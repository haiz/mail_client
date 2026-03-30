import Foundation
import UserNotifications

/// Handles macOS notifications for new mail.
final class NotificationManager: NSObject, @unchecked Sendable {

    static let shared = NotificationManager()

    private override init() {
        super.init()
    }

    private var isAvailable: Bool {
        // UNUserNotificationCenter requires a bundled app with Info.plist
        Bundle.main.bundleIdentifier != nil
    }

    func requestPermission() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("Notification permission error: \(error)")
            }
        }
    }

    func notifyNewEmail(sender: String, subject: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = sender
        content.body = subject
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    func clearBadge() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
