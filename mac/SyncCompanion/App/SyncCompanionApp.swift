import SwiftUI
import AppKit
import CoreGraphics
import UserNotifications

@main
struct SyncCompanionApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var eventMonitor: Any?
    private var wakeObserver: Any?

    private var sessionState: SessionState!
    private var connectionManager: ConnectionManager!

    private(set) static var dockIcon: NSImage?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        sessionState = SessionState()
        connectionManager = ConnectionManager(sessionState: sessionState)

        let icon = makeDockIcon()
        AppDelegate.dockIcon = icon
        NSApp.applicationIconImage = icon

        buildStatusItem()
        buildPopover()

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }

        UNUserNotificationCenter.current().delegate = self
        NotificationManager.setupCategories()
        NotificationManager.requestPermission()

        connectionManager.start()
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
        button.image?.isTemplate = false
        button.contentTintColor = .white
        button.action = #selector(togglePopover)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        let dropView = DropTargetView()
        dropView.autoresizingMask = [.width, .height]
        dropView.frame = button.bounds
        dropView.isConnected = { [weak self] in
            guard let self else { return false }
            if case .connected = self.sessionState.status { return true }
            return false
        }
        dropView.onDrop = { [weak self] urls in
            self?.connectionManager.quickSend(urls: urls)
        }
        dropView.onHighlight = { [weak self] _ in
            self?.statusItem?.button?.contentTintColor = .white
        }
        button.addSubview(dropView)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if let pop = popover, pop.isShown {
            closePopover()
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let window = popover?.contentViewController?.view.window {
                window.level = .statusBar
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
                window.makeKey()
            }
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
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let button = self.statusItem?.button else { return }
                if let transfer = self.sessionState.incomingTransfer {
                    button.title = " \(Int(transfer.progress * 100))%"
                    button.contentTintColor = .white
                } else {
                    button.title = ""
                    button.contentTintColor = .white
                }
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

    // MARK: - UNUserNotificationCenterDelegate

    // Show notifications even when the app is in the foreground (e.g. file manager open)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            NotificationManager.handleAction(
                identifier: response.actionIdentifier,
                userInfo: response.notification.request.content.userInfo
            )
        }
        completionHandler()
    }

    // MARK: - Dock icon

    private func makeDockIcon() -> NSImage {
        let s: CGFloat = 512
        let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            let fur      = NSColor(white: 0.10, alpha: 1)
            let innerEar = NSColor(red: 0.35, green: 0.09, blue: 0.09, alpha: 1)
            let amber    = NSColor(red: 1.00, green: 0.55, blue: 0.00, alpha: 1)
            let pupil    = NSColor(white: 0.04, alpha: 1)
            let nose     = NSColor(red: 0.73, green: 0.19, blue: 0.19, alpha: 1)

            // Navy background with rounded corners
            let bg = NSBezierPath(roundedRect: rect, xRadius: 112, yRadius: 112)
            NSColor(red: 0.051, green: 0.106, blue: 0.165, alpha: 1).setFill()
            bg.fill()

            // ── Ears ──────────────────────────────────────────────────────
            fur.setFill()
            let lEar = NSBezierPath()
            lEar.move(to: NSPoint(x: 110, y: 295))
            lEar.line(to: NSPoint(x: 82,  y: 420))
            lEar.line(to: NSPoint(x: 215, y: 355))
            lEar.close(); lEar.fill()
            let rEar = NSBezierPath()
            rEar.move(to: NSPoint(x: 402, y: 295))
            rEar.line(to: NSPoint(x: 430, y: 420))
            rEar.line(to: NSPoint(x: 297, y: 355))
            rEar.close(); rEar.fill()

            // ── Head ──────────────────────────────────────────────────────
            fur.setFill()
            NSBezierPath(ovalIn: NSRect(x: 96, y: 65, width: 320, height: 290)).fill()

            // ── Inner ears ────────────────────────────────────────────────
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

            // ── Eyes ──────────────────────────────────────────────────────
            amber.setFill()
            NSBezierPath(ovalIn: NSRect(x: 148, y: 222, width: 90, height: 64)).fill()
            NSBezierPath(ovalIn: NSRect(x: 274, y: 222, width: 90, height: 64)).fill()
            pupil.setFill()
            NSBezierPath(roundedRect: NSRect(x: 186, y: 212, width: 16, height: 84), xRadius: 7, yRadius: 7).fill()
            NSBezierPath(roundedRect: NSRect(x: 312, y: 212, width: 16, height: 84), xRadius: 7, yRadius: 7).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 155, y: 268, width: 13, height: 13)).fill()
            NSBezierPath(ovalIn: NSRect(x: 281, y: 268, width: 13, height: 13)).fill()

            // ── Nose ──────────────────────────────────────────────────────
            nose.setFill()
            let nosePath = NSBezierPath()
            nosePath.move(to:  NSPoint(x: 256, y: 206))
            nosePath.line(to:  NSPoint(x: 274, y: 188))
            nosePath.line(to:  NSPoint(x: 256, y: 172))
            nosePath.line(to:  NSPoint(x: 238, y: 188))
            nosePath.close(); nosePath.fill()

            // ── Whiskers ──────────────────────────────────────────────────
            NSColor(white: 0.55, alpha: 0.45).setStroke()
            let w = NSBezierPath(); w.lineWidth = 1.8
            w.move(to: NSPoint(x: 228, y: 182)); w.line(to: NSPoint(x: 80,  y: 196))
            w.move(to: NSPoint(x: 228, y: 172)); w.line(to: NSPoint(x: 80,  y: 160))
            w.move(to: NSPoint(x: 284, y: 182)); w.line(to: NSPoint(x: 432, y: 196))
            w.move(to: NSPoint(x: 284, y: 172)); w.line(to: NSPoint(x: 432, y: 160))
            w.stroke()

            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Drop target overlay for status bar button

/// Transparent overlay placed over the status bar button.
/// `hitTest` returns `nil` so mouse clicks pass through to the button underneath,
/// while drag events are still received by this view via NSDraggingDestination.
private final class DropTargetView: NSView {

    var isConnected: (() -> Bool)?
    var onDrop: (([URL]) -> Void)?
    var onHighlight: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isConnected?() == true,
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        else { return [] }
        onHighlight?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHighlight?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onHighlight?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?
            .compactMap { $0 as? URL } ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
