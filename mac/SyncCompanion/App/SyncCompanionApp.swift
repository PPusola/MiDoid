import SwiftUI
import AppKit

@main
struct SyncCompanionApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?

    private var sessionState: SessionState!
    private var connectionManager: ConnectionManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        sessionState = SessionState()
        connectionManager = ConnectionManager(sessionState: sessionState)

        buildStatusItem()
        buildPopover()

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }

        connectionManager.generateSession()
        startIconSync()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
        FileManagerWindow.shared.close()
    }

    // MARK: - Status item

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: Icons.phone, accessibilityDescription: "MiDoid")
        button.image?.isTemplate = true
        button.action = #selector(togglePopover)
        button.target = self
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let pop = popover, pop.isShown {
            closePopover()
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover?.contentViewController?.view.window?.makeKey()
        }
    }

    private func closePopover() {
        popover?.performClose(nil)
    }

    // MARK: - Popover

    private func buildPopover() {
        let content = MenuBarView(state: sessionState, manager: connectionManager)
        let hc = NSHostingController(rootView: content)
        hc.sizingOptions = []
        let pop = NSPopover()
        pop.contentViewController = hc
        pop.contentSize = NSSize(width: 260, height: 340)
        pop.behavior = .semitransient
        pop.animates = true
        popover = pop
    }

    // MARK: - Icon tint sync

    private func startIconSync() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem?.button else { return }
            DispatchQueue.main.async {
                button.contentTintColor = self.sessionState.menuBarTint
            }
        }
    }
}
