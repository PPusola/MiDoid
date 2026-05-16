import AppKit
import Foundation
import Darwin

struct QRPayload: Codable {
    let token: String
    let mac_ip: String
    let port: Int
    let session_id: String
    let expires_at: Int64
    let v: Int
}

@MainActor
final class ConnectionManager: NSObject {

    private let sessionState: SessionState
    private let discovery = MdnsDiscovery()

    private var currentSessionId: String = ""
    private var currentToken: String = ""
    private(set) var currentQRJSON: String = ""

    init(sessionState: SessionState) {
        self.sessionState = sessionState
        super.init()
        discovery.delegate = self
    }

    // MARK: - Session generation

    func generateSession() {
        let sessionId = String(format: "%06x", Int.random(in: 0...0xFFFFFF))
        let token = randomToken()
        currentSessionId = sessionId
        currentToken = token
        currentQRJSON = ""
        startQR(sessionId: sessionId, token: token)
    }

    private func startQR(sessionId: String, token: String) {
        guard let ip = lanIP() else {
            sessionState.setError("No Wi-Fi IP found. Connect to a network.")
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
        FileManagerWindow.shared.close()
        sessionState.setIdle()
        generateSession()
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
        while let ifa = ptr {
            let name   = String(cString: ifa.pointee.ifa_name)
            let family = ifa.pointee.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET), name.hasPrefix("en") {
                var addr = ifa.pointee.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf  = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let ip = String(cString: buf)
                if ip != "127.0.0.1" { return ip }
            }
            ptr = ifa.pointee.ifa_next
        }
        return nil
    }
}

// MARK: - MdnsDiscoveryDelegate

extension ConnectionManager: MdnsDiscoveryDelegate {

    func deviceFound(ip: String, port: Int, sessionId: String) {
        guard sessionId == currentSessionId else { return }
        let token = currentToken
        currentToken = ""
        discovery.stop()
        sessionState.setConnected(ip: ip, port: port, token: token, expiry: nil)
        FileManagerWindow.shared.open(ip: ip, port: port, token: token)
    }

    func deviceLost() {
        guard case .connected = sessionState.status else { return }
        FileManagerWindow.shared.close()
        sessionState.setIdle()
        generateSession()
    }
}
