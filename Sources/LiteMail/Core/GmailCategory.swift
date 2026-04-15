/// The closed set of Gmail Inbox categories. Each Gmail message in the inbox
/// belongs to exactly one of these (or to none, treated as Personal/Primary).
///
/// Stored in `emails.gmail_category` as the raw value. Surfaced in the sidebar
/// as virtual folders with IDs like `gmail:category:promotions`.
enum GmailCategory: String, CaseIterable, Sendable {
    case personal
    case promotions
    case social
    case updates
    case forums
    case purchases

    /// Gmail API system label ID corresponding to this category.
    var labelId: String {
        switch self {
        case .personal:   return "CATEGORY_PERSONAL"
        case .promotions: return "CATEGORY_PROMOTIONS"
        case .social:     return "CATEGORY_SOCIAL"
        case .updates:    return "CATEGORY_UPDATES"
        case .forums:     return "CATEGORY_FORUMS"
        case .purchases:  return "CATEGORY_PURCHASES"
        }
    }

    /// Token used in Gmail's `q=category:<token>` search syntax.
    /// Note: Gmail accepts "primary" (not "personal") in search.
    var searchToken: String {
        switch self {
        case .personal: return "primary"
        case .promotions, .social, .updates, .forums, .purchases:
            return rawValue
        }
    }

    /// Virtual folder ID surfaced in the sidebar. Prefixed `gmail:` to avoid
    /// collision with IMAP mailbox paths and JMAP mailbox UUIDs.
    var virtualFolderId: String { "gmail:category:\(rawValue)" }

    /// Inverse of `virtualFolderId`. Returns nil for unrecognized IDs.
    init?(virtualFolderId id: String) {
        let prefix = "gmail:category:"
        guard id.hasPrefix(prefix) else { return nil }
        let raw = String(id.dropFirst(prefix.count))
        guard let c = GmailCategory(rawValue: raw) else { return nil }
        self = c
    }
}
