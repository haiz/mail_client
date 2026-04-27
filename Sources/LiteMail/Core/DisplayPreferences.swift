import Foundation

enum RemoteImagePolicy: String {
    case blockAll = "block_all"
    case blockUnknown = "block_unknown"
    case allowAll = "allow_all"
}

enum BodyRendering: String {
    case auto
    case html
    case plain
}

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

    static let bodyRenderingDefaultsKey = "bodyRendering"

    static var bodyRendering: BodyRendering {
        get {
            let raw = UserDefaults.standard.string(forKey: bodyRenderingDefaultsKey) ?? ""
            return BodyRendering(rawValue: raw) ?? .auto
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: bodyRenderingDefaultsKey)
            NotificationCenter.default.post(name: .bodyRenderingChanged, object: nil)
        }
    }

    static let remoteImagePolicyDefaultsKey = "remoteImagePolicy"

    static var remoteImagePolicy: RemoteImagePolicy {
        get {
            let raw = UserDefaults.standard.string(forKey: remoteImagePolicyDefaultsKey) ?? ""
            return RemoteImagePolicy(rawValue: raw) ?? .blockUnknown
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: remoteImagePolicyDefaultsKey)
            NotificationCenter.default.post(name: .remoteImagePolicyChanged, object: nil)
        }
    }
}

extension Notification.Name {
    static let emailListLimitChanged = Notification.Name("LiteMail.emailListLimitChanged")
    static let remoteImagePolicyChanged = Notification.Name("LiteMail.remoteImagePolicyChanged")
    static let bodyRenderingChanged = Notification.Name("LiteMail.bodyRenderingChanged")
}
