import Foundation

/// Rewrites remote `http(s)://` image URLs in HTML to `data-blocked-src` placeholders,
/// leaving `cid:` and `data:` URLs untouched. Returns the sanitized HTML and a count
/// of how many URLs were blocked.
enum RemoteImageSanitizer {

    static func sanitize(_ html: String, blockImages: Bool) -> (html: String, blockedCount: Int) {
        guard blockImages else { return (html, 0) }

        var result = html
        var blockedCount = 0

        // Block <img src="http..."> and <img src='http...'>
        result = replaceAll(
            in: result,
            pattern: #"(<img\b[^>]*?\s)src=(["'])(https?://[^"']+)\2"#,
            replacement: { match in
                blockedCount += 1
                return "\(match[1])src=\(match[2])data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7\(match[2]) data-blocked-src=\(match[2])\(match[3])\(match[2])"
            }
        )

        // Block srcset="http..."
        result = replaceAll(
            in: result,
            pattern: #"\bsrcset=(["'])(https?://[^"']+)\1"#,
            replacement: { match in
                blockedCount += 1
                return "data-blocked-srcset=\(match[1])\(match[2])\(match[1])"
            }
        )

        // Block <video poster="http...">
        result = replaceAll(
            in: result,
            pattern: #"\bposter=(["'])(https?://[^"']+)\1"#,
            replacement: { match in
                blockedCount += 1
                return "data-blocked-poster=\(match[1])\(match[2])\(match[1])"
            }
        )

        // Block url(http...) in inline style attributes
        result = replaceAll(
            in: result,
            pattern: #"url\((["']?)(https?://[^)'"]+)\1\)"#,
            replacement: { match in
                blockedCount += 1
                return "url(data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7)"
            }
        )

        return (result, blockedCount)
    }

    // MARK: - Helpers

    private static func replaceAll(
        in input: String,
        pattern: String,
        replacement: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return input
        }
        let nsInput = input as NSString
        let range = NSRange(location: 0, length: nsInput.length)
        var output = input
        var offset = 0

        let matches = regex.matches(in: input, range: range)
        for match in matches {
            var groups: [String] = []
            for i in 0..<match.numberOfRanges {
                let r = match.range(at: i)
                groups.append(r.location != NSNotFound ? nsInput.substring(with: r) : "")
            }
            let rep = replacement(groups)
            let adjustedRange = NSRange(location: match.range.location + offset, length: match.range.length)
            output = (output as NSString).replacingCharacters(in: adjustedRange, with: rep)
            offset += rep.count - match.range.length
        }
        return output
    }
}
