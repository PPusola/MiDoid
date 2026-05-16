import SwiftUI
import AppKit

// MARK: - Semantic colors (auto dark/light adaptive)

extension Color {
    static let syncGreen        = Color(nsColor: .systemGreen)
    static let syncYellow       = Color(nsColor: .systemYellow)
    static let syncRed          = Color(nsColor: .systemRed)
    static let syncGreenMuted   = Color(nsColor: .systemGreen).opacity(0.15)
    static let syncSurface      = Color(nsColor: .windowBackgroundColor)
    static let syncOnSurface    = Color(nsColor: .labelColor)
    static let syncSubtle       = Color(nsColor: .secondaryLabelColor)
}

// MARK: - SF Symbol name constants

enum Icons {
    static let phone        = "iphone.and.arrow.forward"
    static let qr           = "qrcode.viewfinder"
    static let connected    = "checkmark.icloud.fill"
    static let error        = "exclamationmark.triangle.fill"
    static let disconnect   = "eject.fill"
    static let refresh      = "arrow.clockwise"
    static let eye          = "eye.fill"
    static let eyeSlash     = "eye.slash.fill"
    static let quit         = "power"
    static let spinner      = "arrow.triangle.2.circlepath"
    static let clock        = "clock"
}

// MARK: - Status derived values

extension SyncStatus {

    var label: String {
        switch self {
        case .idle:          return "Waiting for device"
        case .displayingQR:  return "Scan to connect"
        case .connecting:    return "Connecting…"
        case .connected:     return "Connected"
        case .error:         return "Error"
        }
    }

    var color: Color {
        switch self {
        case .idle:          return .syncSubtle
        case .displayingQR:  return .syncYellow
        case .connecting:    return .syncYellow
        case .connected:     return .syncGreen
        case .error:         return .syncRed
        }
    }

    var icon: String {
        switch self {
        case .idle:          return Icons.phone
        case .displayingQR:  return Icons.qr
        case .connecting:    return Icons.spinner
        case .connected:     return Icons.connected
        case .error:         return Icons.error
        }
    }
}
