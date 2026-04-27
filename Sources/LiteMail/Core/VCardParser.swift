import Foundation

struct VCard: Sendable {
    var fn: String?
    var emails: [String] = []
    var phones: [String] = []
    var org: String?
}

enum VCardParser {

    static func parse(_ data: Data) -> [VCard] {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }
        // Unfold lines: CRLF followed by whitespace is a continuation
        let unfolded = text
            .replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\n\t", with: "")

        var result: [VCard] = []
        var current: VCard?
        let lines = unfolded.components(separatedBy: .newlines)

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.uppercased() == "BEGIN:VCARD" {
                current = VCard()
            } else if line.uppercased() == "END:VCARD" {
                if let card = current { result.append(card) }
                current = nil
            } else if var card = current {
                let (name, value) = splitProperty(line)
                let upperName = name.uppercased().components(separatedBy: ";").first ?? name.uppercased()
                switch upperName {
                case "FN":
                    card.fn = decodeValue(value)
                case "EMAIL":
                    let email = decodeValue(value)
                    if !email.isEmpty { card.emails.append(email) }
                case "TEL":
                    let phone = decodeValue(value)
                    if !phone.isEmpty { card.phones.append(phone) }
                case "ORG":
                    card.org = decodeValue(value).components(separatedBy: ";").first
                default:
                    break
                }
                current = card
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

    private static func decodeValue(_ value: String) -> String {
        // Basic quoted-printable decode
        if value.uppercased().hasPrefix("ENCODING=QUOTED-PRINTABLE:") || value.contains("=3D") {
            return decodeQP(value.components(separatedBy: ":").dropFirst().joined(separator: ":"))
        }
        return value
    }

    private static func decodeQP(_ input: String) -> String {
        var result = ""
        var i = input.startIndex
        while i < input.endIndex {
            let c = input[i]
            if c == "=" {
                let next = input.index(after: i)
                if next < input.endIndex {
                    let afterNext = input.index(after: next)
                    if afterNext < input.endIndex {
                        let hex = String(input[next...afterNext])
                        if let code = UInt8(hex, radix: 16) {
                            result.append(Character(UnicodeScalar(code)))
                            i = input.index(after: afterNext)
                            continue
                        }
                    }
                }
            }
            result.append(c)
            i = input.index(after: i)
        }
        return result
    }
}
