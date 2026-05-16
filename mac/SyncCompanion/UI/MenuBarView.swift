import AppKit
import SwiftUI

struct MenuBarView: View {

    @ObservedObject var state: SessionState
    let manager: ConnectionManager

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            contentBody
                .padding(16)

            Divider()

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 260)
        .background(Color.syncSurface)
    }

    // MARK: - Header

    private var statusHeader: some View {
        HStack(spacing: 8) {
            ZStack {
                if case .connected = state.status {
                    Circle().fill(state.status.color.opacity(0.25)).frame(width: 14, height: 14)
                }
                Circle().fill(state.status.color).frame(width: 8, height: 8)
            }

            Text(state.status.label)
                .font(.system(.callout, design: .rounded).weight(.semibold))

            Spacer()

            if case .connected = state.status, !state.timeRemaining.isEmpty {
                Text(state.timeRemaining)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentBody: some View {
        switch state.status {
        case .idle:
            idleView

        case .displayingQR(let secs):
            QRCodeView(payload: manager.currentQRJSON, secondsLeft: secs)

        case .connecting:
            connectingView

        case .connected:
            connectedView

        case .error(let msg):
            errorView(msg)
        }
    }

    private var idleView: some View {
        VStack(spacing: 10) {
            Image(systemName: Icons.qr)
                .font(.system(size: 44))
                .foregroundColor(.secondary)
                .padding(.bottom, 4)
            Text("Open SyncCompanion on your\nAndroid phone and scan the QR")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var connectingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Connecting…")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var connectedView: some View {
        VStack(spacing: 8) {
            Image(systemName: Icons.connected)
                .font(.system(size: 44))
                .foregroundColor(.syncGreen)
                .padding(.bottom, 4)
            Text("Android is connected")
                .font(.callout.weight(.medium))
            Button("Open File Manager") {
                manager.openFileManager()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: Icons.error)
                .font(.system(size: 36))
                .foregroundColor(.syncRed)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
            Button("Try Again") { manager.generateSession() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if case .connected = state.status {
                Button(action: { manager.disconnect() }) {
                    Label("Disconnect", systemImage: Icons.disconnect)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()

            if case .displayingQR = state.status {
                Button(action: { manager.generateSession() }) {
                    Image(systemName: Icons.refresh)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Generate new QR code")
            }

            Button(action: { NSApplication.shared.terminate(nil) }) {
                Image(systemName: Icons.quit)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Quit SyncCompanion")
        }
    }
}
