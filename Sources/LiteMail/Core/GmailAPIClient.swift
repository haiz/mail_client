import Foundation

/// Errors classified by HTTP status from Gmail REST API.
enum GmailAPIError: Error, Equatable {
    case unauthorized       // 401: token rejected
    case rateLimited        // 429 or 403 quota
    case httpError(Int)     // 4xx (other than 401/403/429) or 5xx
    case badResponse        // unexpected body shape
    case transport(String)  // network/dns/etc, message captured for logs
}

/// Protocol abstraction over the two Gmail REST endpoints used by
/// GmailCategoriesService. Allows test doubles without URLProtocol mocking.
/// Token is passed per call — callers (GmailCategoriesService) own refresh.
protocol GmailAPI: Sendable {
    func listMessageIds(query: String, maxResults: Int, accessToken: String) async throws -> [String]
    func batchGetMessageIds(ids: [String], accessToken: String) async throws -> [String: String]
}

/// Thin Gmail REST API client. No caching, no retry, no token refresh —
/// callers handle policy.
actor GmailAPIClient: GmailAPI {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Issues `GET /gmail/v1/users/me/messages?q=<query>&maxResults=N`.
    /// Returns the list of Gmail message IDs (single page).
    func listMessageIds(query: String, maxResults: Int, accessToken: String) async throws -> [String] {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "gmail.googleapis.com"
        comps.path = "/gmail/v1/users/me/messages"
        comps.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
        ]
        guard let url = comps.url else { throw GmailAPIError.badResponse }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await dataTask(req)
        try Self.classify(response: response)

        struct ListResponse: Decodable {
            let messages: [Item]?
            struct Item: Decodable { let id: String }
        }
        let decoded = try JSONDecoder().decode(ListResponse.self, from: data)
        return (decoded.messages ?? []).map { $0.id }
    }

    /// Issues a `POST /batch/gmail/v1` request wrapping N `messages.get` calls,
    /// each requesting only the `Message-Id` header. Returns a mapping of
    /// Gmail message ID → RFC-822 Message-Id header value. Missing IDs (no
    /// Message-Id in response) are omitted from the map.
    func batchGetMessageIds(ids: [String], accessToken: String) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }

        let boundary = "batch_\(UUID().uuidString)"
        var body = ""
        for id in ids {
            body += "--\(boundary)\r\n"
            body += "Content-Type: application/http\r\n\r\n"
            body += "GET /gmail/v1/users/me/messages/\(id)?format=metadata&metadataHeaders=Message-Id HTTP/1.1\r\n"
            body += "\r\n\r\n"
        }
        body += "--\(boundary)--\r\n"

        var req = URLRequest(url: URL(string: "https://gmail.googleapis.com/batch/gmail/v1")!)
        req.httpMethod = "POST"
        req.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = body.data(using: .utf8)

        let (data, response) = try await dataTask(req)
        try Self.classify(response: response)

        return Self.parseBatchResponse(data: data, response: response)
    }

    // MARK: - Helpers

    private func dataTask(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: req)
        } catch {
            throw GmailAPIError.transport(error.localizedDescription)
        }
    }

    private static func classify(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GmailAPIError.badResponse
        }
        switch http.statusCode {
        case 200..<300: return
        case 401:       throw GmailAPIError.unauthorized
        case 403, 429:  throw GmailAPIError.rateLimited
        default:        throw GmailAPIError.httpError(http.statusCode)
        }
    }

    /// Parses a multipart/mixed batch response into [gmailId: rfc822MessageId].
    /// Tolerant — drops parts that don't include a Message-Id header.
    private static func parseBatchResponse(data: Data, response: URLResponse) -> [String: String] {
        guard let http = response as? HTTPURLResponse,
              let contentType = http.value(forHTTPHeaderField: "Content-Type"),
              let boundary = contentType.split(separator: ";")
                .map({ $0.trimmingCharacters(in: .whitespaces) })
                .first(where: { $0.hasPrefix("boundary=") })
                .map({ raw -> String in
                    let s = String(raw.dropFirst("boundary=".count))
                    if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
                        return String(s.dropFirst().dropLast())
                    }
                    return s
                }),
              let text = String(data: data, encoding: .utf8) else {
            return [:]
        }

        var result: [String: String] = [:]
        let parts = text.components(separatedBy: "--\(boundary)")
        for part in parts {
            // Find the JSON body (after the blank line that follows the inner
            // HTTP/1.1 status + headers).
            guard let jsonStart = part.range(of: "\r\n\r\n{")?.lowerBound else { continue }
            let jsonText = String(part[jsonStart...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let jsonData = jsonText.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(BatchItem.self, from: jsonData) else {
                continue
            }
            let messageIdHeader = parsed.payload?.headers?.first {
                $0.name.lowercased() == "message-id"
            }?.value
            if let header = messageIdHeader {
                result[parsed.id] = header
            }
        }
        return result
    }

    private struct BatchItem: Decodable {
        let id: String
        let payload: Payload?
        struct Payload: Decodable {
            let headers: [Header]?
        }
        struct Header: Decodable {
            let name: String
            let value: String
        }
    }
}
