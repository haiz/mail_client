import Foundation
import UserNotifications

/// Handles macOS notifications for new mail.
final class NotificationManager: NSObject, @unchecked Sendable {

    static let shared = NotificationManager()

    private override init() {
        super.init()
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                print("Notification permission error: \(error)")
            }
        }
    }

    func notifyNewEmail(sender: String, subject: String) {
        let content = UNMutableNotificationContent()
        content.title = sender
        content.body = subject
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }

    func clearBadge() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
