import AppKit
import SwiftUI

@MainActor
final class FileManagerWindow: NSObject, NSWindowDelegate {
    static let shared = FileManagerWindow()

    private var window: NSWindow?
    private var viewModel: FileBrowserViewModel?

    var isOpen: Bool { window != nil }

    func bringToFront() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func open(ip: String, port: Int, token: String) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let client = WebDavClient(ip: ip, port: port, token: token)
        let vm     = FileBrowserViewModel(client: client)
        viewModel  = vm
        let hc     = NSHostingController(rootView: FileBrowserView(viewModel: vm))
        let w      = NSWindow(contentViewController: hc)
        w.title = "MiDoid - Android Files"
        w.subtitle = ip
        w.setContentSize(NSSize(width: 960, height: 600))
        w.minSize = NSSize(width: 680, height: 440)
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.toolbarStyle = .unifiedCompact
        w.tabbingMode = .preferred
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = AppDelegate.dockIcon
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func prepareUpload(urls: [URL]) {
        viewModel?.prepareUploadFiles(urls)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        FileBrowserViewModel.pendingRetries = viewModel?.transferQueue.filter { $0.state == .failed } ?? []
        window = nil
        viewModel = nil
        NSApp.setActivationPolicy(.accessory)
    }
}
