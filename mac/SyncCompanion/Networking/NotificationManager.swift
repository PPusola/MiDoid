import UserNotifications
import AppKit

@MainActor
enum NotificationManager {

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func setupCategories() {
        let show = UNNotificationAction(
            identifier: "SHOW_IN_FINDER",
            title: "Show in Finder",
            options: .foreground
        )
        let categories: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: "FILE_RECEIVED",   actions: [show], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "FILE_DOWNLOADED", actions: [show], intentIdentifiers: [], options: [])
        ]
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }

    static func fileReceived(name: String, size: Int64, from deviceName: String, at url: URL) {
        let c = UNMutableNotificationContent()
        c.title = "Received from \(deviceName)"
        c.body  = "\(name) · \(formatBytes(size))"
        c.sound = .default
        c.categoryIdentifier = "FILE_RECEIVED"
        c.userInfo = ["url": url.path]
        deliver(c, id: "recv-\(UUID().uuidString)")
    }

    static func fileDownloaded(name: String, size: Int64, at url: URL) {
        let c = UNMutableNotificationContent()
        c.title = "Download complete"
        c.body  = "\(name) · \(formatBytes(size))"
        c.sound = .default
        c.categoryIdentifier = "FILE_DOWNLOADED"
        c.userInfo = ["url": url.path]
        deliver(c, id: "dl-\(UUID().uuidString)")
    }

    static func handleAction(identifier: String, userInfo: [AnyHashable: Any]) {
        guard (identifier == "SHOW_IN_FINDER" || identifier == UNNotificationDefaultActionIdentifier),
              let path = userInfo["url"] as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Private

    private static func deliver(_ content: UNMutableNotificationContent, id: String) {
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil),
            withCompletionHandler: nil
        )
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let d = Double(bytes)
        if d < 1_024          { return "\(bytes) B" }
        if d < 1_048_576      { return String(format: "%.1f KB", d / 1_024) }
        if d < 1_073_741_824  { return String(format: "%.1f MB", d / 1_048_576) }
        return String(format: "%.2f GB", d / 1_073_741_824)
    }
}
