import AppKit
import Foundation
import Darwin
import UserNotifications

struct QRPayload: Codable {
    let token: String
    let mac_ip: String
    let port: Int
    let session_id: String
    let expires_at: Int64
    let v: Int
}

private struct PairedSession: Codable {
    let sessionId: String
    let token: String
    let ip: String
    let port: Int
    let expiry: Date?

    var isExpired: Bool {
        guard let expiry else { return false }
        return expiry <= Date()
    }
}

@MainActor
final class ConnectionManager: NSObject {

    private let sessionState: SessionState
    private let discovery = MdnsDiscovery()

    private var currentSessionId: String = ""
    private var currentToken: String = ""
    private(set) var currentQRJSON: String = ""
    private var rememberedSession: PairedSession?
    private var autoReconnectEnabled = true
    private var reconnectRetryTask: Task<Void, Never>?
    private var recentDisconnects: [Date] = []
    private var incomingFileServer: IncomingFileServer?

    var hasRememberedSession: Bool { rememberedSession != nil }
    var rememberedEndpointLabel: String? {
        rememberedSession.map { "\($0.ip):\($0.port)" }
    }

    init(sessionState: SessionState) {
        self.sessionState = sessionState
        if let data = KeychainStore.load(forKey: Self.rememberedSessionKey) {
            rememberedSession = try? JSONDecoder().decode(PairedSession.self, from: data)
            if let rememberedSession, rememberedSession.isExpired {
                self.rememberedSession = nil
                KeychainStore.delete(forKey: Self.rememberedSessionKey)
            }
        }
        super.init()
        discovery.delegate = self
    }

    // MARK: - Session generation

    func start() {
        if rememberedSession != nil {
            reconnect()
        } else {
            generateSession()
        }
    }

    func generateSession() {
        autoReconnectEnabled = true
        reconnectRetryTask?.cancel()
        let sessionId = String(format: "%06x", Int.random(in: 0...0xFFFFFF))
        let token = randomToken()
        currentSessionId = sessionId
        currentToken = token
        currentQRJSON = ""
        startQR(sessionId: sessionId, token: token)
    }

    private func startQR(sessionId: String, token: String) {
        guard let ip = lanIP() else {
            sessionState.setError("No local network address found. MiDoid does not need internet, but your Mac must be on the same Wi-Fi or LAN as Android.")
            return
        }
        let expiresAt = Int64(Date().timeIntervalSince1970) + 60
        let payload = QRPayload(token: token, mac_ip: ip, port: WebDavClient.defaultPort,
                                session_id: sessionId, expires_at: expiresAt, v: 1)
        if let data = try? JSONEncoder().encode(payload),
           let json = String(data: data, encoding: .utf8) {
            currentQRJSON = json
        }
        discovery.start(expectedSessionId: sessionId)
        sessionState.startQRCountdown { [weak self] in
            self?.generateSession()
        }
    }

    // MARK: - File manager

    func openFileManager() {
        guard case .connected(let ip, let port, let token, _) = sessionState.status else { return }
        FileManagerWindow.shared.open(ip: ip, port: port, token: token)
    }

    // MARK: - Disconnect

    func disconnect() {
        autoReconnectEnabled = false
        reconnectRetryTask?.cancel()
        FileManagerWindow.shared.close()
        discovery.stop()
        incomingFileServer?.stop()
        incomingFileServer = nil
        sessionState.setIdle()
        generateSession()
        autoReconnectEnabled = false
    }

    func forgetRememberedDevice() {
        rememberedSession = nil
        KeychainStore.delete(forKey: Self.rememberedSessionKey)
        autoReconnectEnabled = false
        reconnectRetryTask?.cancel()
        if case .connecting = sessionState.status {
            generateSession()
        }
    }

    // Sends local files to the Android device by uploading them to the root WebDAV directory.
    // Opens the file manager window first so the user can see progress.
    func quickSend(urls: [URL]) {
        guard case .connected(let ip, let port, let token, _) = sessionState.status else { return }
        FileManagerWindow.shared.open(ip: ip, port: port, token: token)
        FileManagerWindow.shared.prepareUpload(urls: urls)
    }

    func reconnect() {
        autoReconnectEnabled = true
        FileManagerWindow.shared.close()
        guard let session = rememberedSession else {
            generateSession()
            return
        }
        guard !session.isExpired else {
            rememberedSession = nil
            KeychainStore.delete(forKey: Self.rememberedSessionKey)
            generateSession()
            return
        }
        currentSessionId = session.sessionId
        currentToken = session.token
        currentQRJSON = ""
        sessionState.setConnecting()
        startReconnectLoop(for: session, retryDelay: 5)
    }

    private func remember(_ session: PairedSession) {
        rememberedSession = session
        if let data = try? JSONEncoder().encode(session) {
            try? KeychainStore.save(data, forKey: Self.rememberedSessionKey)
        }
    }

    private func startReconnectLoop(for session: PairedSession, retryDelay: TimeInterval) {
        reconnectRetryTask?.cancel()
        discovery.start(expectedSessionId: session.sessionId)
        probeRememberedSession(session)
        // mDNS can miss a re-appearance after sleep or Wi-Fi changes, so restart
        // discovery while the UI remains in "connecting". We also probe the last
        // known endpoint because Bonjour can lag behind real network availability.
        reconnectRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(retryDelay * 1_000_000_000))
                let shouldRetry = await MainActor.run { () -> Bool in
                    guard let self, self.autoReconnectEnabled else { return false }
                    guard case .connecting = self.sessionState.status else { return false }
                    self.discovery.start(expectedSessionId: session.sessionId)
                    self.probeRememberedSession(session)
                    return true
                }
                if !shouldRetry { break }
            }
        }
    }

    private func probeRememberedSession(_ session: PairedSession) {
        Task { [weak self] in
            guard let self else { return }
            let authHeader = "Basic " + Data("sync:\(session.token)".utf8).base64EncodedString()
            guard let url = URL(string: "http://\(session.ip):\(session.port)/_midoid/info") else { return }
            var req = URLRequest(url: url)
            req.setValue(authHeader, forHTTPHeaderField: "Authorization")
            req.setValue("close", forHTTPHeaderField: "Connection")
            req.timeoutInterval = 3
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpAdditionalHeaders = ["Connection": "close"]
            guard let (_, response) = try? await URLSession(configuration: cfg).data(for: req),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { return }

            await MainActor.run {
                guard self.autoReconnectEnabled else { return }
                guard case .connecting = self.sessionState.status else { return }
                guard !session.isExpired else {
                    self.rememberedSession = nil
                    KeychainStore.delete(forKey: Self.rememberedSessionKey)
                    self.generateSession()
                    return
                }
                self.completeConnection(ip: session.ip, port: session.port, token: session.token, sessionId: session.sessionId)
            }
        }
    }

    // MARK: - Token generation

    private func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - LAN IP detection

    private func lanIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        var fallback: String?
        while let ifa = ptr {
            let name   = String(cString: ifa.pointee.ifa_name)
            let flags = Int32(ifa.pointee.ifa_flags)
            let family = ifa.pointee.ifa_addr.pointee.sa_family
            let isUsableInterface = (flags & IFF_UP) != 0
                && (flags & IFF_RUNNING) != 0
                && (flags & IFF_LOOPBACK) == 0
                && !name.hasPrefix("utun")
                && !name.hasPrefix("awdl")
                && !name.hasPrefix("llw")

            if family == UInt8(AF_INET), isUsableInterface {
                var addr = ifa.pointee.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf  = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: buf)
                if isPrivateIPv4(ip) { return ip }
                if fallback == nil, ip != "127.0.0.1" { fallback = ip }
            }
            ptr = ifa.pointee.ifa_next
        }
        return fallback
    }

    private func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        return false
    }

    // MARK: - Device name

    private func fetchDeviceName(ip: String, port: Int, token: String) {
        Task { [weak self] in
            guard let self else { return }
            let authHeader = "Basic " + Data("sync:\(token)".utf8).base64EncodedString()
            var request = URLRequest(url: URL(string: "http://\(ip):\(port)/_midoid/info")!)
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            request.setValue("close", forHTTPHeaderField: "Connection")
            request.timeoutInterval = 4
            let cfg = URLSessionConfiguration.default
            cfg.httpAdditionalHeaders = ["Connection": "close"]
            let session = URLSession(configuration: cfg)
            // Android's WebDAV server may not have bound its socket yet when mDNS fires,
            // so retry a few times with a short backoff before giving up silently.
            for attempt in 0..<4 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                }
                guard let (data, resp) = try? await session.data(for: request),
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let name = json["name"] as? String, !name.isEmpty {
                    self.sessionState.deviceName = name
                }
                if let expiryMs = json["expiry_ms"] as? NSNumber, expiryMs.int64Value > 0 {
                    let expiry = Date(timeIntervalSince1970: TimeInterval(expiryMs.int64Value) / 1000)
                    self.remember(PairedSession(sessionId: self.currentSessionIdForConnection(ip: ip, port: port, token: token), token: token, ip: ip, port: port, expiry: expiry))
                    self.sessionState.updateConnectedExpiry(expiry)
                }
                return
            }
        }
    }

    private func currentSessionIdForConnection(ip: String, port: Int, token: String) -> String {
        if let rememberedSession,
           rememberedSession.ip == ip,
           rememberedSession.port == port,
           rememberedSession.token == token {
            return rememberedSession.sessionId
        }
        return currentSessionId
    }

    // MARK: - Incoming file server

    private func startIncomingServer(token: String, deviceName: String) {
        let server = IncomingFileServer()
        server.onTransferProgress = { [weak self] filename, senderName, received, total in
            self?.sessionState.updateIncomingTransfer(
                filename: filename,
                deviceName: senderName,
                receivedBytes: received,
                totalBytes: total
            )
        }
        server.onFileReceived = { [weak self] url, filename, senderName in
            guard let self else { return }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .flatMap { Int64($0) } ?? 0
            NotificationManager.fileReceived(name: filename, size: size, from: senderName, at: url)
            self.presentReceivedFile(url)
            self.sessionState.clearIncomingTransfer()
        }
        server.start(token: token)
        incomingFileServer = server
    }

    private func presentReceivedFile(_ url: URL) {
        if Self.imageExtensions.contains(url.pathExtension.lowercased()) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private static let rememberedSessionKey = "remembered_android_session"
    private static let imageExtensions: Set<String> = ["avif", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"]
}

// MARK: - MdnsDiscoveryDelegate

extension ConnectionManager: MdnsDiscoveryDelegate {

    func deviceFound(ip: String, port: Int, sessionId: String) {
        let token: String
        if sessionId == currentSessionId, !currentToken.isEmpty {
            token = currentToken
        } else if let rememberedSession, rememberedSession.sessionId == sessionId {
            token = rememberedSession.token
        } else {
            return
        }

        completeConnection(ip: ip, port: port, token: token, sessionId: sessionId)
    }

    private func completeConnection(ip: String, port: Int, token: String, sessionId: String) {
        let expiry = rememberedSession?.sessionId == sessionId ? rememberedSession?.expiry : nil
        remember(PairedSession(sessionId: sessionId, token: token, ip: ip, port: port, expiry: expiry))
        autoReconnectEnabled = true
        reconnectRetryTask?.cancel()
        recentDisconnects.removeAll()
        currentToken = ""
        discovery.stop()
        sessionState.setConnected(ip: ip, port: port, token: token, expiry: expiry)
        fetchDeviceName(ip: ip, port: port, token: token)
        startIncomingServer(token: token, deviceName: "")
        FileManagerWindow.shared.open(ip: ip, port: port, token: token)
    }

    func deviceLost() {
        guard case .connected = sessionState.status else { return }
        FileManagerWindow.shared.close()
        incomingFileServer?.stop()
        incomingFileServer = nil
        let reconnectDelay = nextReconnectDelay()
        guard reconnectDelay != nil else {
            autoReconnectEnabled = false
            reconnectRetryTask?.cancel()
            discovery.stop()
            sessionState.setError("Connection is unstable. MiDoid stopped reconnecting after repeated disconnects.")
            return
        }
        guard autoReconnectEnabled, let rememberedSession else {
            sessionState.setError("Android disconnected.")
            return
        }
        sessionState.setConnecting()
        startReconnectLoop(for: rememberedSession, retryDelay: reconnectDelay ?? 30)
    }

    private func nextReconnectDelay() -> TimeInterval? {
        let now = Date()
        let cutoff = now.addingTimeInterval(-10)
        recentDisconnects = recentDisconnects.filter { $0 >= cutoff }
        recentDisconnects.append(now)

        // Stop if the connection flaps more than 5 times in 10 seconds.
        guard recentDisconnects.count <= 5 else { return nil }

        switch recentDisconnects.count {
        case 1, 2: return 5
        case 3: return 10
        default: return 30
        }
    }
}
