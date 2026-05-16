import Foundation
import Combine
import AppKit

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
    }

    func setError(_ message: String) {
        tickTimer?.invalidate()
        status = .error(message)
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
