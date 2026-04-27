import Foundation

struct SearchPredicate: Sendable {
    enum Kind: Sendable {
        case from, to, cc, subject, hasAttachment, before, after, inFolder, isUnread, isStarred
    }
    let kind: Kind
    let value: String
}

struct ParsedQuery: Sendable {
    let ftsQuery: String?
    let predicates: [SearchPredicate]
    let chips: [String]
}

enum SearchQueryParser {

    static func parse(_ raw: String, now: Date = Date()) -> ParsedQuery {
        var ftsTokens: [String] = []
        var predicates: [SearchPredicate] = []
        var chips: [String] = []

        var remaining = raw.trimmingCharacters(in: .whitespaces)

        while !remaining.isEmpty {
            if let (pred, chip, rest) = extractOperator(remaining, now: now) {
                predicates.append(pred)
                chips.append(chip)
                remaining = rest.trimmingCharacters(in: .whitespaces)
            } else {
                // Consume a regular word or quoted string as FTS
                if remaining.hasPrefix("\"") {
                    let (token, rest) = extractQuoted(remaining)
                    ftsTokens.append("\"\(token)\"")
                    remaining = rest.trimmingCharacters(in: .whitespaces)
                } else {
                    let parts = remaining.split(separator: " ", maxSplits: 1)
                    ftsTokens.append(String(parts[0]))
                    remaining = parts.count > 1 ? String(parts[1]) : ""
                }
            }
        }

        let fts = ftsTokens.isEmpty ? nil : ftsTokens.joined(separator: " ")
        return ParsedQuery(ftsQuery: fts, predicates: predicates, chips: chips)
    }

    private static let cal = Calendar.current

    private static func extractOperator(_ input: String, now: Date) -> (SearchPredicate, chip: String, rest: String)? {
        let lower = input.lowercased()
        let prefixes: [(String, (String) -> (SearchPredicate?, String))] = [
            ("from:", { self.parseKV($0, kind: .from) }),
            ("to:", { self.parseKV($0, kind: .to) }),
            ("cc:", { self.parseKV($0, kind: .cc) }),
            ("subject:", { self.parseKV($0, kind: .subject) }),
            ("in:", { self.parseKV($0, kind: .inFolder) }),
            ("before:", { self.parseDate($0, kind: .before, now: now) }),
            ("after:", { self.parseDate($0, kind: .after, now: now) }),
            ("older_than:", { self.parseDuration($0, kind: .before, now: now) }),
            ("newer_than:", { self.parseDuration($0, kind: .after, now: now) }),
            ("has:", { s in
                let (val, rest) = self.extractWord(s)
                if val == "attachment" {
                    return (SearchPredicate(kind: .hasAttachment, value: "1"), rest)
                }
                return (nil, s)
            }),
            ("is:", { s in
                let (val, rest) = self.extractWord(s)
                switch val.lowercased() {
                case "unread": return (SearchPredicate(kind: .isUnread, value: "1"), rest)
                case "starred": return (SearchPredicate(kind: .isStarred, value: "1"), rest)
                default: return (nil, s)
                }
            }),
        ]

        for (prefix, handler) in prefixes {
            if lower.hasPrefix(prefix) {
                let afterPrefix = String(input.dropFirst(prefix.count))
                let (pred, rest) = handler(afterPrefix)
                if let pred {
                    return (pred, "\(prefix)\(String(input.dropFirst(prefix.count).prefix(rest.isEmpty ? 999 : input.dropFirst(prefix.count).count - rest.count)))", rest)
                }
            }
        }
        return nil
    }

    private static func parseKV(_ input: String, kind: SearchPredicate.Kind) -> (SearchPredicate?, String) {
        var (value, rest) = extractWordOrQuoted(input)
        if value.isEmpty { return (nil, input) }
        return (SearchPredicate(kind: kind, value: value), rest)
    }

    private static func parseDate(_ input: String, kind: SearchPredicate.Kind, now: Date) -> (SearchPredicate?, String) {
        let (value, rest) = extractWord(input)
        guard !value.isEmpty else { return (nil, input) }
        // ISO: 2026/01/01 or 2026-01-01
        let normalized = value.replacingOccurrences(of: "/", with: "-")
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        if let date = fmt.date(from: normalized) {
            return (SearchPredicate(kind: kind, value: String(Int(date.timeIntervalSince1970))), rest)
        }
        return (nil, input)
    }

    private static func parseDuration(_ input: String, kind: SearchPredicate.Kind, now: Date) -> (SearchPredicate?, String) {
        let (value, rest) = extractWord(input)
        guard !value.isEmpty else { return (nil, input) }
        let lower = value.lowercased()
        var days: Int?
        if lower.hasSuffix("d"), let n = Int(lower.dropLast()) { days = n }
        else if lower.hasSuffix("w"), let n = Int(lower.dropLast()) { days = n * 7 }
        else if lower.hasSuffix("m"), let n = Int(lower.dropLast()) { days = n * 30 }
        guard let d = days else { return (nil, input) }
        let target = cal.date(byAdding: .day, value: -d, to: now) ?? now
        return (SearchPredicate(kind: kind, value: String(Int(target.timeIntervalSince1970))), rest)
    }

    private static func extractWord(_ input: String) -> (String, String) {
        let parts = input.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
    }

    private static func extractQuoted(_ input: String) -> (String, String) {
        guard input.hasPrefix("\"") else { return extractWord(input) }
        let after = input.dropFirst()
        if let end = after.firstIndex(of: "\"") {
            return (String(after[after.startIndex..<end]), String(after[after.index(after: end)...]))
        }
        return (String(after), "")
    }

    private static func extractWordOrQuoted(_ input: String) -> (String, String) {
        if input.hasPrefix("\"") { return extractQuoted(input) }
        return extractWord(input)
    }
}
