import Foundation
import Combine
import AppKit

struct IncomingTransfer: Equatable {
    let filename: String
    let deviceName: String
    let receivedBytes: Int64
    let totalBytes: Int64

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }

    var detail: String {
        if totalBytes > 0 {
            return "\(Self.formatBytes(receivedBytes)) of \(Self.formatBytes(totalBytes))"
        }
        return Self.formatBytes(receivedBytes)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let d = Double(bytes)
        if d < 1_024 { return "\(bytes) B" }
        if d < 1_048_576 { return String(format: "%.1f KB", d / 1_024) }
        if d < 1_073_741_824 { return String(format: "%.1f MB", d / 1_048_576) }
        return String(format: "%.2f GB", d / 1_073_741_824)
    }
}

enum SyncStatus: Equatable {
    case idle
    case displayingQR(secondsLeft: Int)
    case connecting
    case connected(ip: String, port: Int, token: String, expiry: Date?)
    case error(String)

    static func == (lhs: SyncStatus, rhs: SyncStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.connecting, .connecting):
            return true
        case (.displayingQR(let a), .displayingQR(let b)):
            return a == b
        case (.connected(let a0, let a1, let a2, let a3), .connected(let b0, let b1, let b2, let b3)):
            return a0 == b0 && a1 == b1 && a2 == b2 && a3 == b3
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

@MainActor
final class SessionState: ObservableObject {

    @Published var status: SyncStatus = .idle
    @Published var timeRemaining: String = ""
    @Published var deviceName: String = ""
    @Published var incomingTransfer: IncomingTransfer?

    private var tickTimer: Timer?
    private var qrSecondsLeft = 60

    // MARK: - State transitions

    func startQRCountdown(onExpire: @escaping () -> Void) {
        qrSecondsLeft = 60
        status = .displayingQR(secondsLeft: qrSecondsLeft)
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.qrSecondsLeft -= 1
                if self.qrSecondsLeft <= 0 {
                    self.tickTimer?.invalidate()
                    onExpire()
                } else {
                    self.status = .displayingQR(secondsLeft: self.qrSecondsLeft)
                }
            }
        }
    }

    func setConnected(ip: String, port: Int, token: String, expiry: Date?) {
        tickTimer?.invalidate()
        status = .connected(ip: ip, port: port, token: token, expiry: expiry)
        if let expiry { startSessionCountdown(until: expiry) }
    }

    func setConnecting() {
        tickTimer?.invalidate()
        status = .connecting
    }

    func setIdle() {
        tickTimer?.invalidate()
        status = .idle
        timeRemaining = ""
        deviceName = ""
        incomingTransfer = nil
    }

    func setError(_ message: String) {
        tickTimer?.invalidate()
        status = .error(message)
        incomingTransfer = nil
    }

    func updateIncomingTransfer(filename: String, deviceName: String, receivedBytes: Int64, totalBytes: Int64) {
        incomingTransfer = IncomingTransfer(
            filename: filename,
            deviceName: deviceName,
            receivedBytes: receivedBytes,
            totalBytes: totalBytes
        )
    }

    func clearIncomingTransfer(after delay: TimeInterval = 1.4) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await MainActor.run {
                self?.incomingTransfer = nil
            }
        }
    }

    // MARK: - Countdown

    private func startSessionCountdown(until expiry: Date) {
        timeRemaining = Self.formatInterval(expiry.timeIntervalSinceNow)
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let remaining = expiry.timeIntervalSinceNow
                if remaining <= 0 {
                    self.tickTimer?.invalidate()
                    self.setIdle()
                } else {
                    self.timeRemaining = Self.formatInterval(remaining)
                }
            }
        }
    }

    static func formatInterval(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return String(format: "%ds", s)
    }

    // MARK: - Derived helpers

    var menuBarTint: NSColor? {
        switch status {
        case .connected:  return NSColor.systemGreen
        case .error:      return NSColor.systemRed
        default:          return nil
        }
    }
}
