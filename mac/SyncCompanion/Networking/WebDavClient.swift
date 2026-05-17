import Foundation

struct WebDavItem: Identifiable, Hashable {
    let name: String
    let path: String        // URL-decoded, starts with /
    let isDirectory: Bool
    let size: Int64
    let modified: Date?

    var id: String { path }

    var sfSymbol: String {
        if isDirectory { return "folder.fill" }
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "mp4", "mov", "avi", "mkv":                  return "film"
        case "mp3", "m4a", "aac", "wav", "flac":          return "music.note"
        case "pdf":                                         return "doc.richtext"
        case "zip", "tar", "gz", "7z", "rar":             return "archivebox"
        case "txt", "md":                                  return "doc.text"
        default:                                            return "doc"
        }
    }

    var isPreviewableImage: Bool {
        guard !isDirectory else { return false }
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return true
        default: return false
        }
    }

    var isPreviewableVideo: Bool {
        guard !isDirectory else { return false }
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4", "mov", "m4v": return true
        default: return false
        }
    }

    var isPreviewableMedia: Bool {
        isPreviewableImage || isPreviewableVideo
    }

    var displaySize: String {
        guard !isDirectory else { return "—" }
        let d = Double(size)
        if d < 1_024            { return "\(size) B" }
        if d < 1_048_576        { return String(format: "%.1f KB", d / 1_024) }
        if d < 1_073_741_824   { return String(format: "%.1f MB", d / 1_048_576) }
        return String(format: "%.2f GB", d / 1_073_741_824)
    }
}

final class WebDavClient {
    static let defaultPort = 8080

    let ip: String
    let port: Int
    private let token: String
    private let session: URLSession

    init(ip: String, port: Int, token: String) {
        self.ip    = ip
        self.port  = port
        self.token = token
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
    }

    // MARK: - Helpers

    private var authHeader: String {
        "Basic " + Data("sync:\(token)".utf8).base64EncodedString()
    }

    private func url(for path: String) -> URL {
        var c = URLComponents()
        c.scheme = "http"
        c.host   = ip
        c.port   = port
        c.path   = path.isEmpty ? "/" : path
        return c.url!
    }

    private func req(method: String, path: String,
                     extra: [String: String] = [:], body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url(for: path))
        r.httpMethod = method
        r.setValue(authHeader, forHTTPHeaderField: "Authorization")
        extra.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        r.httpBody = body
        return r
    }

    private func validate(_ response: URLResponse, allowed: Set<Int>) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard allowed.contains(http.statusCode) else {
            throw WebDavError.httpStatus(http.statusCode)
        }
    }

    private func mapNetworkError(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        if urlError.code == .notConnectedToInternet, isLocalAddress(ip) {
            return WebDavError.localNetworkProhibited
        }
        return error
    }

    private func isLocalAddress(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        return false
    }

    // MARK: - WebDAV verbs

    func propfind(path: String) async throws -> [WebDavItem] {
        do {
            let (data, response) = try await session.data(for: req(method: "PROPFIND", path: path,
                                                                   extra: ["Depth": "1"]))
            try validate(response, allowed: [207])
            return PropfindParser.parse(data: data, requestedPath: path)
        } catch {
            throw mapNetworkError(error)
        }
    }

    func download(path: String) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: req(method: "GET", path: path))
            try validate(response, allowed: [200])
            return data
        } catch {
            throw mapNetworkError(error)
        }
    }

    func download(path: String, to destination: URL) async throws {
        do {
            let (tempURL, response) = try await session.download(for: req(method: "GET", path: path))
            try validate(response, allowed: [200])
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            throw mapNetworkError(error)
        }
    }

    func upload(path: String, data: Data) async throws {
        do {
            let (_, response) = try await session.data(for: req(method: "PUT", path: path,
                                                                extra: ["Content-Type": "application/octet-stream",
                                                                        "Content-Length": "\(data.count)"],
                                                                body: data))
            try validate(response, allowed: [200, 201, 204])
        } catch {
            throw mapNetworkError(error)
        }
    }

    func upload(path: String, fileURL: URL) async throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        var request = req(method: "PUT", path: path, extra: [
            "Content-Type": "application/octet-stream",
            "Content-Length": "\(size)"
        ])
        request.httpBody = nil
        do {
            let (_, response) = try await session.upload(for: request, fromFile: fileURL)
            try validate(response, allowed: [200, 201, 204])
        } catch {
            throw mapNetworkError(error)
        }
    }

    func delete(path: String) async throws {
        do {
            let (_, response) = try await session.data(for: req(method: "DELETE", path: path))
            try validate(response, allowed: [200, 202, 204])
        } catch {
            throw mapNetworkError(error)
        }
    }

    func mkcol(path: String) async throws {
        do {
            let (_, response) = try await session.data(for: req(method: "MKCOL", path: path))
            try validate(response, allowed: [200, 201, 204])
        } catch {
            throw mapNetworkError(error)
        }
    }
}

enum WebDavError: LocalizedError {
    case httpStatus(Int)
    case localNetworkProhibited

    var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "WebDAV request failed with HTTP \(code)."
        case .localNetworkProhibited:
            return "macOS is blocking MiDoid from the Local Network. Enable MiDoid in System Settings > Privacy & Security > Local Network, then reconnect."
        }
    }
}

// MARK: - PROPFIND XML parser

private final class PropfindParser: NSObject, XMLParserDelegate {
    private var items: [WebDavItem] = []

    // per-response accumulators
    private var href         = ""
    private var displayName  = ""
    private var contentLen: Int64 = 0
    private var modified: Date?   = nil
    private var isCollection      = false
    private var inResponse        = false
    private var inProp            = false
    private var currentText       = ""
    private var currentLocal      = ""

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale   = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        currentLocal = local(name)
        currentText  = ""
        switch currentLocal {
        case "response":
            href = ""; displayName = ""; contentLen = 0
            modified = nil; isCollection = false; inResponse = true
        case "prop":   if inResponse { inProp = true }
        case "collection": if inProp { isCollection = true }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch local(name) {
        case "href":             if inResponse { href = text }
        case "displayname":      if inProp { displayName = text }
        case "getcontentlength": if inProp { contentLen = Int64(text) ?? 0 }
        case "getlastmodified":  if inProp { modified = Self.dateFmt.date(from: text) }
        case "prop":             inProp = false
        case "response":
            if inResponse {
                let decodedPath = href.removingPercentEncoding ?? href
                let name = displayName.isEmpty
                    ? (decodedPath as NSString).lastPathComponent
                    : displayName
                if !decodedPath.isEmpty {
                    items.append(WebDavItem(name: name, path: decodedPath,
                                           isDirectory: isCollection,
                                           size: contentLen, modified: modified))
                }
                inResponse = false
            }
        default: break
        }
        currentText  = ""
        currentLocal = ""
    }

    private func local(_ name: String) -> String {
        name.components(separatedBy: ":").last ?? name
    }

    static func parse(data: Data, requestedPath: String) -> [WebDavItem] {
        let delegate = PropfindParser()
        let p = XMLParser(data: data)
        p.delegate = delegate
        p.shouldProcessNamespaces = false
        p.parse()
        // Filter out the root entry (the requested path itself)
        let norm = requestedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return delegate.items.filter {
            $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != norm
        }
    }
}
