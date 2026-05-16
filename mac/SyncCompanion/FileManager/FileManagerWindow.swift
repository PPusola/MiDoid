import AppKit
import SwiftUI

@MainActor
final class FileManagerWindow: NSObject, NSWindowDelegate {
    static let shared = FileManagerWindow()

    private var window: NSWindow?

    func open(ip: String, port: Int, token: String) {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let client = WebDavClient(ip: ip, port: port, token: token)
        let vm     = FileBrowserViewModel(client: client)
        let hc     = NSHostingController(rootView: FileBrowserView(viewModel: vm))
        let w      = NSWindow(contentViewController: hc)
        w.title = "Android Files — \(ip)"
        w.setContentSize(NSSize(width: 720, height: 520))
        w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        w.delegate = self
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
