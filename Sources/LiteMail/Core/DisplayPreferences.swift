// Sources/LiteMail/Core/DisplayPreferences.swift
import Foundation

/// Display-related user preferences backed by UserDefaults.
enum DisplayPreferences {
    /// UserDefaults key for the number of emails rendered in the message list.
    static let emailListLimitDefaultsKey = "emailListLimit"

    /// Allowed preset values for the emails-per-page dropdown.
    /// Validated on read so a corrupted value falls back to the default.
    static let emailListLimitPresets: [Int] = [25, 50, 100, 200, 500]

    /// Default number of emails shown in the message list.
    static let defaultEmailListLimit: Int = 50

    /// Current emails-per-page setting. Falls back to the default when the stored
    /// value is missing or not one of the accepted presets.
    static var emailListLimit: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: emailListLimitDefaultsKey)
            return emailListLimitPresets.contains(stored) ? stored : defaultEmailListLimit
        }
        set {
            UserDefaults.standard.set(newValue, forKey: emailListLimitDefaultsKey)
            NotificationCenter.default.post(name: .emailListLimitChanged, object: nil)
        }
    }
}

extension Notification.Name {
    /// Posted when `DisplayPreferences.emailListLimit` changes so the message list can refresh.
    static let emailListLimitChanged = Notification.Name("LiteMail.emailListLimitChanged")
}
