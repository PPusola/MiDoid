import AppKit
import SwiftUI

struct MenuBarView: View {

    @ObservedObject var state: SessionState
    let manager: ConnectionManager

    var body: some View {
        VStack(spacing: 14) {
            header

            contentBody

            footer
        }
        .padding(14)
        .frame(width: 320)
        .background(
            LinearGradient(
                colors: [
                    Color.syncPanelRaised.opacity(0.95),
                    Color.syncPanel.opacity(0.92)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(state.status.color.opacity(0.16))
                Image(systemName: state.status.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(state.status.color)
            }
            .frame(width: 40, height: 40)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.syncLine, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("MiDoid")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            statusBadge
        }
    }

    private var headerSubtitle: String {
        switch state.status {
        case .idle:
            return "Private Android file access"
        case .displayingQR:
            return "Pair with your Android phone"
        case .connecting:
            return "Looking for your phone"
        case .connected:
            return state.deviceName.isEmpty ? "Android is connected" : state.deviceName
        case .error:
            return "Needs attention"
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.status.color)
                .frame(width: 7, height: 7)
            Text(state.status.label)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(state.status.color.opacity(0.12), in: Capsule())
        .foregroundColor(state.status.color)
    }

    // MARK: - Content

    @ViewBuilder
    private var contentBody: some View {
        switch state.status {
        case .idle:
            idleView

        case .displayingQR(let secs):
            pairingCard(secondsLeft: secs)

        case .connecting:
            connectingView

        case .connected:
            connectedView

        case .error(let msg):
            errorView(msg)
        }
    }

    private var idleView: some View {
        panelCard {
            VStack(spacing: 14) {
                Image(systemName: Icons.laptop)
                    .font(.system(size: 38, weight: .medium))
                    .foregroundColor(.syncAccent)

                VStack(spacing: 4) {
                    Text("Ready to pair")
                        .font(.headline)
                    Text("Open MiDoid on Android and scan the QR code from this Mac.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    manager.generateSession()
                } label: {
                    Label("Show QR Code", systemImage: Icons.qr)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func pairingCard(secondsLeft: Int) -> some View {
        panelCard {
            VStack(spacing: 12) {
                QRCodeView(payload: manager.currentQRJSON, secondsLeft: secondsLeft)

                Text("Local network only. No cloud relay.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.08), in: Capsule())
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var connectingView: some View {
        panelCard {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.regular)

                VStack(spacing: 4) {
                    Text("Reconnecting")
                        .font(.headline)
                    Text(manager.rememberedEndpointLabel.map { "Trying \($0). Keep both devices on the same Wi-Fi network." } ?? "Keep both devices on the same Wi-Fi network.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    manager.generateSession()
                } label: {
                    Label("Pair Again", systemImage: Icons.qr)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var connectedView: some View {
        VStack(spacing: 10) {
            if let transfer = state.incomingTransfer {
                incomingTransferView(transfer)
            }

            panelCard {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.syncGreen.opacity(0.16))
                            Image(systemName: Icons.connected)
                                .font(.system(size: 21, weight: .semibold))
                                .foregroundColor(.syncGreen)
                        }
                        .frame(width: 48, height: 48)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(state.deviceName.isEmpty ? "Android is connected" : state.deviceName)
                                .font(.headline)
                                .lineLimit(1)
                            if case .connected(let ip, let port, _, _) = state.status {
                                Text("\(ip):\(port)")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()
                    }

                    HStack(spacing: 8) {
                        quickInfo(icon: "lock.shield", title: "Private", value: "LAN only")
                        quickInfo(icon: "arrow.up.doc", title: "Send", value: "Drag to icon")
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(IncomingFileServer.landingFolder().lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button("Change") { chooseLandingFolder() }
                            .buttonStyle(.borderless)
                            .font(.caption)
                    }

                    Button {
                        manager.openFileManager()
                    } label: {
                        Label("Open File Manager", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }
        }
    }

    private func incomingTransferView(_ transfer: IncomingTransfer) -> some View {
        panelCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.syncGreen)
                    Text("Receiving")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(Int(transfer.progress * 100))%")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Text(transfer.filename)
                    .font(.caption)
                    .lineLimit(1)

                ProgressView(value: transfer.totalBytes > 0 ? transfer.progress : nil)
                    .controlSize(.small)

                Text(transfer.detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        panelCard {
            VStack(spacing: 12) {
                Image(systemName: Icons.error)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundColor(.syncRed)

                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(5)

                Button {
                    manager.reconnect()
                } label: {
                    Label("Try Again", systemImage: Icons.refresh)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if case .connected = state.status {
                Button {
                    manager.disconnect()
                } label: {
                    Label("Disconnect", systemImage: Icons.disconnect)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    manager.reconnect()
                } label: {
                    Image(systemName: Icons.refresh)
                }
                .buttonStyle(.borderless)
                .help("Reconnect")

                Button {
                    manager.forgetRememberedDevice()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .help("Forget This Device")
            } else if case .displayingQR = state.status {
                Button {
                    manager.generateSession()
                } label: {
                    Label("Refresh QR", systemImage: Icons.refresh)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if case .connecting = state.status {
                EmptyView()
            } else {
                Button {
                    manager.reconnect()
                } label: {
                    Label("Reconnect", systemImage: Icons.refresh)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!manager.hasRememberedSession)

                if manager.hasRememberedSession {
                    Button {
                        manager.forgetRememberedDevice()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                    .help("Forget Saved Device")
                }
            }

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: Icons.quit)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Quit MiDoid")
        }
        .padding(.top, 2)
    }

    // MARK: - Building Blocks

    private func panelCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.syncPanelRaised.opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.syncLine, lineWidth: 1)
            )
    }

    private func chooseLandingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where received files are saved"
        panel.directoryURL = IncomingFileServer.landingFolder()
        if panel.runModal() == .OK, let url = panel.url {
            IncomingFileServer.setLandingFolder(url)
        }
    }

    private func quickInfo(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.syncAccent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }
}
