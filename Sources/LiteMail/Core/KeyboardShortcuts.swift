import AppKit

struct Shortcut: Sendable {
    let id: String
    let key: String
    let modifiers: NSEvent.ModifierFlags
    let label: String
    let section: String
}

enum ShortcutAction: Sendable {
    case nextMessage
    case prevMessage
    case openMessage
    case archive
    case delete
    case reply
    case replyAll
    case forward
    case toggleStar
    case markSpam
    case markUnread
    case gotoInbox
    case gotoSent
    case gotoAll
    case focusSearch
    case showCheatSheet
}

enum KeyboardShortcuts {

    static let all: [(Shortcut, ShortcutAction)] = [
        (Shortcut(id: "next", key: "j", modifiers: [], label: "Next message", section: "Navigation"),
         .nextMessage),
        (Shortcut(id: "prev", key: "k", modifiers: [], label: "Previous message", section: "Navigation"),
         .prevMessage),
        (Shortcut(id: "open", key: "\r", modifiers: [], label: "Open message", section: "Navigation"),
         .openMessage),
        (Shortcut(id: "archive", key: "e", modifiers: [], label: "Archive", section: "Actions"),
         .archive),
        (Shortcut(id: "delete", key: "#", modifiers: [], label: "Delete", section: "Actions"),
         .delete),
        (Shortcut(id: "reply", key: "r", modifiers: [], label: "Reply", section: "Compose"),
         .reply),
        (Shortcut(id: "replyAll", key: "a", modifiers: [], label: "Reply all", section: "Compose"),
         .replyAll),
        (Shortcut(id: "forward", key: "f", modifiers: [], label: "Forward", section: "Compose"),
         .forward),
        (Shortcut(id: "star", key: "s", modifiers: [], label: "Toggle star", section: "Actions"),
         .toggleStar),
        (Shortcut(id: "spam", key: "!", modifiers: [], label: "Mark as spam", section: "Actions"),
         .markSpam),
        (Shortcut(id: "unread", key: "u", modifiers: [], label: "Mark as unread", section: "Actions"),
         .markUnread),
        (Shortcut(id: "gotoInbox", key: "i", modifiers: [], label: "Go to Inbox (g i)", section: "Go To"),
         .gotoInbox),
        (Shortcut(id: "gotoSent", key: "t", modifiers: [], label: "Go to Sent (g t)", section: "Go To"),
         .gotoSent),
        (Shortcut(id: "gotoAll", key: "a", modifiers: [], label: "Go to All Mail (g a)", section: "Go To"),
         .gotoAll),
        (Shortcut(id: "search", key: "/", modifiers: [], label: "Focus search", section: "Navigation"),
         .focusSearch),
        (Shortcut(id: "cheatSheet", key: "?", modifiers: [], label: "Show shortcuts (?)", section: "Navigation"),
         .showCheatSheet),
    ]

    /// Matches an NSEvent to a ShortcutAction.
    /// Handles 2-key chords: `g i` (inbox), `g t` (sent), `g a` (all mail).
    /// `pendingPrefix` holds the first key of a chord; cleared after a match or 1.2 s.
    static func match(event: NSEvent, pendingPrefix: inout String?) -> ShortcutAction? {
        let ch = event.charactersIgnoringModifiers ?? ""
        guard !ch.isEmpty else { return nil }
        let mods = event.modifierFlags.intersection([.command, .option, .shift, .control])

        // Chord resolution
        if let prefix = pendingPrefix {
            pendingPrefix = nil
            if prefix == "g" {
                switch ch {
                case "i": return .gotoInbox
                case "t": return .gotoSent
                case "a": return .gotoAll
                default: return nil
                }
            }
        }

        // Start chord on bare "g"
        if ch == "g" && mods.isEmpty {
            pendingPrefix = "g"
            return nil
        }

        // Single-key matches (no modifiers)
        guard mods.isEmpty else { return nil }
        for (shortcut, action) in all {
            if shortcut.key == ch && shortcut.modifiers == [] {
                // Skip go-to shortcuts here — they only work via chord
                switch action {
                case .gotoInbox, .gotoSent, .gotoAll: continue
                default: break
                }
                return action
            }
        }
        return nil
    }
}
