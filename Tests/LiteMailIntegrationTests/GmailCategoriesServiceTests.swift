import XCTest
@testable import LiteMail

final class GmailCategoriesServiceTests: XCTestCase {

    private var dbPath: String!
    private var store: MailStore!
    private let accountId = "gmail-test"

    override func setUp() async throws {
        dbPath = NSTemporaryDirectory() + "lm_cat_\(UUID().uuidString).sqlite"
        store = try MailStore(path: dbPath)
        let acc = AccountRecord(
            id: accountId, emailAddress: "user@gmail.com",
            protocolType: "imap", authType: "oauth2",
            keychainRef: "k", isDefault: true
        )
        try await store.insertAccount(acc)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testRefreshAssignsCategoryByMessageId() async throws {
        // Two inbox messages locally, one matched by Gmail as promotions.
        _ = try await store.insertEmail(makeRec(messageId: "<m1@gmail>", uid: 1))
        _ = try await store.insertEmail(makeRec(messageId: "<m2@gmail>", uid: 2))

        let api = StubGmailAPI()
        await api.setCategoryResults(
            promotions: [(gmailId: "g1", messageId: "<m1@gmail>")],
            social: [],
            updates: [],
            forums: [],
            purchases: [],
            personal: [(gmailId: "g2", messageId: "<m2@gmail>")]
        )

        let service = GmailCategoriesService(
            client: api, store: store,
            tokenProvider: StubTokenProvider(token: "test-token")
        )
        try await service.refresh(accountId: accountId)

        let m1 = try await store.fetchHeaders(
            accountId: accountId,
            folder: "gmail:category:promotions",
            offset: 0, limit: 10
        )
        let m2 = try await store.fetchHeaders(
            accountId: accountId,
            folder: "gmail:category:personal",
            offset: 0, limit: 10
        )
        XCTAssertEqual(m1.first?.messageId, "<m1@gmail>")
        XCTAssertEqual(m2.first?.messageId, "<m2@gmail>")
    }

    func testRefreshPassesTokenToAPI() async throws {
        let api = StubGmailAPI()
        await api.setCategoryResults(
            promotions: [], social: [], updates: [],
            forums: [], purchases: [], personal: []
        )
        let service = GmailCategoriesService(
            client: api, store: store,
            tokenProvider: StubTokenProvider(token: "the-token")
        )
        try await service.refresh(accountId: accountId)

        let tokensSeen = await api.tokensSeen
        XCTAssertTrue(tokensSeen.contains("the-token"))
    }

    func testRefreshSwallowsRateLimit() async throws {
        _ = try await store.insertEmail(makeRec(messageId: "<x@gmail>", uid: 10))
        let api = StubGmailAPI()
        await api.setListError(GmailAPIError.rateLimited)

        let service = GmailCategoriesService(
            client: api, store: store,
            tokenProvider: StubTokenProvider(token: "t")
        )
        // Must not throw — rate-limit failures are swallowed
        try await service.refresh(accountId: accountId)

        // Rate limit on the first category must abort the entire cycle — no further calls.
        let listCalls = await api.listCalls
        XCTAssertEqual(listCalls, 1, "Rate limit should abort remaining categories")
    }

    func testRefreshSwallowsTransportError() async throws {
        let api = StubGmailAPI()
        await api.setListError(GmailAPIError.transport("DNS"))
        let service = GmailCategoriesService(
            client: api, store: store,
            tokenProvider: StubTokenProvider(token: "t")
        )
        try await service.refresh(accountId: accountId)

        // Transport errors should NOT abort — all 6 categories must be attempted.
        let listCalls = await api.listCalls
        XCTAssertEqual(listCalls, 6, "Transport error should not abort remaining categories")
    }

    func testRefreshReturnsSilentlyWhenTokenFetchFails() async throws {
        let api = StubGmailAPI()
        let service = GmailCategoriesService(
            client: api, store: store,
            tokenProvider: FailingTokenProvider()
        )
        // Must not throw — token failure means we just don't refresh.
        try await service.refresh(accountId: accountId)

        // No API calls should have been made.
        let listCalls = await api.listCalls
        XCTAssertEqual(listCalls, 0)
    }

    func testRefreshSkipsMessagesWithNoMatchingMessageIdLocally() async throws {
        _ = try await store.insertEmail(makeRec(messageId: "<exists@gmail>", uid: 1))

        let api = StubGmailAPI()
        await api.setCategoryResults(
            promotions: [
                (gmailId: "g1", messageId: "<exists@gmail>"),
                (gmailId: "g2", messageId: "<not-in-db@gmail>"),
            ],
            social: [], updates: [], forums: [], purchases: [], personal: []
        )

        let service = GmailCategoriesService(
            client: api, store: store,
            tokenProvider: StubTokenProvider(token: "t")
        )
        try await service.refresh(accountId: accountId)

        let promos = try await store.fetchHeaders(
            accountId: accountId,
            folder: "gmail:category:promotions",
            offset: 0, limit: 10
        )
        XCTAssertEqual(promos.count, 1)
        XCTAssertEqual(promos.first?.messageId, "<exists@gmail>")
    }

    // MARK: - Helpers

    private func makeRec(messageId: String, uid: Int) -> EmailRecord {
        var r = EmailRecord(
            messageId: messageId,
            folder: "INBOX",
            senderEmail: "x@gmail.com",
            subject: "s",
            date: Int(Date().timeIntervalSince1970),
            isRead: false, isStarred: false, isDeleted: false,
            hasAttachments: false,
            accountId: accountId
        )
        r.uid = uid
        return r
    }
}

/// Stub returning a fixed token.
struct StubTokenProvider: TokenProvider {
    let token: String
    func oauthAccessToken(accountId: String) async throws -> String { token }
}

/// Stub that always fails (simulates revoked / no-credentials).
struct FailingTokenProvider: TokenProvider {
    func oauthAccessToken(accountId: String) async throws -> String {
        throw AuthError.notAuthenticated
    }
}

/// Test double for GmailAPI.
actor StubGmailAPI: GmailAPI {
    private var perCategory: [GmailCategory: [(gmailId: String, messageId: String)]] = [:]
    private var listError: Error?
    private(set) var tokensSeen: Set<String> = []
    private(set) var listCalls: Int = 0

    func setCategoryResults(
        promotions: [(gmailId: String, messageId: String)],
        social: [(gmailId: String, messageId: String)],
        updates: [(gmailId: String, messageId: String)],
        forums: [(gmailId: String, messageId: String)],
        purchases: [(gmailId: String, messageId: String)],
        personal: [(gmailId: String, messageId: String)]
    ) {
        perCategory[.promotions] = promotions
        perCategory[.social] = social
        perCategory[.updates] = updates
        perCategory[.forums] = forums
        perCategory[.purchases] = purchases
        perCategory[.personal] = personal
    }

    func setListError(_ err: Error) { listError = err }

    func listMessageIds(query: String, maxResults: Int, accessToken: String) async throws -> [String] {
        listCalls += 1
        tokensSeen.insert(accessToken)
        if let err = listError { throw err }
        // Decode the category from the query (matches what the service builds).
        for c in GmailCategory.allCases where query.contains("category:\(c.searchToken)") {
            return (perCategory[c] ?? []).map { $0.gmailId }
        }
        return []
    }

    func batchGetMessageIds(ids: [String], accessToken: String) async throws -> [String: String] {
        tokensSeen.insert(accessToken)
        var result: [String: String] = [:]
        for entries in perCategory.values {
            for entry in entries where ids.contains(entry.gmailId) {
                result[entry.gmailId] = entry.messageId
            }
        }
        return result
    }
}
