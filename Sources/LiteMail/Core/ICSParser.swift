import Foundation

struct ICSEvent: Sendable {
    var summary: String?
    var start: Date?
    var end: Date?
    var location: String?
    var organizer: String?
    var rrule: String?
}

enum ICSParser {

    static func parse(_ data: Data) -> [ICSEvent] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }
        let unfolded = text
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")

        var result: [ICSEvent] = []
        var current: ICSEvent?
        let lines = unfolded.components(separatedBy: .newlines)

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.uppercased() == "BEGIN:VEVENT" {
                current = ICSEvent()
            } else if line.uppercased() == "END:VEVENT" {
                if let event = current { result.append(event) }
                current = nil
            } else if var event = current {
                let (rawName, value) = splitProperty(line)
                let name = rawName.uppercased().components(separatedBy: ";").first ?? rawName.uppercased()
                switch name {
                case "SUMMARY":
                    event.summary = unescape(value)
                case "DTSTART", "DTSTART;VALUE=DATE":
                    event.start = parseDate(value, params: rawName)
                case "DTEND", "DTEND;VALUE=DATE":
                    event.end = parseDate(value, params: rawName)
                case "LOCATION":
                    event.location = unescape(value)
                case "ORGANIZER":
                    // Organizer is typically MAILTO:email@example.com
                    event.organizer = value.hasPrefix("MAILTO:") ? String(value.dropFirst(7)) : value
                case "RRULE":
                    event.rrule = value
                default:
                    break
                }
                current = event
            }
        }
        return result
    }

    private static func splitProperty(_ line: String) -> (name: String, value: String) {
        guard let colonIdx = line.firstIndex(of: ":") else { return (line, "") }
        let name = String(line[line.startIndex..<colonIdx])
        let value = String(line[line.index(after: colonIdx)...])
        return (name, value)
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func parseDate(_ value: String, params: String) -> Date? {
        let cleanParams = params.uppercased()
        // All-day: DTSTART;VALUE=DATE:20260101
        if cleanParams.contains("VALUE=DATE") || (value.count == 8 && !value.contains("T")) {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd"
            fmt.timeZone = TimeZone(identifier: "UTC")
            return fmt.date(from: value)
        }
        // UTC: 20260101T120000Z
        if value.hasSuffix("Z") {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            fmt.timeZone = TimeZone(identifier: "UTC")
            return fmt.date(from: value)
        }
        // Floating: 20260101T120000
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss"
        fmt.timeZone = TimeZone.current
        return fmt.date(from: value)
    }
}
