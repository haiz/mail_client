import XCTest
@testable import LiteMail

// Intercepts URLSession requests in tests
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let (data, response) = Self.handler?(request) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ContactsStoreTests: XCTestCase {
    var mailStore: MailStore!
    var urlSession: URLSession!

    override func setUpWithError() throws {
        mailStore = try MailStore(path: ":memory:")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        urlSession = URLSession(configuration: config)
    }

    /// Seeds the account referenced by tests. Contacts table has a FK on accounts.id.
    private func insertAccount(id: String) async throws {
        let record = AccountRecord(
            id: id, emailAddress: "\(id)@test.com",
            protocolType: "imap", authType: "oauth2",
            keychainRef: "test-\(id)", isDefault: false
        )
        try await mailStore.insertAccount(record)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchAndStoreWritesContactsToDatabase() async throws {
        try await insertAccount(id: "acc1")
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let body = """
            {
              "connections": [
                {
                  "resourceName": "people/c1",
                  "names": [{"displayName": "Alice Test"}],
                  "emailAddresses": [{"value": "alice@test.com"}],
                  "photos": [{"url": "https://example.com/photo.jpg"}]
                }
              ]
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }

        let store = ContactsStore(mailStore: mailStore, tokenProvider: StubTokenProvider(), urlSession: urlSession)
        await store.fetchAndStore(accountId: "acc1")

        let results = try await mailStore.lookupContacts(prefix: "alice", accountId: "acc1")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.name, "Alice Test")
        XCTAssertEqual(results.first?.email, "alice@test.com")
        XCTAssertEqual(results.first?.photoURL, "https://example.com/photo.jpg")
    }

    func testFetchAndStoreHandlesPagination() async throws {
        try await insertAccount(id: "acc1")
        var callCount = 0
        MockURLProtocol.handler = { _ in
            callCount += 1
            let nextToken = callCount == 1 ? #","nextPageToken":"page2""# : ""
            let body = """
            {"connections":[{"resourceName":"people/c\(callCount)","names":[{"displayName":"Person \(callCount)"}],"emailAddresses":[{"value":"p\(callCount)@test.com"}]}]\(nextToken)}
            """.data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://people.googleapis.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (body, resp)
        }

        let store = ContactsStore(mailStore: mailStore, tokenProvider: StubTokenProvider(), urlSession: urlSession)
        await store.fetchAndStore(accountId: "acc1")

        XCTAssertEqual(callCount, 2)
        let all = try await mailStore.lookupContacts(prefix: "p", accountId: "acc1")
        XCTAssertEqual(all.count, 2)
    }

    func testFetchAndStoreIsNonFatalOnHTTPError() async throws {
        try await insertAccount(id: "acc1")
        MockURLProtocol.handler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (Data(), resp)
        }

        let store = ContactsStore(mailStore: mailStore, tokenProvider: StubTokenProvider(), urlSession: urlSession)
        await store.fetchAndStore(accountId: "acc1")  // must not throw

        let results = try await mailStore.lookupContacts(prefix: "", accountId: "acc1")
        XCTAssertTrue(results.isEmpty)
    }
}

private struct StubTokenProvider: TokenProvider {
    func oauthAccessToken(accountId: String) async throws -> String {
        return "test-token"
    }
}
