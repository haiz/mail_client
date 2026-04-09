import XCTest
@testable import LiteMail

final class EmailReadTests: XCTestCase {

    func testFetchHeadersPagination() async throws {
        let (manager, _, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        for i in 1...20 {
            _ = try await store.insertEmail(
                TestData.makeEmailRecord(messageId: "<page-\(i)@test>", accountId: "test-account", uid: i)
            )
        }

        let page1 = try await manager.fetchHeaders(accountId: "test-account", folder: "INBOX", offset: 0, limit: 10)
        let page2 = try await manager.fetchHeaders(accountId: "test-account", folder: "INBOX", offset: 10, limit: 10)

        XCTAssertEqual(page1.count, 10)
        XCTAssertEqual(page2.count, 10)

        let page1Ids = Set(page1.map(\.id))
        let page2Ids = Set(page2.map(\.id))
        XCTAssertTrue(page1Ids.isDisjoint(with: page2Ids))
    }

    func testFetchBodyCaching() async throws {
        let (manager, _, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let emailId = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<body@test>", accountId: "test-account", uid: 1)
        )

        try await store.insertBody(emailId: emailId, text: "Hello world", html: "<p>Hello world</p>")

        let body1 = try await manager.fetchBody(emailId: emailId)
        XCTAssertNotNil(body1)
        XCTAssertEqual(body1?.textBody, "Hello world")
        XCTAssertEqual(body1?.htmlBody, "<p>Hello world</p>")

        let body2 = try await manager.fetchBody(emailId: emailId)
        XCTAssertEqual(body2?.textBody, "Hello world")
    }

    func testFetchThread() async throws {
        let (manager, _, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        for i in 1...3 {
            _ = try await store.insertEmail(
                TestData.makeEmailRecord(
                    messageId: "<thread-\(i)@test>",
                    threadId: "thread-abc",
                    accountId: "test-account",
                    uid: i
                )
            )
        }

        let thread = try await manager.fetchThread(threadId: "thread-abc")
        XCTAssertEqual(thread.count, 3)
        XCTAssertTrue(thread.allSatisfy { $0.threadId == "thread-abc" })
    }

    func testSearchFTS5() async throws {
        let (manager, _, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        _ = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<search1@test>", subject: "Meeting tomorrow at noon", accountId: "test-account", uid: 1)
        )
        _ = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<search2@test>", subject: "Invoice for December", accountId: "test-account", uid: 2)
        )

        let results = try await manager.search(query: "meeting", accountId: "test-account")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.subject, "Meeting tomorrow at noon")
    }

    func testCrossAccountSearch() async throws {
        let store = try MailStore(path: ":memory:")
        let authManager = AuthManager()

        let mock1 = MockMailProvider(accountId: "acc1")
        let mock2 = MockMailProvider(accountId: "acc2")

        let manager = AccountManager(store: store, authManager: authManager) { config, _, _ in
            if config.id == "acc1" { return mock1 }
            return mock2
        }

        try await manager.addAccount(TestData.makeAccountConfig(id: "acc1", email: "a@test.com"))
        try await manager.addAccount(TestData.makeAccountConfig(id: "acc2", email: "b@test.com"))

        _ = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<x1@test>", subject: "Project update", accountId: "acc1", uid: 1)
        )
        _ = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<x2@test>", subject: "Project deadline", accountId: "acc2", uid: 1)
        )

        let results = try await manager.search(query: "project", accountId: nil)
        XCTAssertEqual(results.count, 2)
    }

    func testSearchEmptyQuery() async throws {
        let (manager, _, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        _ = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<e@test>", accountId: "test-account", uid: 1)
        )

        let results = try await manager.search(query: "", accountId: "test-account")
        XCTAssertEqual(results.count, 0)
    }
}
