import Network
import Foundation

// Listens on port 8082 for HTTP POST /receive from Android's ShareReceiveActivity.
// The class itself is MainActor so callers don't need to switch; networking helpers
// are nonisolated so they can run on the NWListener background queue.
@MainActor
final class IncomingFileServer {
    static let port: UInt16 = 8082

    var onFileReceived: ((URL, String, String) -> Void)?   // (savedURL, filename, deviceName)
    var onTransferProgress: ((String, String, Int64, Int64) -> Void)? // filename, deviceName, received, total

    private var listener: NWListener?

    func start(token: String) {
        stop()
        guard let l = try? NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!) else { return }
        listener = l
        // Capture token as a plain String value so the Sendable closure doesn't
        // need to reach back to the MainActor-isolated self.
        let tok = token
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInitiated))
            IncomingFileServer.readHeaders(connection: conn, accumulated: Data()) { headerData, bodyStart in
                IncomingFileServer.processRequest(
                    connection: conn,
                    headerData: headerData,
                    bodyStart: bodyStart,
                    token: tok
                ) { url, filename, deviceName in
                    Task { @MainActor [weak self] in
                        self?.onFileReceived?(url, filename, deviceName)
                    }
                } onProgress: { filename, deviceName, received, total in
                    Task { @MainActor [weak self] in
                        self?.onTransferProgress?(filename, deviceName, received, total)
                    }
                }
            }
        }
        l.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - nonisolated networking helpers (run on NWListener background queue)

    private nonisolated static func readHeaders(
        connection: NWConnection,
        accumulated: Data,
        completion: @escaping (Data, Data) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
            guard error == nil, let data, !data.isEmpty else { connection.cancel(); return }
            let all = accumulated + data
            if let range = all.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                completion(Data(all[..<range.upperBound]), Data(all[range.upperBound...]))
            } else {
                readHeaders(connection: connection, accumulated: all, completion: completion)
            }
        }
    }

    private nonisolated static func processRequest(
        connection: NWConnection,
        headerData: Data,
        bodyStart: Data,
        token: String,
        onDone: @escaping (URL, String, String) -> Void,
        onProgress: @escaping (String, String, Int64, Int64) -> Void
    ) {
        guard let str = String(data: headerData, encoding: .utf8) else {
            send(connection: connection, status: 400); return
        }
        let lines = str.components(separatedBy: "\r\n")
        guard let requestLine = lines.first,
              requestLine.uppercased().hasPrefix("POST /RECEIVE") ||
              requestLine.hasPrefix("POST /receive") else {
            send(connection: connection, status: 400); return
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        guard let auth = headers["authorization"],
              auth.hasPrefix("Basic "),
              let decoded = Data(base64Encoded: String(auth.dropFirst(6)).trimmingCharacters(in: .whitespaces))
                  .flatMap({ String(data: $0, encoding: .utf8) }),
              decoded == "sync:\(token)" else {
            send(connection: connection, status: 401); return
        }

        let filename   = headers["x-filename"]    ?? "received_file"
        let deviceName = headers["x-device-name"] ?? "Android"
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0

        let landingDir = IncomingFileServer.landingFolder(for: filename)
        try? FileManager.default.createDirectory(at: landingDir, withIntermediateDirectories: true)
        let destURL = IncomingFileServer.uniqueURL(in: landingDir, filename: filename)

        guard FileManager.default.createFile(atPath: destURL.path, contents: nil),
              let fileHandle = try? FileHandle(forWritingTo: destURL) else {
            send(connection: connection, status: 500); return
        }

        if !bodyStart.isEmpty { fileHandle.write(bodyStart) }
        onProgress(filename, deviceName, Int64(bodyStart.count), Int64(contentLength))
        let remaining = contentLength - bodyStart.count
        if remaining <= 0 {
            try? fileHandle.close()
            send(connection: connection, status: 200)
            onDone(destURL, filename, deviceName)
        } else {
            streamBody(connection: connection, fileHandle: fileHandle, remaining: remaining,
                       totalLength: contentLength, received: bodyStart.count,
                       destURL: destURL, filename: filename, deviceName: deviceName,
                       onDone: onDone, onProgress: onProgress)
        }
    }

    private nonisolated static func streamBody(
        connection: NWConnection,
        fileHandle: FileHandle,
        remaining: Int,
        totalLength: Int,
        received: Int,
        destURL: URL,
        filename: String,
        deviceName: String,
        onDone: @escaping (URL, String, String) -> Void,
        onProgress: @escaping (String, String, Int64, Int64) -> Void
    ) {
        let toRead = min(remaining, 65_536)
        connection.receive(minimumIncompleteLength: 1, maximumLength: toRead) { data, _, _, error in
            guard error == nil, let data, !data.isEmpty else {
                try? fileHandle.close(); connection.cancel(); return
            }
            fileHandle.write(data)
            let newRemaining = remaining - data.count
            let newReceived = received + data.count
            onProgress(filename, deviceName, Int64(newReceived), Int64(totalLength))
            if newRemaining <= 0 {
                try? fileHandle.close()
                send(connection: connection, status: 200)
                onDone(destURL, filename, deviceName)
            } else {
                streamBody(connection: connection, fileHandle: fileHandle, remaining: newRemaining,
                           totalLength: totalLength, received: newReceived,
                           destURL: destURL, filename: filename, deviceName: deviceName,
                           onDone: onDone, onProgress: onProgress)
            }
        }
    }

    private nonisolated static func send(connection: NWConnection, status: Int) {
        let phrase: String
        switch status {
        case 200: phrase = "OK"
        case 400: phrase = "Bad Request"
        case 401: phrase = "Unauthorized"
        default:  phrase = "Internal Server Error"
        }
        let response = "HTTP/1.1 \(status) \(phrase)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: response.data(using: .utf8), completion: .idempotent)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { connection.cancel() }
    }

    // MARK: - Landing folder helpers (nonisolated — called from background queue too)

    nonisolated static let landingFolderDefaultsKey = "incoming.landingFolderPath"

    nonisolated static func landingFolder() -> URL {
        if let saved = UserDefaults.standard.string(forKey: landingFolderDefaultsKey) {
            let url = URL(fileURLWithPath: saved, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/MiDoid", isDirectory: true)
    }

    static func setLandingFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: landingFolderDefaultsKey)
    }

    nonisolated static func landingFolder(for filename: String) -> URL {
        landingFolder().appendingPathComponent(folderName(for: filename), isDirectory: true)
    }

    nonisolated static func folderName(for filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "raw", "tif", "tiff", "webp":
            return "Photos"
        case "3gp", "avi", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "webm":
            return "Videos"
        case "aac", "aiff", "alac", "flac", "m4a", "mp3", "ogg", "opus", "wav":
            return "Audio"
        case "csv", "doc", "docx", "key", "md", "numbers", "pages", "pdf", "ppt", "pptx", "rtf", "txt", "xls", "xlsx":
            return "Documents"
        case "7z", "bz2", "dmg", "gz", "pkg", "rar", "tar", "tgz", "zip":
            return "Archives"
        default:
            return "Other"
        }
    }

    nonisolated static func uniqueURL(in folder: URL, filename: String) -> URL {
        let base = folder.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: base.path) else { return base }
        let ns  = filename as NSString
        let stem = ns.deletingPathExtension
        let ext  = ns.pathExtension
        var i = 1
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            let url = folder.appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            i += 1
        }
    }
}
