import XCTest
import GRDB
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

    /// Bumps a single job's attempt count by calling failDeleteJobsTransient repeatedly.
    private func bumpAttempts(jobId: Int64, times: Int) async throws {
        for _ in 0..<times {
            try await store.failDeleteJobsTransient(jobIds: [jobId], now: 0, error: "bump")
        }
    }

    func testWorkerPartialGiveupSplitsGroup() async throws {
        let provider = MockDeleteProvider(accountId: accId)
        await provider.setNextError(TransientTestError())
        let worker = DeleteWorker(store: store, providerLookup: { _ in provider })

        // Insert 3 emails and enqueue deletes.
        let id1 = try await insert(uid: 1)
        let id2 = try await insert(uid: 2)
        let id3 = try await insert(uid: 3)
        let recs = try await store.fetchEmailRecords(ids: [id1, id2, id3])
        try await store.enqueueDeletes(records: recs, now: 0)

        // Find the job ids (ordered by creation).
        let allJobs: [DeleteJobRecord] = try await store.fetchDueDeleteJobs(now: 0, limit: 100)
        let job1 = allJobs.first(where: { $0.emailId == id1 })!
        let job2 = allJobs.first(where: { $0.emailId == id2 })!
        // job3 stays at 0 attempts.

        // Bump: job1 → 9 attempts, job2 → 5 attempts.
        try await bumpAttempts(jobId: job1.id!, times: 9)
        try await bumpAttempts(jobId: job2.id!, times: 5)

        // Run the worker at a time when all jobs are due.
        await worker.runOnce(now: 10_000)

        // Assert: job1 (9→10 attempts) should be permanently failed.
        // job2 and job3 should be queued with incremented attempts.
        let rows: [(Int64, String, Int)] = try await store.concurrentReader.read { db in
            try Row.fetchAll(db, sql: "SELECT id, state, attempts FROM delete_jobs ORDER BY id")
                .map { ($0["id"], $0["state"], $0["attempts"]) }
        }
        let row1 = rows.first(where: { $0.0 == job1.id! })!
        let row2 = rows.first(where: { $0.0 == job2.id! })!
        let row3 = rows.first(where: { $0.0 == allJobs.first(where: { $0.emailId == id3 })!.id! })!

        XCTAssertEqual(row1.1, "failed", "9-attempt job should be permanently failed")
        XCTAssertEqual(row1.2, 9, "permanently failed job keeps its attempt count")
        XCTAssertEqual(row2.1, "queued", "5-attempt job should be retried")
        XCTAssertEqual(row2.2, 6, "5-attempt job incremented to 6")
        XCTAssertEqual(row3.1, "queued", "0-attempt job should be retried")
        XCTAssertEqual(row3.2, 1, "0-attempt job incremented to 1")
    }

    func testWorkerRetriesTransientErrorWithBackoff() async throws {
        struct NetErr: Error {}
        let provider = MockDeleteProvider(accountId: accId)
        await provider.setNextError(NetErr())
        let worker = DeleteWorker(store: store, providerLookup: { _ in provider })

        let id = try await insert(uid: 2)
        let recs = try await store.fetchEmailRecords(ids: [id])
        try await store.enqueueDeletes(records: recs, now: 0)
        await worker.runOnce(now: 100)

        let job: DeleteJobRecord? = try await store.concurrentReader.read { db in
            try DeleteJobRecord.filter(Column("email_id") == id).fetchOne(db)
        }
        XCTAssertEqual(job?.state, "queued")
        XCTAssertEqual(job?.attempts, 1)
        XCTAssertGreaterThan(job?.nextAttemptAt ?? 0, 100)

        let email: EmailRecord? = try await store.concurrentReader.read { db in
            try EmailRecord.fetchOne(db, key: id)
        }
        XCTAssertEqual(email?.deleteState, "pending_delete", "still hidden, not yet failed")
    }

    func testWorkerMarksPermanentOnAuthFailure() async throws {
        let provider = MockDeleteProvider(accountId: accId)
        await provider.setNextError(IMAPProviderError.authFailed("denied"))
        let worker = DeleteWorker(store: store, providerLookup: { _ in provider })

        let id = try await insert(uid: 3)
        let recs = try await store.fetchEmailRecords(ids: [id])
        try await store.enqueueDeletes(records: recs, now: 0)

        let expectation = XCTestExpectation(description: "permanent fail posted")
        let obs = NotificationCenter.default.addObserver(forName: .deleteJobsPermanentlyFailed,
                                                         object: nil, queue: nil) { _ in
            expectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        await worker.runOnce(now: 100)
        await fulfillment(of: [expectation], timeout: 1.0)

        let email: EmailRecord? = try await store.concurrentReader.read { db in
            try EmailRecord.fetchOne(db, key: id)
        }
        XCTAssertEqual(email?.deleteState, "delete_failed")
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

    func setNextError(_ error: Error?) {
        nextError = error
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
    func markSpamBatch(messageRefs: [String]) async throws {}
    func send(message: OutgoingMessage) async throws {}
    func fetchAttachment(messageRef: String, partId: String) async throws -> Data { Data() }
    func startPushNotifications(onNewMessage: @escaping @Sendable () async -> Void) async throws {}
    func stopPushNotifications() async throws {}
}

/// A plain transient error (not classified as permanent by DeleteWorker.isPermanent).
private struct TransientTestError: Error, CustomStringConvertible {
    var description: String { "transient test error" }
}
