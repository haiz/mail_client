import XCTest
@testable import LiteMail

final class DeleteWorkerTests: XCTestCase {

    private var store: MailStore!
    private var dbPath: String!
    private let accId = "worker-test"

    override func setUp() async throws {
        dbPath = NSTemporaryDirectory() + "delworker_\(UUID().uuidString).sqlite"
        store = try MailStore(path: dbPath)
        let acc = AccountRecord(id: accId, emailAddress: "w@test", protocolType: "imap",
                                authType: "password", keychainRef: "k", isDefault: true)
        try await store.insertAccount(acc)
    }

    override func tearDown() async throws {
        store = nil
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private func insert(uid: Int, folder: String = "INBOX") async throws -> Int64 {
        let rec = EmailRecord(
            messageId: "\(uid)@t", folder: folder, senderEmail: "s@t", date: 0,
            isRead: false, isStarred: false, isDeleted: false,
            hasAttachments: false, uid: uid, accountId: accId
        )
        return try await store.insertEmail(rec)
    }

    func testWorkerDrainsSuccessfulJobs() async throws {
        let provider = MockDeleteProvider(accountId: accId)
        let worker = DeleteWorker(store: store, providerLookup: { _ in provider })

        let id = try await insert(uid: 1)
        let recs = try await store.fetchEmailRecords(ids: [id])
        try await store.enqueueDeletes(records: recs, now: 0)

        await worker.runOnce(now: 100)

        let calledRefs = await provider.calledRefs
        XCTAssertEqual(calledRefs.count, 1)
        let rem: Int = try await store.concurrentReader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM emails WHERE id=?", arguments: [id]) ?? -1
        }
        XCTAssertEqual(rem, 0, "email hard-deleted on success")
    }
}

// MARK: - Mock Provider for DeleteWorker tests

/// Minimal MailProvider actor — only deleteMessageBatch is exercised in this test.
actor MockDeleteProvider: MailProvider {
    let accountId: String
    let emailAddress: String = "mock@test"

    private(set) var isConnected: Bool = false
    private(set) var calledRefs: [String] = []
    var nextError: Error?

    init(accountId: String) {
        self.accountId = accountId
    }

    func connect() async throws { isConnected = true }
    func disconnect() async throws { isConnected = false }
    func performInitialSync() async throws {}
    func performIncrementalSync() async throws {}
    func listFolders() async throws -> [ProviderFolder] { [] }
    func createFolder(name: String) async throws {}
    func fetchMessages(folderId: String, cursor: String?, limit: Int) async throws
        -> (messages: [ProviderMessage], nextCursor: String?) { ([], nil) }
    func fetchMessageBody(messageRef: String) async throws -> ProviderMessageBody {
        ProviderMessageBody(ref: messageRef, textBody: nil, htmlBody: nil)
    }
    func markRead(messageRef: String, read: Bool) async throws {}
    func markStarred(messageRef: String, starred: Bool) async throws {}
    func moveMessage(messageRef: String, toFolderId: String) async throws {}
    func deleteMessage(messageRef: String) async throws {}
    func markReadBatch(messageRefs: [String], read: Bool) async throws {}
    func markStarredBatch(messageRefs: [String], starred: Bool) async throws {}
    func moveMessageBatch(messageRefs: [String], toFolderId: String) async throws {}
    func deleteMessageBatch(messageRefs: [String]) async throws {
        if let e = nextError { throw e }
        calledRefs += messageRefs
    }
    func send(message: OutgoingMessage) async throws {}
    func fetchAttachment(messageRef: String, partId: String) async throws -> Data { Data() }
    func startPushNotifications(onNewMessage: @escaping @Sendable () async -> Void) async throws {}
    func stopPushNotifications() async throws {}
}
