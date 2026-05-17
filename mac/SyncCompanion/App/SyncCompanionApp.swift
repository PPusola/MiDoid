import SwiftUI
import AppKit
import CoreGraphics

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
    private var wakeObserver: Any?

    private var sessionState: SessionState!
    private var connectionManager: ConnectionManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        sessionState = SessionState()
        connectionManager = ConnectionManager(sessionState: sessionState)

        NSApp.applicationIconImage = makeDockIcon()

        buildStatusItem()
        buildPopover()

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }

        connectionManager.generateSession()
        startIconSync()
        startWakeRecovery()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if FileManagerWindow.shared.isOpen {
            FileManagerWindow.shared.bringToFront()
        } else if let button = statusItem?.button {
            if let pop = popover, !pop.isShown {
                pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                pop.contentViewController?.view.window?.makeKey()
            }
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
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
        pop.contentSize = NSSize(width: 320, height: 360)
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

    private func startWakeRecovery() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.connectionManager.reconnect()
            }
        }
    }

    // MARK: - Dock icon

    private func makeDockIcon() -> NSImage {
        let s: CGFloat = 512
        let image = NSImage(size: NSSize(width: s, height: s))
        image.lockFocus()

        // Navy background
        NSColor(red: 0.051, green: 0.106, blue: 0.165, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: s, height: s).fill()

        let fur      = NSColor(white: 0.10, alpha: 1)
        let innerEar = NSColor(red: 0.35, green: 0.09, blue: 0.09, alpha: 1)
        let amber    = NSColor(red: 1.00, green: 0.55, blue: 0.00, alpha: 1)
        let pupil    = NSColor(white: 0.04, alpha: 1)
        let nose     = NSColor(red: 0.73, green: 0.19, blue: 0.19, alpha: 1)

        // ── Ears ──────────────────────────────────────────────────────────
        fur.setFill()
        // left outer
        let lEar = NSBezierPath()
        lEar.move(to: NSPoint(x: 110, y: 295))
        lEar.line(to: NSPoint(x: 82,  y: 420))
        lEar.line(to: NSPoint(x: 215, y: 355))
        lEar.close(); lEar.fill()
        // right outer
        let rEar = NSBezierPath()
        rEar.move(to: NSPoint(x: 402, y: 295))
        rEar.line(to: NSPoint(x: 430, y: 420))
        rEar.line(to: NSPoint(x: 297, y: 355))
        rEar.close(); rEar.fill()

        // ── Head ──────────────────────────────────────────────────────────
        fur.setFill()
        NSBezierPath(ovalIn: NSRect(x: 96, y: 65, width: 320, height: 290)).fill()

        // ── Inner ears (drawn on top of head) ─────────────────────────────
        innerEar.setFill()
        let lEarI = NSBezierPath()
        lEarI.move(to: NSPoint(x: 128, y: 308))
        lEarI.line(to: NSPoint(x: 106, y: 398))
        lEarI.line(to: NSPoint(x: 206, y: 345))
        lEarI.close(); lEarI.fill()
        let rEarI = NSBezierPath()
        rEarI.move(to: NSPoint(x: 384, y: 308))
        rEarI.line(to: NSPoint(x: 406, y: 398))
        rEarI.line(to: NSPoint(x: 306, y: 345))
        rEarI.close(); rEarI.fill()

        // ── Eyes ──────────────────────────────────────────────────────────
        amber.setFill()
        NSBezierPath(ovalIn: NSRect(x: 148, y: 222, width: 90, height: 64)).fill()
        NSBezierPath(ovalIn: NSRect(x: 274, y: 222, width: 90, height: 64)).fill()

        // vertical slit pupils
        pupil.setFill()
        NSBezierPath(roundedRect: NSRect(x: 186, y: 212, width: 16, height: 84), xRadius: 7, yRadius: 7).fill()
        NSBezierPath(roundedRect: NSRect(x: 312, y: 212, width: 16, height: 84), xRadius: 7, yRadius: 7).fill()

        // shine dots
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: 155, y: 268, width: 13, height: 13)).fill()
        NSBezierPath(ovalIn: NSRect(x: 281, y: 268, width: 13, height: 13)).fill()

        // ── Nose ──────────────────────────────────────────────────────────
        nose.setFill()
        let nosePath = NSBezierPath()
        nosePath.move(to:  NSPoint(x: 256, y: 206))
        nosePath.line(to:  NSPoint(x: 274, y: 188))
        nosePath.line(to:  NSPoint(x: 256, y: 172))
        nosePath.line(to:  NSPoint(x: 238, y: 188))
        nosePath.close(); nosePath.fill()

        // ── Whiskers ──────────────────────────────────────────────────────
        NSColor(white: 0.55, alpha: 0.45).setStroke()
        let w = NSBezierPath(); w.lineWidth = 1.8
        w.move(to: NSPoint(x: 228, y: 182)); w.line(to: NSPoint(x: 80,  y: 196))
        w.move(to: NSPoint(x: 228, y: 172)); w.line(to: NSPoint(x: 80,  y: 160))
        w.move(to: NSPoint(x: 284, y: 182)); w.line(to: NSPoint(x: 432, y: 196))
        w.move(to: NSPoint(x: 284, y: 172)); w.line(to: NSPoint(x: 432, y: 160))
        w.stroke()

        image.unlockFocus()
        return image
    }
}
