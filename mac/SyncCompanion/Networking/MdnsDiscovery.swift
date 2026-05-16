import Foundation
import Darwin

@MainActor
protocol MdnsDiscoveryDelegate: AnyObject {
    func deviceFound(ip: String, port: Int, sessionId: String)
    func deviceLost()
}

final class MdnsDiscovery: NSObject {

    weak var delegate: MdnsDiscoveryDelegate?

    private var browser: NetServiceBrowser?
    private var resolving: NetService?
    private var expectedSessionId: String = ""

    // MARK: - Lifecycle

    func start(expectedSessionId: String) {
        self.expectedSessionId = expectedSessionId
        stop()

        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: "_android-sync._tcp.", inDomain: "local.")
        browser = b
    }

    func stop() {
        browser?.stop()
        browser = nil
        resolving?.stop()
        resolving = nil
    }

    // MARK: - Address extraction

    private func extractIPv4(from service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        for data in addresses {
            let ip = data.withUnsafeBytes { ptr -> String? in
                let family = ptr.load(as: sockaddr.self).sa_family
                guard family == AF_INET else { return nil }
                var addr = ptr.load(as: sockaddr_in.self)
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &addr.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
                let candidate = String(cString: buf)
                return candidate == "0.0.0.0" ? nil : candidate
            }
            if let ip { return ip }
        }
        return nil
    }
}

// MARK: - NetServiceBrowserDelegate

extension MdnsDiscovery: NetServiceBrowserDelegate {

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        resolving = service
        service.delegate = self
        service.resolve(withTimeout: 10)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        Task { @MainActor [weak self] in
            self?.delegate?.deviceLost()
        }
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        NSLog("MdnsDiscovery: browser stopped")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        NSLog("MdnsDiscovery: search error: \(errorDict)")
    }
}

// MARK: - NetServiceDelegate

extension MdnsDiscovery: NetServiceDelegate {

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let txtData = sender.txtRecordData() else {
            NSLog("MdnsDiscovery: no TXT record — ignoring")
            return
        }

        let txt = NetService.dictionary(fromTXTRecord: txtData)

        // Security Fix #3: verify session_id in TXT record matches current QR session
        guard
            let sidData = txt["session_id"],
            let sessionId = String(data: sidData, encoding: .utf8),
            sessionId == expectedSessionId
        else {
            NSLog("MdnsDiscovery: session_id mismatch — rejecting service")
            return
        }

        guard let ip = extractIPv4(from: sender) else {
            NSLog("MdnsDiscovery: no IPv4 address resolved")
            return
        }

        Task { @MainActor [weak self] in
            self?.delegate?.deviceFound(ip: ip, port: sender.port, sessionId: sessionId)
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        NSLog("MdnsDiscovery: resolve failed: \(errorDict)")
    }
}
