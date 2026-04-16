import XCTest
@testable import LiteMail

final class GmailAPIClientTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GmailMockURLProtocol.self]
        session = URLSession(configuration: config)
        GmailMockURLProtocol.handlers.removeAll()
    }

    override func tearDown() {
        GmailMockURLProtocol.handlers.removeAll()
        session = nil
    }

    func testListMessageIdsBuildsCorrectURL() async throws {
        var capturedURL: URL?
        GmailMockURLProtocol.handlers["/gmail/v1/users/me/messages"] = { request in
            capturedURL = request.url
            let body = #"{"messages":[{"id":"abc","threadId":"t1"}]}"#.data(using: .utf8)!
            return (body, 200, ["Content-Type": "application/json"])
        }

        let client = GmailAPIClient(session: session)
        let ids = try await client.listMessageIds(
            query: "category:promotions label:inbox newer_than:30d",
            maxResults: 500,
            accessToken: "test-token"
        )
        XCTAssertEqual(ids, ["abc"])

        let url = try XCTUnwrap(capturedURL)
        XCTAssertEqual(url.host, "gmail.googleapis.com")
        XCTAssertEqual(url.path, "/gmail/v1/users/me/messages")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let q = Dictionary(uniqueKeysWithValues: comps.queryItems!.map { ($0.name, $0.value) })
        XCTAssertEqual(q["q"], "category:promotions label:inbox newer_than:30d")
        XCTAssertEqual(q["maxResults"], "500")
    }

    func testListMessageIdsSendsAuthHeader() async throws {
        var capturedAuth: String?
        GmailMockURLProtocol.handlers["/gmail/v1/users/me/messages"] = { request in
            capturedAuth = request.value(forHTTPHeaderField: "Authorization")
            return (#"{"messages":[]}"#.data(using: .utf8)!, 200, [:])
        }

        let client = GmailAPIClient(session: session)
        _ = try await client.listMessageIds(
            query: "category:primary", maxResults: 500, accessToken: "abc-token"
        )
        XCTAssertEqual(capturedAuth, "Bearer abc-token")
    }

    func testListMessageIdsHandlesEmptyResponse() async throws {
        GmailMockURLProtocol.handlers["/gmail/v1/users/me/messages"] = { _ in
            (#"{}"#.data(using: .utf8)!, 200, [:])
        }
        let client = GmailAPIClient(session: session)
        let ids = try await client.listMessageIds(query: "x", maxResults: 500, accessToken: "t")
        XCTAssertTrue(ids.isEmpty)
    }

    func testListMessageIdsThrowsOn401() async throws {
        GmailMockURLProtocol.handlers["/gmail/v1/users/me/messages"] = { _ in
            (Data(), 401, [:])
        }
        let client = GmailAPIClient(session: session)
        do {
            _ = try await client.listMessageIds(query: "x", maxResults: 500, accessToken: "t")
            XCTFail("Expected GmailAPIError.unauthorized")
        } catch GmailAPIError.unauthorized {
            // OK
        }
    }

    func testListMessageIdsThrowsOnRateLimit() async throws {
        GmailMockURLProtocol.handlers["/gmail/v1/users/me/messages"] = { _ in
            (Data(), 429, [:])
        }
        let client = GmailAPIClient(session: session)
        do {
            _ = try await client.listMessageIds(query: "x", maxResults: 500, accessToken: "t")
            XCTFail("Expected GmailAPIError.rateLimited")
        } catch GmailAPIError.rateLimited {
            // OK
        }
    }

    func testBatchGetMessageIdsExtractsRfc822MessageIdHeader() async throws {
        let multipart = """
        --batch_xyz\r
        Content-Type: application/http\r
        \r
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        \r
        {"id":"abc","payload":{"headers":[{"name":"Message-Id","value":"<original@example.com>"}]}}\r
        --batch_xyz--\r

        """
        GmailMockURLProtocol.handlers["/batch/gmail/v1"] = { _ in
            (multipart.data(using: .utf8)!, 200, ["Content-Type": "multipart/mixed; boundary=batch_xyz"])
        }

        let client = GmailAPIClient(session: session)
        let mapping = try await client.batchGetMessageIds(ids: ["abc"], accessToken: "t")
        XCTAssertEqual(mapping["abc"], "<original@example.com>")
    }

    func testBatchGetMessageIdsExtractsMultipleParts() async throws {
        let multipart = """
        --batch_xyz\r
        Content-Type: application/http\r
        \r
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        \r
        {"id":"a","payload":{"headers":[{"name":"Message-Id","value":"<msg-a@x>"}]}}\r
        --batch_xyz\r
        Content-Type: application/http\r
        \r
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        \r
        {"id":"b","payload":{"headers":[{"name":"Message-Id","value":"<msg-b@x>"}]}}\r
        --batch_xyz\r
        Content-Type: application/http\r
        \r
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        \r
        {"id":"c","payload":{"headers":[]}}\r
        --batch_xyz--\r

        """
        GmailMockURLProtocol.handlers["/batch/gmail/v1"] = { _ in
            (multipart.data(using: .utf8)!, 200, ["Content-Type": "multipart/mixed; boundary=batch_xyz"])
        }

        let client = GmailAPIClient(session: session)
        let mapping = try await client.batchGetMessageIds(ids: ["a", "b", "c"], accessToken: "t")

        XCTAssertEqual(mapping["a"], "<msg-a@x>")
        XCTAssertEqual(mapping["b"], "<msg-b@x>")
        XCTAssertNil(mapping["c"], "Missing Message-Id header → omitted from map")
    }
}

/// URLProtocol that routes by request path to a stubbed handler.
/// Named GmailMockURLProtocol to avoid collision with MockURLProtocol in ContactsStoreTests.
private final class GmailMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handlers: [String: (URLRequest) -> (Data, Int, [String: String])] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let path = request.url?.path,
              let handler = GmailMockURLProtocol.handlers[path] else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (data, status, headers) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
