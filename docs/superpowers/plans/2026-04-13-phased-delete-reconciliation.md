# Phased Delete with Server Reconciliation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace fire-and-forget bulk delete with a persistent, reconciled queue so the local DB never diverges from the server.

**Architecture:** Add `delete_state` to `emails` and a `delete_jobs` table. `AccountManager.deleteBatch` enqueues jobs; a `DeleteWorker` actor drains the queue with retry + surfaced failure. Incremental sync reconciles `pending_delete` rows against server UIDs so drift corrects itself. Thread expansion is scoped to the current folder.

**Tech Stack:** Swift 5.9, AppKit, GRDB, SwiftMail (IMAP), XCTest.

**Spec:** `docs/superpowers/specs/2026-04-13-phased-delete-reconciliation.md`

---

## Phase A — Schema & Types

### Task 1: Schema migration v7

**Files:**
- Modify: `Sources/LiteMail/Core/MailStore.swift` (append migration after v6)
- Test: `Tests/LiteMailTests/MailStoreTests.swift`

- [ ] **Step 1: Write the failing migration test**

Append to `Tests/LiteMailTests/MailStoreTests.swift`:

```swift
func testV7MigrationAddsDeleteStateAndDeleteJobs() async throws {
    let path = NSTemporaryDirectory() + "litemail_v7_\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try MailStore(path: path)

    let columns: [String] = try await store.concurrentReader.read { db in
        try Row.fetchAll(db, sql: "PRAGMA table_info(emails)").compactMap { $0["name"] as String? }
    }
    XCTAssertTrue(columns.contains("delete_state"), "emails.delete_state missing")

    let hasTable: Int = try await store.concurrentReader.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='delete_jobs'") ?? 0
    }
    XCTAssertEqual(hasTable, 1, "delete_jobs table missing")

    let defaultState: String? = try await store.concurrentReader.read { db in
        try String.fetchOne(db, sql: """
            SELECT dflt_value FROM pragma_table_info('emails') WHERE name='delete_state'
        """)
    }
    XCTAssertEqual(defaultState, "'synced'")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter MailStoreTests.testV7MigrationAddsDeleteStateAndDeleteJobs`
Expected: FAIL — `emails.delete_state missing`.

- [ ] **Step 3: Add the v7 migration**

In `Sources/LiteMail/Core/MailStore.swift`, append to the `migrate()` body right before `try migrator.migrate(dbPool)`:

```swift
// v7: phased delete state + delete_jobs queue.
// See docs/superpowers/specs/2026-04-13-phased-delete-reconciliation.md
migrator.registerMigration("v7_delete_state_and_jobs") { db in
    try db.alter(table: "emails") { t in
        t.add(column: "delete_state", .text).notNull().defaults(to: "synced")
    }
    try db.create(index: "idx_emails_delete_state", on: "emails", columns: ["delete_state"])

    try db.create(table: "delete_jobs") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("account_id", .text).notNull()
        t.column("email_id", .integer).notNull().references("emails", onDelete: .cascade)
        t.column("folder", .text).notNull()
        t.column("uid", .integer).notNull()
        t.column("state", .text).notNull().defaults(to: "queued")
        t.column("attempts", .integer).notNull().defaults(to: 0)
        t.column("last_error", .text)
        t.column("next_attempt_at", .integer).notNull()
        t.column("created_at", .integer).notNull()
    }
    try db.create(index: "idx_delete_jobs_due", on: "delete_jobs", columns: ["state", "next_attempt_at"])
    try db.create(index: "idx_delete_jobs_email", on: "delete_jobs", columns: ["email_id"])
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter MailStoreTests.testV7MigrationAddsDeleteStateAndDeleteJobs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/Core/MailStore.swift Tests/LiteMailTests/MailStoreTests.swift
git commit -m "feat(mailstore): v7 migration — delete_state column + delete_jobs table"
```

---

### Task 2: EmailRecord gains `deleteState`

**Files:**
- Modify: `Sources/LiteMail/Core/MailStore.swift` (EmailRecord struct near line 734)
- Test: `Tests/LiteMailTests/MailStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/LiteMailTests/MailStoreTests.swift`:

```swift
func testEmailRecordRoundTripsDeleteState() async throws {
    let path = NSTemporaryDirectory() + "litemail_estate_\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try MailStore(path: path)
    let acc = AccountRecord(id: "a1", emailAddress: "x@y.z", protocolType: "imap",
                            authType: "password", keychainRef: "k", isDefault: true)
    try await store.insertAccount(acc)

    var rec = EmailRecord(
        messageId: "m1@x", folder: "INBOX", senderEmail: "s@x", date: 1,
        isRead: false, isStarred: false, isDeleted: false, hasAttachments: false,
        uid: 10, accountId: "a1"
    )
    rec.deleteState = "pending_delete"
    let id = try await store.insertEmail(rec)
    XCTAssertGreaterThan(id, 0)

    let fetched: EmailRecord? = try await store.concurrentReader.read { db in
        try EmailRecord.fetchOne(db, key: id)
    }
    XCTAssertEqual(fetched?.deleteState, "pending_delete")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter MailStoreTests.testEmailRecordRoundTripsDeleteState`
Expected: FAIL — `deleteState` property missing.

- [ ] **Step 3: Add `deleteState` to EmailRecord**

In `Sources/LiteMail/Core/MailStore.swift`, find the `EmailRecord` struct (~line 734) and:

1. Add the stored property after `accountId`:

```swift
    var accountId: String?
    var deleteState: String = "synced"
```

2. Add to CodingKeys:

```swift
        case accountId = "account_id"
        case deleteState = "delete_state"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --filter MailStoreTests.testEmailRecordRoundTripsDeleteState`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/Core/MailStore.swift Tests/LiteMailTests/MailStoreTests.swift
git commit -m "feat(mailstore): EmailRecord.deleteState property"
```

---

### Task 3: `DeleteJobRecord` struct

**Files:**
- Modify: `Sources/LiteMail/Core/MailStore.swift` (append near SyncStateRecord)
- Test: `Tests/LiteMailTests/MailStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MailStoreTests.swift`:

```swift
func testDeleteJobRecordRoundTrip() async throws {
    let path = NSTemporaryDirectory() + "litemail_djr_\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: path) }
    let store = try MailStore(path: path)
    let acc = AccountRecord(id: "a1", emailAddress: "x@y.z", protocolType: "imap",
                            authType: "password", keychainRef: "k", isDefault: true)
    try await store.insertAccount(acc)
    var em = EmailRecord(messageId: "m@x", folder: "INBOX", senderEmail: "s@x",
                         date: 0, isRead: false, isStarred: false, isDeleted: false,
                         hasAttachments: false, uid: 1, accountId: "a1")
    let emailId = try await store.insertEmail(em)

    let job = DeleteJobRecord(
        id: nil, accountId: "a1", emailId: emailId, folder: "INBOX", uid: 1,
        state: "queued", attempts: 0, lastError: nil,
        nextAttemptAt: 100, createdAt: 100
    )
    let saved: DeleteJobRecord = try await store.insertDeleteJob(job)
    XCTAssertNotNil(saved.id)
    XCTAssertEqual(saved.folder, "INBOX")
    XCTAssertEqual(saved.uid, 1)
    XCTAssertEqual(saved.state, "queued")
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter MailStoreTests.testDeleteJobRecordRoundTrip`
Expected: FAIL — `DeleteJobRecord` undefined.

- [ ] **Step 3: Add `DeleteJobRecord` + `insertDeleteJob`**

In `Sources/LiteMail/Core/MailStore.swift`, add before `struct SyncStateRecord`:

```swift
struct DeleteJobRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "delete_jobs"

    var id: Int64?
    var accountId: String
    var emailId: Int64
    var folder: String
    var uid: Int
    var state: String        // "queued" | "running" | "failed"
    var attempts: Int
    var lastError: String?
    var nextAttemptAt: Int   // unix seconds
    var createdAt: Int

    enum CodingKeys: String, CodingKey {
        case id, folder, uid, state, attempts
        case accountId = "account_id"
        case emailId = "email_id"
        case lastError = "last_error"
        case nextAttemptAt = "next_attempt_at"
        case createdAt = "created_at"
    }
}
```

Then inside the `MailStore` actor, add:

```swift
func insertDeleteJob(_ job: DeleteJobRecord) throws -> DeleteJobRecord {
    try dbPool.write { db in
        var j = job
        try j.insert(db)
        j.id = db.lastInsertedRowID
        return j
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter MailStoreTests.testDeleteJobRecordRoundTrip`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/Core/MailStore.swift Tests/LiteMailTests/MailStoreTests.swift
git commit -m "feat(mailstore): DeleteJobRecord + insertDeleteJob"
```

---

## Phase B — Store API for the new flow

### Task 4: `enqueueDeletes(records:)` — atomic mark + enqueue

**Files:**
- Modify: `Sources/LiteMail/Core/MailStore.swift`
- Test: `Tests/LiteMailTests/MailStoreBatchTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MailStoreBatchTests.swift`:

```swift
func testEnqueueDeletesSetsStateAndCreatesJobsAtomically() async throws {
    let ids = try await insertTestEmails(count: 3, folder: "INBOX")
    let recs = try await store.fetchEmailRecords(ids: ids)
    // Fill folder/uid that fetchEmailRecords already has
    try await store.enqueueDeletes(records: recs, now: 1000)

    let states: [String] = try await store.concurrentReader.read { db in
        try String.fetchAll(db, sql: "SELECT delete_state FROM emails WHERE id IN (?,?,?)",
                            arguments: [ids[0], ids[1], ids[2]])
    }
    XCTAssertEqual(Set(states), ["pending_delete"])

    let jobCount: Int = try await store.concurrentReader.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM delete_jobs") ?? -1
    }
    XCTAssertEqual(jobCount, 3)
}

func testEnqueueDeletesSkipsRecordsWithoutUid() async throws {
    // A record missing uid can't be deleted server-side; skip it and don't mark pending.
    let id = try await store.insertTestEmail(folder: "INBOX", uid: nil)
    let recs = try await store.fetchEmailRecords(ids: [id])
    try await store.enqueueDeletes(records: recs, now: 1000)

    let state: String? = try await store.concurrentReader.read { db in
        try String.fetchOne(db, sql: "SELECT delete_state FROM emails WHERE id=?", arguments: [id])
    }
    XCTAssertEqual(state, "synced")
    let jobCount: Int = try await store.concurrentReader.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM delete_jobs") ?? -1
    }
    XCTAssertEqual(jobCount, 0)
}
```

The existing `insertTestEmails` helper assumes uid-less inserts. Extend the helpers section of that file with:

```swift
private func insertTestEmail(folder: String = "INBOX", uid: Int? = nil) async throws -> Int64 {
    var rec = EmailRecord(
        messageId: "msg-\(UUID().uuidString)@test",
        folder: folder, senderEmail: "s@test",
        date: Int(Date().timeIntervalSince1970),
        isRead: false, isStarred: false, isDeleted: false,
        hasAttachments: false, uid: uid, accountId: testAccountId
    )
    return try await store.insertEmail(rec)
}
```

Also update the existing `insertTestEmails` to populate a UID so the happy-path test works:

```swift
private func insertTestEmails(count: Int, folder: String = "INBOX") async throws -> [Int64] {
    var ids: [Int64] = []
    for i in 1...count {
        let id = try await insertTestEmail(folder: folder, uid: 1000 + i)
        ids.append(id)
    }
    return ids
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter MailStoreBatchTests.testEnqueueDeletesSetsStateAndCreatesJobsAtomically`
Expected: FAIL — `enqueueDeletes` undefined.

- [ ] **Step 3: Implement `enqueueDeletes`**

In `MailStore.swift` (after `unmarkDeletedBatch`, ~line 500):

```swift
/// Atomically marks emails as pending_delete and inserts delete_jobs for each.
/// Records without a UID are skipped — they cannot be server-deleted.
/// Records without an accountId are skipped (defensive — shouldn't happen in practice).
func enqueueDeletes(records: [EmailRecord], now: Int = Int(Date().timeIntervalSince1970)) throws {
    try dbPool.write { db in
        for rec in records {
            guard let id = rec.id, let uid = rec.uid, let accId = rec.accountId else { continue }
            try db.execute(
                sql: "UPDATE emails SET delete_state = 'pending_delete' WHERE id = ?",
                arguments: [id]
            )
            var job = DeleteJobRecord(
                id: nil, accountId: accId, emailId: id,
                folder: rec.folder, uid: uid,
                state: "queued", attempts: 0, lastError: nil,
                nextAttemptAt: now, createdAt: now
            )
            try job.insert(db)
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter MailStoreBatchTests.testEnqueueDeletes`
Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/Core/MailStore.swift Tests/LiteMailTests/MailStoreBatchTests.swift
git commit -m "feat(mailstore): enqueueDeletes atomically marks pending + creates jobs"
```

---

### Task 5: Queue dequeue + completion APIs

**Files:**
- Modify: `Sources/LiteMail/Core/MailStore.swift`
- Test: `Tests/LiteMailTests/MailStoreBatchTests.swift`

- [ ] **Step 1: Write failing tests**

Append to `MailStoreBatchTests.swift`:

```swift
func testFetchDueDeleteJobsReturnsQueuedAndDue() async throws {
    let ids = try await insertTestEmails(count: 2, folder: "INBOX")
    let recs = try await store.fetchEmailRecords(ids: ids)
    try await store.enqueueDeletes(records: recs, now: 100)

    // Not due yet
    let empty = try await store.fetchDueDeleteJobs(now: 99, limit: 10)
    XCTAssertTrue(empty.isEmpty)

    // Due
    let due = try await store.fetchDueDeleteJobs(now: 100, limit: 10)
    XCTAssertEqual(due.count, 2)
    XCTAssertEqual(Set(due.map { $0.state }), ["queued"])
}

func testMarkJobRunningThenSucceededHardDeletesEmail() async throws {
    let ids = try await insertTestEmails(count: 1, folder: "INBOX")
    let recs = try await store.fetchEmailRecords(ids: ids)
    try await store.enqueueDeletes(records: recs, now: 100)
    let jobs = try await store.fetchDueDeleteJobs(now: 100, limit: 10)
    let job = jobs[0]

    try await store.markDeleteJobsRunning(jobIds: [job.id!])
    try await store.succeedDeleteJobs(jobIds: [job.id!])

    let emailCount: Int = try await store.concurrentReader.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM emails WHERE id=?", arguments: [ids[0]]) ?? -1
    }
    XCTAssertEqual(emailCount, 0, "email row should be hard-deleted on success")
    let jobCount: Int = try await store.concurrentReader.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM delete_jobs") ?? -1
    }
    XCTAssertEqual(jobCount, 0, "job row should be removed on success")
}

func testFailTransientReschedulesAndIncrementsAttempts() async throws {
    let ids = try await insertTestEmails(count: 1)
    let recs = try await store.fetchEmailRecords(ids: ids)
    try await store.enqueueDeletes(records: recs, now: 100)
    let job = try await store.fetchDueDeleteJobs(now: 100, limit: 10)[0]
    try await store.markDeleteJobsRunning(jobIds: [job.id!])

    try await store.failDeleteJobsTransient(jobIds: [job.id!], now: 100, error: "timeout")

    let updated: DeleteJobRecord? = try await store.concurrentReader.read { db in
        try DeleteJobRecord.fetchOne(db, key: job.id!)
    }
    XCTAssertEqual(updated?.state, "queued")
    XCTAssertEqual(updated?.attempts, 1)
    XCTAssertEqual(updated?.lastError, "timeout")
    XCTAssertGreaterThan(updated?.nextAttemptAt ?? 0, 100)
}

func testFailPermanentMarksEmailDeleteFailed() async throws {
    let ids = try await insertTestEmails(count: 1)
    let recs = try await store.fetchEmailRecords(ids: ids)
    try await store.enqueueDeletes(records: recs, now: 100)
    let job = try await store.fetchDueDeleteJobs(now: 100, limit: 10)[0]

    try await store.failDeleteJobsPermanent(jobIds: [job.id!], error: "auth denied")

    let state: String? = try await store.concurrentReader.read { db in
        try String.fetchOne(db, sql: "SELECT delete_state FROM emails WHERE id=?", arguments: [ids[0]])
    }
    XCTAssertEqual(state, "delete_failed")
    let jobState: String? = try await store.concurrentReader.read { db in
        try String.fetchOne(db, sql: "SELECT state FROM delete_jobs WHERE id=?", arguments: [job.id!])
    }
    XCTAssertEqual(jobState, "failed")
}

func testResetRunningJobsOnStartup() async throws {
    let ids = try await insertTestEmails(count: 1)
    let recs = try await store.fetchEmailRecords(ids: ids)
    try await store.enqueueDeletes(records: recs, now: 100)
    let job = try await store.fetchDueDeleteJobs(now: 100, limit: 10)[0]
    try await store.markDeleteJobsRunning(jobIds: [job.id!])

    try await store.resetRunningDeleteJobs()

    let st: String? = try await store.concurrentReader.read { db in
        try String.fetchOne(db, sql: "SELECT state FROM delete_jobs WHERE id=?", arguments: [job.id!])
    }
    XCTAssertEqual(st, "queued")
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter MailStoreBatchTests.testFetchDueDeleteJobs`
Expected: FAIL — functions undefined.

- [ ] **Step 3: Implement queue APIs**

In `MailStore.swift`, add after `enqueueDeletes`:

```swift
// MARK: - Delete Job Queue

func fetchDueDeleteJobs(now: Int, limit: Int) throws -> [DeleteJobRecord] {
    try dbPool.read { db in
        try DeleteJobRecord
            .filter(Column("state") == "queued" && Column("next_attempt_at") <= now)
            .order(Column("next_attempt_at").asc)
            .limit(limit)
            .fetchAll(db)
    }
}

func markDeleteJobsRunning(jobIds: [Int64]) throws {
    guard !jobIds.isEmpty else { return }
    let placeholders = jobIds.map { _ in "?" }.joined(separator: ",")
    let args = jobIds.map { $0 as DatabaseValueConvertible }
    try dbPool.write { db in
        try db.execute(
            sql: "UPDATE delete_jobs SET state='running' WHERE id IN (\(placeholders))",
            arguments: StatementArguments(args)
        )
    }
}

func succeedDeleteJobs(jobIds: [Int64]) throws {
    guard !jobIds.isEmpty else { return }
    let placeholders = jobIds.map { _ in "?" }.joined(separator: ",")
    let args = jobIds.map { $0 as DatabaseValueConvertible }
    try dbPool.write { db in
        // Hard-delete the emails these jobs owned, then the jobs themselves.
        // The FK ON DELETE CASCADE would also drop the jobs, but being explicit avoids ambiguity.
        try db.execute(
            sql: """
                DELETE FROM emails WHERE id IN (
                    SELECT email_id FROM delete_jobs WHERE id IN (\(placeholders))
                )
            """,
            arguments: StatementArguments(args)
        )
        try db.execute(
            sql: "DELETE FROM delete_jobs WHERE id IN (\(placeholders))",
            arguments: StatementArguments(args)
        )
    }
}

func failDeleteJobsTransient(jobIds: [Int64], now: Int, error: String) throws {
    guard !jobIds.isEmpty else { return }
    try dbPool.write { db in
        for id in jobIds {
            guard var job = try DeleteJobRecord.fetchOne(db, key: id) else { continue }
            job.attempts += 1
            job.lastError = error
            // Backoff: 2^attempts seconds, capped at 300s.
            let delay = min(300, Int(pow(2.0, Double(job.attempts))))
            job.nextAttemptAt = now + delay
            job.state = "queued"
            try job.update(db)
        }
    }
}

func failDeleteJobsPermanent(jobIds: [Int64], error: String) throws {
    guard !jobIds.isEmpty else { return }
    let placeholders = jobIds.map { _ in "?" }.joined(separator: ",")
    let args = jobIds.map { $0 as DatabaseValueConvertible }
    try dbPool.write { db in
        // Update emails to delete_failed
        try db.execute(
            sql: """
                UPDATE emails SET delete_state='delete_failed' WHERE id IN (
                    SELECT email_id FROM delete_jobs WHERE id IN (\(placeholders))
                )
            """,
            arguments: StatementArguments(args)
        )
        // Mark job failed
        var a: [DatabaseValueConvertible] = [error]
        a += args
        try db.execute(
            sql: "UPDATE delete_jobs SET state='failed', last_error=? WHERE id IN (\(placeholders))",
            arguments: StatementArguments(a)
        )
    }
}

/// Called on app startup: any 'running' job from a prior crashed run is put back to 'queued'.
func resetRunningDeleteJobs() throws {
    try dbPool.write { db in
        try db.execute(sql: "UPDATE delete_jobs SET state='queued' WHERE state='running'")
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter MailStoreBatchTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/Core/MailStore.swift Tests/LiteMailTests/MailStoreBatchTests.swift
git commit -m "feat(mailstore): delete-job queue APIs — dequeue, succeed, fail, reset"
```

---

### Task 6: Hide `pending_delete` from list queries

**Files:**
- Modify: `Sources/LiteMail/Core/MailStore.swift` (four queries)
- Test: `Tests/LiteMailTests/MailStoreBatchTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `MailStoreBatchTests.swift`:

```swift
func testPendingDeleteHiddenFromListingsAndFolderCounts() async throws {
    let ids = try await insertTestEmails(count: 3, folder: "INBOX")
    let recs = try await store.fetchEmailRecords(ids: ids)
    try await store.enqueueDeletes(records: [recs[0]], now: 100)

    // fetchEmails for the folder should return 2
    let headers = try await store.fetchEmails(accountId: testAccountId, folder: "INBOX", limit: 50)
    XCTAssertEqual(headers.count, 2)
    XCTAssertFalse(headers.contains(where: { $0.id == ids[0] }))

    // listFolders count should be 2
    let folders = try await store.listFolders(accountId: testAccountId)
    let inbox = folders.first(where: { $0.folder == "INBOX" })
    XCTAssertEqual(inbox?.totalCount, 2)
}

func testDeleteFailedStillVisibleInListings() async throws {
    let ids = try await insertTestEmails(count: 1)
    let recs = try await store.fetchEmailRecords(ids: ids)
    try await store.enqueueDeletes(records: recs, now: 100)
    let job = try await store.fetchDueDeleteJobs(now: 100, limit: 10)[0]
    try await store.failDeleteJobsPermanent(jobIds: [job.id!], error: "denied")

    let headers = try await store.fetchEmails(accountId: testAccountId, folder: "INBOX", limit: 50)
    XCTAssertEqual(headers.count, 1)
    XCTAssertEqual(headers[0].id, ids[0])
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter MailStoreBatchTests.testPendingDeleteHidden`
Expected: FAIL — pending_delete still counted.

- [ ] **Step 3: Update `listFolders` query**

In `MailStore.listFolders` (~line 577), change the COUNT predicates to also exclude `pending_delete`:

```swift
let rows = try Row.fetchAll(db, sql: """
    SELECT ss.folder,
           COALESCE(SUM(CASE WHEN e.is_deleted = 0 AND e.delete_state <> 'pending_delete' THEN 1 ELSE 0 END), 0) AS total_count,
           COALESCE(SUM(CASE WHEN e.is_read = 0 AND e.is_deleted = 0 AND e.delete_state <> 'pending_delete' THEN 1 ELSE 0 END), 0) AS unread_count
    FROM sync_state ss
    LEFT JOIN emails e ON e.folder = ss.folder AND e.account_id = ss.account_id
    WHERE ss.account_id = ?
    GROUP BY ss.folder
    ORDER BY ss.folder
""", arguments: [accountId])
```

- [ ] **Step 4: Update `fetchEmails` filter**

Find `fetchEmails(accountId:folder:limit:)` at `MailStore.swift:363`. Change its filter clause:

```swift
.filter(Column("account_id") == accountId && Column("folder") == folder && Column("is_deleted") == false && Column("delete_state") != "pending_delete")
```

Likewise update `fetchEmails(accountId:folder:before:limit:)` (cursor variant) and `search(accountId:query:limit:)` if present — every list-facing query filters out `pending_delete`.

Also update `fetchThread(threadId:)` (~line 385):

```swift
try EmailRecord
    .filter(Column("thread_id") == threadId)
    .filter(Column("is_deleted") == false)
    .filter(Column("delete_state") != "pending_delete")
    .order(Column("date").asc)
    .fetchAll(db)
```

And the sidebar count query inside `AccountManager.listFolders` path is already covered via `store.listFolders`.

- [ ] **Step 5: Run tests**

Run: `swift test --filter MailStoreBatchTests`
Expected: all PASS.

Then run the broader suite to catch regressions:

```bash
swift test --filter LiteMailTests
```

Expected: PASS (any existing tests that asserted `is_deleted=1` should still work since they haven't switched to pending_delete).

- [ ] **Step 6: Commit**

```bash
git add Sources/LiteMail/Core/MailStore.swift Tests/LiteMailTests/MailStoreBatchTests.swift
git commit -m "feat(mailstore): hide pending_delete from list/folder queries"
```

---

## Phase C — The Worker

### Task 7: `DeleteWorker` skeleton

**Files:**
- Create: `Sources/LiteMail/Core/DeleteWorker.swift`
- Test: `Tests/LiteMailIntegrationTests/DeleteWorkerTests.swift` (new)

- [ ] **Step 1: Write the failing test**

Create `Tests/LiteMailIntegrationTests/DeleteWorkerTests.swift`:

```swift
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
        let provider = MockDeleteProvider()
        let worker = DeleteWorker(store: store, providerLookup: { _ in provider })

        let id = try await insert(uid: 1)
        let recs = try await store.fetchEmailRecords(ids: [id])
        try await store.enqueueDeletes(records: recs, now: 0)

        await worker.runOnce(now: 100)

        XCTAssertEqual(provider.calledRefs.count, 1)
        let rem: Int = try await store.concurrentReader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM emails WHERE id=?", arguments: [id]) ?? -1
        }
        XCTAssertEqual(rem, 0, "email hard-deleted on success")
    }
}

final class MockDeleteProvider: MailProvider, @unchecked Sendable {
    var isConnected: Bool { true }
    var calledRefs: [String] = []
    var nextError: Error?

    // Minimal MailProvider conformance — only deleteMessageBatch is exercised in this test.
    // Other methods return defaults or throw.
    func connect() async throws {}
    func disconnect() async throws {}
    func performInitialSync() async throws {}
    func performIncrementalSync() async throws {}
    func listFolders() async throws -> [ProviderFolder] { [] }
    func createFolder(name: String) async throws {}
    func fetchMessages(folderId: String, cursor: String?, limit: Int) async throws
        -> (messages: [ProviderMessage], nextCursor: String?) { ([], nil) }
    func fetchMessageBody(messageRef: String) async throws -> ProviderMessageBody {
        ProviderMessageBody(textBody: nil, htmlBody: nil)
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
    func send(_ message: OutgoingMessage) async throws {}
    func fetchAttachment(messageRef: String, partId: String) async throws -> Data { Data() }
    func startPushNotifications(onNewMessage: @escaping @Sendable () async -> Void) async throws {}
    func stopPushNotifications() async throws {}
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter DeleteWorkerTests.testWorkerDrainsSuccessfulJobs`
Expected: FAIL — `DeleteWorker` undefined.

- [ ] **Step 3: Create `DeleteWorker`**

Create `Sources/LiteMail/Core/DeleteWorker.swift`:

```swift
import Foundation

/// Drains `delete_jobs` and calls the provider's `deleteMessageBatch`. Serialized via actor.
///
/// Design: the worker is pure — it reads the queue, calls providers, updates the queue.
/// UI signaling (toasts, badges) happens via posts to `NotificationCenter` on permanent failure.
actor DeleteWorker {
    private let store: MailStore
    private let providerLookup: @Sendable (_ accountId: String) -> (any MailProvider)?
    private var tickTask: Task<Void, Never>?
    private let batchLimit: Int

    init(store: MailStore,
         providerLookup: @escaping @Sendable (String) -> (any MailProvider)?,
         batchLimit: Int = 200) {
        self.store = store
        self.providerLookup = providerLookup
        self.batchLimit = batchLimit
    }

    /// Starts a 10-second ticker. Idempotent.
    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runOnce(now: Int(Date().timeIntervalSince1970))
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    /// Explicit kick after enqueue. Runs one drain pass immediately.
    func kick() async {
        await runOnce(now: Int(Date().timeIntervalSince1970))
    }

    /// Single drain pass. Public for tests.
    func runOnce(now: Int) async {
        let due: [DeleteJobRecord]
        do {
            due = try await store.fetchDueDeleteJobs(now: now, limit: batchLimit)
        } catch {
            return
        }
        guard !due.isEmpty else { return }

        // Group by (account, folder) so each IMAP batch selects one mailbox.
        let byGroup = Dictionary(grouping: due, by: { GroupKey(accountId: $0.accountId, folder: $0.folder) })
        for (key, jobs) in byGroup {
            await processGroup(accountId: key.accountId, folder: key.folder, jobs: jobs, now: now)
        }
    }

    private struct GroupKey: Hashable {
        let accountId: String
        let folder: String
    }

    private func processGroup(accountId: String, folder: String, jobs: [DeleteJobRecord], now: Int) async {
        guard let provider = providerLookup(accountId) else {
            // No provider — transient: maybe account not loaded yet.
            try? await store.failDeleteJobsTransient(
                jobIds: jobs.compactMap(\.id), now: now, error: "provider not available")
            return
        }
        let ids = jobs.compactMap(\.id)
        try? await store.markDeleteJobsRunning(jobIds: ids)

        let refs = jobs.map { "folder:\($0.folder):uid:\($0.uid)" }
        do {
            try await provider.deleteMessageBatch(messageRefs: refs)
            try? await store.succeedDeleteJobs(jobIds: ids)
        } catch {
            if DeleteWorker.isPermanent(error) || jobs.first.map({ $0.attempts + 1 >= 10 }) == true {
                try? await store.failDeleteJobsPermanent(jobIds: ids, error: "\(error)")
                NotificationCenter.default.post(name: .deleteJobsPermanentlyFailed,
                                                object: nil,
                                                userInfo: ["count": ids.count])
            } else {
                try? await store.failDeleteJobsTransient(jobIds: ids, now: now, error: "\(error)")
            }
        }
    }

    /// Classifies an error as permanent. Conservative: only well-known permanent cases.
    static func isPermanent(_ error: any Error) -> Bool {
        // Auth errors, message-not-found, 5xx-equivalent.
        // IMAPProviderError is the one LiteMail-defined enum we can inspect today.
        if let e = error as? IMAPProviderError {
            switch e {
            case .authenticationFailed, .messageNotFound:
                return true
            default:
                return false
            }
        }
        return false
    }
}

extension Notification.Name {
    static let deleteJobsPermanentlyFailed = Notification.Name("LiteMail.deleteJobsPermanentlyFailed")
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter DeleteWorkerTests.testWorkerDrainsSuccessfulJobs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/Core/DeleteWorker.swift Tests/LiteMailIntegrationTests/DeleteWorkerTests.swift
git commit -m "feat(core): DeleteWorker actor drains delete_jobs queue"
```

---

### Task 8: Worker error paths

**Files:**
- Modify: `Sources/LiteMail/Core/IMAPProvider.swift` (add `IMAPProviderError` cases if missing)
- Test: `Tests/LiteMailIntegrationTests/DeleteWorkerTests.swift`

- [ ] **Step 1: Inspect existing `IMAPProviderError`**

Run: `grep -n 'enum IMAPProviderError' Sources/LiteMail/Core/IMAPProvider.swift`

If `authenticationFailed` / `messageNotFound` cases already exist (confirmed in `toProviderMessage` and `fetchMessageBody`), skip step 2.

- [ ] **Step 2: Ensure required cases exist**

If missing, extend:

```swift
enum IMAPProviderError: Error {
    case notConnected
    case authenticationFailed
    case messageNotFound
    case sendFailed(String)
    // ...existing cases
}
```

- [ ] **Step 3: Add transient + permanent tests**

Append to `DeleteWorkerTests.swift`:

```swift
func testWorkerRetriesTransientErrorWithBackoff() async throws {
    struct NetErr: Error {}
    let provider = MockDeleteProvider()
    provider.nextError = NetErr()
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
    let provider = MockDeleteProvider()
    provider.nextError = IMAPProviderError.authenticationFailed
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
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter DeleteWorkerTests`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add Tests/LiteMailIntegrationTests/DeleteWorkerTests.swift Sources/LiteMail/Core/IMAPProvider.swift
git commit -m "test(delete-worker): cover transient retry + permanent auth failure"
```

---

## Phase D — Integration

### Task 9: Rewrite `AccountManager.deleteBatch`

**Files:**
- Modify: `Sources/LiteMail/Core/AccountManager.swift` (also add worker property)
- Test: `Tests/LiteMailIntegrationTests/BatchActionTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `BatchActionTests.swift`:

```swift
func testDeleteBatchEnqueuesJobsAndHidesFromList() async throws {
    // existing setUp creates manager with MockMailProvider
    let ids = try await insertTestHeaders(count: 3)

    try await manager.deleteBatch(emailIds: ids)

    // Hidden from list
    let headers = try await manager.listEmails(accountId: testAccountId, folder: "INBOX", limit: 50)
    XCTAssertEqual(headers.count, 0)

    // Jobs present
    let jobCount: Int = try await manager.store.concurrentReader.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM delete_jobs") ?? -1
    }
    XCTAssertEqual(jobCount, 3)
}

func testDeleteBatchDoesNotFireAndForget() async throws {
    // After deleteBatch returns, no background Task should be invoking the provider.
    // Instead, worker.kick() drives it. Since the mock provider records calls,
    // we assert that calls happen only after worker drain.
    let ids = try await insertTestHeaders(count: 2)
    try await manager.deleteBatch(emailIds: ids)
    XCTAssertEqual(mockProvider.deleteBatchCalls, 0, "no implicit call at deleteBatch time")

    await manager.deleteWorker.kick()
    XCTAssertEqual(mockProvider.deleteBatchCalls, 1)
}
```

Make sure `MockMailProvider` has a `deleteBatchCalls` counter; if missing, add:

```swift
var deleteBatchCalls = 0
func deleteMessageBatch(messageRefs: [String]) async throws { deleteBatchCalls += 1 }
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter BatchActionTests.testDeleteBatchEnqueuesJobsAndHidesFromList`
Expected: FAIL — existing `deleteBatch` fires provider eagerly.

- [ ] **Step 3: Rewrite `deleteBatch`**

In `AccountManager.swift`:

1. Add a worker property in the actor. Find the property section and add:

```swift
let deleteWorker: DeleteWorker
```

2. In the initializer, construct it after `store` is set. Example (adapt to current init shape):

```swift
self.deleteWorker = DeleteWorker(
    store: store,
    providerLookup: { [weak self] accountId in
        // weak self is fine — lookup is purely read-only
        return self?.providers[accountId]
    }
)
Task { await self.deleteWorker.start() }
```

3. Replace the body of `deleteBatch` (~line 257-264):

```swift
func deleteBatch(emailIds: [Int64]) async throws {
    guard !emailIds.isEmpty else { return }
    let records = try await store.fetchEmailRecords(ids: emailIds)
    try await store.enqueueDeletes(records: records)
    await deleteWorker.kick()
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter BatchActionTests`
Expected: PASS. Also run the full integration suite to catch regressions:

```bash
swift test --filter LiteMailIntegrationTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/Core/AccountManager.swift Tests/LiteMailIntegrationTests/BatchActionTests.swift Tests/LiteMailIntegrationTests/MockMailProvider.swift
git commit -m "refactor(account-manager): deleteBatch enqueues jobs, worker performs IMAP call"
```

---

### Task 10: Undo cancels `pending_delete`

**Files:**
- Modify: `Sources/LiteMail/Core/MailStore.swift` (add `cancelPendingDeletes`)
- Modify: `Sources/LiteMail/App/AppDelegate.swift` (undo handler at ~line 377-382)
- Test: `Tests/LiteMailIntegrationTests/BatchActionTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `BatchActionTests.swift`:

```swift
func testUndoRestoresPendingDeleteAndRemovesJobs() async throws {
    let ids = try await insertTestHeaders(count: 2)
    try await manager.deleteBatch(emailIds: ids)

    try await manager.store.cancelPendingDeletes(emailIds: ids)

    // Visible again
    let headers = try await manager.listEmails(accountId: testAccountId, folder: "INBOX", limit: 50)
    XCTAssertEqual(headers.count, 2)

    // Jobs gone
    let jobCount: Int = try await manager.store.concurrentReader.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM delete_jobs") ?? -1
    }
    XCTAssertEqual(jobCount, 0)
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter BatchActionTests.testUndoRestoresPendingDeleteAndRemovesJobs`
Expected: FAIL — `cancelPendingDeletes` undefined.

- [ ] **Step 3: Implement `cancelPendingDeletes`**

In `MailStore.swift`, after `enqueueDeletes`:

```swift
/// Reverts a batch of pending_delete rows to synced and deletes their queued jobs.
/// If a job is already 'running', we skip it — worker is past the point of no return.
func cancelPendingDeletes(emailIds: [Int64]) throws {
    guard !emailIds.isEmpty else { return }
    let placeholders = emailIds.map { _ in "?" }.joined(separator: ",")
    let args = emailIds.map { $0 as DatabaseValueConvertible }
    try dbPool.write { db in
        // Only delete jobs that haven't started running yet.
        try db.execute(
            sql: "DELETE FROM delete_jobs WHERE email_id IN (\(placeholders)) AND state = 'queued'",
            arguments: StatementArguments(args)
        )
        // Revert email state where no more jobs reference it (row left only if running).
        try db.execute(sql: """
            UPDATE emails SET delete_state='synced'
            WHERE id IN (\(placeholders))
              AND NOT EXISTS (SELECT 1 FROM delete_jobs WHERE email_id = emails.id)
        """, arguments: StatementArguments(args))
    }
}
```

- [ ] **Step 4: Wire into AppDelegate undo**

In `Sources/LiteMail/App/AppDelegate.swift` at the `batchDelete` handler (~line 377), replace the undo reverse operation:

```swift
let deleteAction = UndoableBatchAction(
    description: deleteDesc,
    reverseOperation: { [weak self] in
        guard let store = self?.accountManager?.store else { return }
        try await store.cancelPendingDeletes(emailIds: expandedIds)
    },
    emailIds: expandedIds
)
```

- [ ] **Step 5: Run the test to verify pass**

Run: `swift test --filter BatchActionTests.testUndoRestoresPendingDeleteAndRemovesJobs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/LiteMail/Core/MailStore.swift Sources/LiteMail/App/AppDelegate.swift Tests/LiteMailIntegrationTests/BatchActionTests.swift
git commit -m "feat(undo): cancelPendingDeletes reverts state + removes queued jobs"
```

---

### Task 11: Scope `expandThreadIds` to the current folder

**Files:**
- Modify: `Sources/LiteMail/App/AppDelegate.swift` (~line 289-305)
- Test: `Tests/LiteMailGUITests/GUITestHelpers.swift` or a new small XCTest

- [ ] **Step 1: Write the failing test**

Create or append to `Tests/LiteMailIntegrationTests/ThreadExpansionTests.swift`:

```swift
import XCTest
@testable import LiteMail

final class ThreadExpansionTests: XCTestCase {
    func testExpandFiltersByCurrentFolder() async throws {
        let path = NSTemporaryDirectory() + "threadexp_\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try MailStore(path: path)
        let accId = "a"
        let acc = AccountRecord(id: accId, emailAddress: "a@b", protocolType: "imap",
                                authType: "password", keychainRef: "k", isDefault: true)
        try await store.insertAccount(acc)

        func mk(_ uid: Int, _ folder: String, _ thread: String) async throws -> Int64 {
            var r = EmailRecord(messageId: "\(uid)@x", folder: folder, senderEmail: "s@x",
                                date: 0, isRead: false, isStarred: false, isDeleted: false,
                                hasAttachments: false, uid: uid, accountId: accId)
            r.threadId = thread
            return try await store.insertEmail(r)
        }

        let head = try await mk(1, "Github", "t1")
        _ = try await mk(2, "Github", "t1")
        _ = try await mk(3, "INBOX", "t1")   // same thread, other folder

        let members = try await store.fetchThread(threadId: "t1")
        let scoped = members.filter { $0.folder == "Github" }.compactMap(\.id)

        XCTAssertEqual(Set(scoped), Set([head, members.first { $0.uid == 2 }!.id!]))
        XCTAssertFalse(scoped.contains(where: { $0 == members.first { $0.uid == 3 }!.id! }))
    }
}
```

This test exercises the scoping rule at the store level (where it is cheap). The AppDelegate callsite is the integration.

- [ ] **Step 2: Run to verify pass (fetchThread already works)**

Run: `swift test --filter ThreadExpansionTests`
Expected: PASS — this validates the scoping contract.

- [ ] **Step 3: Update `expandThreadIds` in AppDelegate**

In `Sources/LiteMail/App/AppDelegate.swift` replace the body:

```swift
private func expandThreadIds(_ ids: [Int64]) async throws -> [Int64] {
    guard let accountManager else { return ids }
    var expanded = Set<Int64>(ids)   // always include the originals
    let groups = windowController?.messageListView.threadGroups ?? []
    let folder = currentFolder
    for id in ids {
        if let group = groups.first(where: { $0.primaryHeader.id == id }),
           let threadId = group.threadId {
            let members = try await accountManager.fetchThread(threadId: threadId)
            for header in members where header.folder == folder {
                expanded.insert(header.id)
            }
        }
    }
    return Array(expanded)
}
```

- [ ] **Step 4: Build to check no regressions**

```bash
swift build 2>&1 | tail -30
swift test --filter LiteMailTests
swift test --filter LiteMailIntegrationTests
```

Expected: build succeeds, tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/App/AppDelegate.swift Tests/LiteMailIntegrationTests/ThreadExpansionTests.swift
git commit -m "fix(appdelegate): scope expandThreadIds to current folder"
```

---

### Task 12: Reset running jobs on startup

**Files:**
- Modify: `Sources/LiteMail/Core/AccountManager.swift` (init)

- [ ] **Step 1: Call `resetRunningDeleteJobs` before worker start**

In `AccountManager.swift` init, after `self.deleteWorker = ...`:

```swift
Task {
    try? await self.store.resetRunningDeleteJobs()
    await self.deleteWorker.start()
}
```

- [ ] **Step 2: Build + test**

```bash
swift build 2>&1 | tail -15
swift test --filter LiteMailIntegrationTests
```

Expected: all pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/LiteMail/Core/AccountManager.swift
git commit -m "feat(account-manager): reset stuck running delete jobs on startup"
```

---

## Phase E — Sync reconciliation

### Task 13: `reconcilePendingDeletes` in IMAPProvider

**Files:**
- Modify: `Sources/LiteMail/Core/IMAPProvider.swift`
- Modify: `Sources/LiteMail/Core/MailStore.swift` (new query `fetchPendingDeleteUids`)
- Test: Protocol tests are Docker-bound; add a unit test via a small wrapper instead.

- [ ] **Step 1: Add `fetchPendingDeleteUids` to MailStore**

In `MailStore.swift`:

```swift
/// Returns (emailId, uid) for every pending_delete row in the given folder.
func fetchPendingDeleteUids(accountId: String, folder: String) throws -> [(emailId: Int64, uid: Int)] {
    try dbPool.read { db in
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, uid FROM emails
            WHERE account_id = ? AND folder = ? AND delete_state = 'pending_delete' AND uid IS NOT NULL
        """, arguments: [accountId, folder])
        return rows.map { (emailId: $0["id"], uid: $0["uid"]) }
    }
}

/// Hard-deletes emails confirmed absent from server + their jobs.
func confirmDeletesByEmailIds(_ emailIds: [Int64]) throws {
    guard !emailIds.isEmpty else { return }
    let placeholders = emailIds.map { _ in "?" }.joined(separator: ",")
    let args = emailIds.map { $0 as DatabaseValueConvertible }
    try dbPool.write { db in
        try db.execute(sql: "DELETE FROM emails WHERE id IN (\(placeholders))",
                       arguments: StatementArguments(args))
        // cascade drops the job rows, but be explicit:
        try db.execute(sql: "DELETE FROM delete_jobs WHERE email_id IN (\(placeholders))",
                       arguments: StatementArguments(args))
    }
}
```

- [ ] **Step 2: Write the MailStore-side test**

Append to `MailStoreBatchTests.swift`:

```swift
func testFetchPendingDeleteUidsAndConfirm() async throws {
    let ids = try await insertTestEmails(count: 2, folder: "Github")
    let recs = try await store.fetchEmailRecords(ids: ids)
    try await store.enqueueDeletes(records: recs, now: 0)

    let pending = try await store.fetchPendingDeleteUids(accountId: testAccountId, folder: "Github")
    XCTAssertEqual(pending.count, 2)

    try await store.confirmDeletesByEmailIds([ids[0]])

    let remaining = try await store.fetchPendingDeleteUids(accountId: testAccountId, folder: "Github")
    XCTAssertEqual(remaining.count, 1)
}
```

Run: `swift test --filter MailStoreBatchTests.testFetchPendingDeleteUidsAndConfirm`
Expected: PASS.

- [ ] **Step 3: Add reconciliation pass to IMAPProvider**

In `Sources/LiteMail/Core/IMAPProvider.swift`, add after `incrementalSyncFolder` (~line 215):

```swift
/// Compares local pending_delete rows for this folder against server UIDs.
/// - If server does NOT have the UID: server already expunged it — hard-delete locally.
/// - If server DOES have the UID: leave state alone; worker will retry.
///
/// Called at the end of `incrementalSyncFolder`. Safe to call with 0 pending rows.
private func reconcilePendingDeletes(imap: IMAPServer, folderId: String) async throws {
    let pending = try await store.fetchPendingDeleteUids(accountId: accountId, folder: folderId)
    guard !pending.isEmpty else { return }

    // Already selected in incrementalSyncFolder; still safe to re-select for clarity.
    _ = try await imap.selectMailbox(folderId)

    let uids = pending.map { UID(UInt32($0.uid)) }
    let uidSet = MessageIdentifierSet<UID>(uids)
    let found: Set<UInt32>
    do {
        // UID SEARCH UID <set> returns the subset that actually exists server-side.
        let results = try await imap.uidSearch(uids: uidSet)
        found = Set(results.map(\.value))
    } catch {
        // If reconciliation search fails, don't touch state — worker handles recovery.
        return
    }

    let missing: [Int64] = pending
        .filter { !found.contains(UInt32($0.uid)) }
        .map(\.emailId)
    if !missing.isEmpty {
        try await store.confirmDeletesByEmailIds(missing)
    }
}
```

**Note on the SwiftMail API:** `imap.uidSearch(uids:)` is the presumed interface. If SwiftMail exposes a different name (e.g., `imap.search(criteria:)`), adjust the call site. Grep:

```bash
grep -rn "func uidSearch\|func search" .build/checkouts/swiftmail 2>/dev/null | head -5
```

Use whichever is available. If no `uidSearch` exists, fall back to fetching headers with the candidate UID set and checking which UIDs came back:

```swift
let infos = try await imap.fetchMessageInfos(uidRange: UID(UInt32(uids.map(\.value).min()!))...UID(UInt32(uids.map(\.value).max()!)))
let found = Set(infos.compactMap { $0.uid?.value })
```

- [ ] **Step 4: Call reconciliation from `incrementalSyncFolder`**

At the end of `incrementalSyncFolder` (after `updateSyncState`), add:

```swift
try? await reconcilePendingDeletes(imap: imap, folderId: folderId)
```

The `try?` here is intentional: reconciliation is best-effort and must not fail the whole sync.

- [ ] **Step 5: Integration test with mock IMAP**

This is best verified against Docker GreenMail. Add to `Tests/LiteMailProtocolTests/IMAPSyncTests.swift` (requires `docker compose -f docker-compose.test.yml up -d`):

```swift
func testReconciliationHardDeletesMissingPendingRows() async throws {
    // Setup: account + sync → mark two messages pending_delete → delete one from server → sync again.
    // (Adapt fixture setup from existing IMAPSyncTests.)
    // ...
    // Assertion: after second sync, the message with UID no longer on server is hard-deleted;
    // the one still present remains pending_delete.
}
```

If writing the full protocol test here is heavy, defer a TODO comment referencing this task and cover via manual smoke test in Task 16.

- [ ] **Step 6: Build + test**

```bash
swift build 2>&1 | tail -20
swift test --filter LiteMailTests
swift test --filter LiteMailIntegrationTests
```

Expected: PASS. Protocol tests only if Docker is running.

- [ ] **Step 7: Commit**

```bash
git add Sources/LiteMail/Core/IMAPProvider.swift Sources/LiteMail/Core/MailStore.swift Tests/LiteMailTests/MailStoreBatchTests.swift
git commit -m "feat(sync): reconcile pending_delete rows against server UIDs"
```

---

## Phase F — UI surfacing of failures

### Task 14: `delete_failed` badge in the message list

**Files:**
- Modify: `Sources/LiteMail/Core/MailStore.swift` (surface `deleteState` in the header DTO if not already)
- Modify: `Sources/LiteMail/Core/MailEngineProtocol.swift` (EmailHeader type — add `deleteState`)
- Modify: `Sources/LiteMail/GUI/MessageListView.swift` (cell rendering)

- [ ] **Step 1: Add `deleteState` to EmailHeader**

In `Sources/LiteMail/Core/MailEngineProtocol.swift`, find `EmailHeader` and add:

```swift
let deleteState: String   // "synced" | "pending_delete" | "delete_failed"
```

Update any initializer in the same file.

- [ ] **Step 2: Populate `deleteState` in the record → header converter**

Find `recordToHeader` in `AccountManager.swift` (around line 208 area). Add the new field:

```swift
return EmailHeader(
    ...existing fields...,
    deleteState: record.deleteState
)
```

- [ ] **Step 3: Render badge in list cell**

In `Sources/LiteMail/GUI/MessageListView.swift`, find the cell configuration and add (after subject rendering):

```swift
// Show a small red "!" on delete_failed rows so the user knows a delete didn't go through.
if header.deleteState == "delete_failed" {
    let badge = NSTextField(labelWithString: "!")
    badge.textColor = .systemRed
    badge.font = .boldSystemFont(ofSize: 11)
    badge.toolTip = "Couldn't delete on server. Click Retry in the toolbar."
    // ...attach to cell's horizontal stack at the trailing side
}
```

Adapt to existing cell layout code.

- [ ] **Step 4: Build**

```bash
swift build 2>&1 | tail -10
```

Expected: success. Run the app; do a delete against a disconnected account to see the badge (manual verification acceptable for UI work).

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/Core/MailEngineProtocol.swift Sources/LiteMail/Core/AccountManager.swift Sources/LiteMail/GUI/MessageListView.swift
git commit -m "feat(ui): show delete_failed badge on message list rows"
```

---

### Task 15: "Retry failed deletes" action

**Files:**
- Modify: `Sources/LiteMail/Core/AccountManager.swift` (new `retryFailedDeletes`)
- Modify: `Sources/LiteMail/Core/MailStore.swift` (new `requeueFailedDeleteJobs`)
- Modify: `Sources/LiteMail/GUI/BulkActionBar.swift` or menu
- Test: `Tests/LiteMailIntegrationTests/BatchActionTests.swift`

- [ ] **Step 1: Write failing test**

Append to `BatchActionTests.swift`:

```swift
func testRetryFailedDeletesRequeuesAndClearsFailedState() async throws {
    // Force a permanent failure first
    let ids = try await insertTestHeaders(count: 1)
    try await manager.deleteBatch(emailIds: ids)
    // Fail the job permanently via store (bypass worker for determinism)
    let jobs = try await manager.store.fetchDueDeleteJobs(now: Int.max, limit: 10)
    try await manager.store.failDeleteJobsPermanent(jobIds: jobs.map { $0.id! }, error: "test")

    try await manager.retryFailedDeletes(accountId: testAccountId, folder: "INBOX")

    let email: EmailRecord? = try await manager.store.concurrentReader.read { db in
        try EmailRecord.fetchOne(db, key: ids[0])
    }
    XCTAssertEqual(email?.deleteState, "pending_delete")
    let jobState: String? = try await manager.store.concurrentReader.read { db in
        try String.fetchOne(db, sql: "SELECT state FROM delete_jobs WHERE email_id=?", arguments: [ids[0]])
    }
    XCTAssertEqual(jobState, "queued")
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test --filter BatchActionTests.testRetryFailedDeletes`
Expected: FAIL — `retryFailedDeletes` undefined.

- [ ] **Step 3: Implement store requeue**

In `MailStore.swift`:

```swift
/// Resets failed jobs in a folder back to queued and clears email delete_state.
func requeueFailedDeleteJobs(accountId: String, folder: String, now: Int) throws -> Int {
    try dbPool.write { db in
        let changed = try db.execute(
            sql: """
                UPDATE delete_jobs SET state='queued', attempts=0, next_attempt_at=?, last_error=NULL
                WHERE account_id=? AND folder=? AND state='failed'
            """,
            arguments: [now, accountId, folder]
        )
        try db.execute(sql: """
            UPDATE emails SET delete_state='pending_delete'
            WHERE account_id=? AND folder=? AND delete_state='delete_failed'
        """, arguments: [accountId, folder])
        // db.execute returns Void in GRDB; fetch changes count separately if needed
        return db.changesCount
    }
}
```

(Strip the `Int` return if your GRDB version disallows; use a separate COUNT query for the return value.)

- [ ] **Step 4: Implement manager method**

In `AccountManager.swift`:

```swift
func retryFailedDeletes(accountId: String, folder: String) async throws {
    _ = try await store.requeueFailedDeleteJobs(
        accountId: accountId, folder: folder,
        now: Int(Date().timeIntervalSince1970)
    )
    await deleteWorker.kick()
}
```

- [ ] **Step 5: Wire UI (bulk bar button)**

In `BulkActionBar.swift` add a button visible when any `delete_failed` rows exist in the current folder, triggering `retryFailedDeletes`. If bulk bar is too tight, add a menu item in the toolbar / View menu.

- [ ] **Step 6: Run tests**

Run: `swift test --filter BatchActionTests.testRetryFailedDeletes`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LiteMail/Core/AccountManager.swift Sources/LiteMail/Core/MailStore.swift Sources/LiteMail/GUI/BulkActionBar.swift Tests/LiteMailIntegrationTests/BatchActionTests.swift
git commit -m "feat(ui): retry failed deletes from bulk bar"
```

---

### Task 16: Permanent-failure toast

**Files:**
- Modify: `Sources/LiteMail/App/AppDelegate.swift`

- [ ] **Step 1: Observe `.deleteJobsPermanentlyFailed`**

In `AppDelegate.swift` `applicationDidFinishLaunching` (or wherever observers are registered):

```swift
NotificationCenter.default.addObserver(forName: .deleteJobsPermanentlyFailed,
                                       object: nil, queue: .main) { [weak self] note in
    let count = note.userInfo?["count"] as? Int ?? 0
    guard count > 0 else { return }
    self?.windowController?.statusBar.updateSyncStatus("Couldn't delete \(count) message\(count == 1 ? "" : "s") — see red badge, click Retry")
}
```

(If there is an existing undo/toast infrastructure, dispatch through that for consistency.)

- [ ] **Step 2: Build + manual smoke**

```bash
swift build 2>&1 | tail -5
```

Expected: build succeeds.

Manual: temporarily throw `IMAPProviderError.authenticationFailed` in `deleteMessageBatch`, run, delete a message → toast appears.

- [ ] **Step 3: Commit**

```bash
git add Sources/LiteMail/App/AppDelegate.swift
git commit -m "feat(ui): surface permanent delete failures in status bar"
```

---

## Phase G — Verification

### Task 17: End-to-end integration test

**Files:**
- Create: `Tests/LiteMailIntegrationTests/DeleteReconciliationE2ETests.swift`

- [ ] **Step 1: Write the E2E test**

Create the file:

```swift
import XCTest
@testable import LiteMail

final class DeleteReconciliationE2ETests: XCTestCase {

    private var path: String!
    private var store: MailStore!
    private var manager: AccountManager!
    private var provider: MockMailProvider!

    override func setUp() async throws {
        path = NSTemporaryDirectory() + "e2e_\(UUID().uuidString).sqlite"
        store = try MailStore(path: path)
        provider = MockMailProvider()
        // Construct manager with injected provider — use whichever helper your tests already use.
        manager = try await IntegrationTestHelpers.makeManager(store: store, provider: provider, accountId: "e2e")
    }

    override func tearDown() async throws {
        store = nil
        manager = nil
        try? FileManager.default.removeItem(atPath: path)
    }

    func testHappyPathDeleteReachesServerAndRemovesLocally() async throws {
        let ids = try await IntegrationTestHelpers.seedEmails(store: store, accountId: "e2e", folder: "INBOX", count: 3)

        try await manager.deleteBatch(emailIds: ids)
        await manager.deleteWorker.kick()

        // Emails gone locally
        let remaining = try await manager.listEmails(accountId: "e2e", folder: "INBOX", limit: 50)
        XCTAssertEqual(remaining.count, 0)
        // Provider saw the batch
        XCTAssertEqual(provider.deleteBatchCalls, 1)
    }

    func testTransientThenSuccessEventuallyDrains() async throws {
        let ids = try await IntegrationTestHelpers.seedEmails(store: store, accountId: "e2e", folder: "INBOX", count: 1)
        struct Transient: Error {}
        provider.nextErrorQueue = [Transient()]   // fail once, then succeed

        try await manager.deleteBatch(emailIds: ids)
        await manager.deleteWorker.kick()
        // After first kick, job still pending
        let mid: Int = try await store.concurrentReader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM delete_jobs") ?? -1
        }
        XCTAssertEqual(mid, 1)

        // Fast-forward: we pass 'now' high enough to exceed backoff
        await manager.deleteWorker.runOnce(now: Int.max)

        let rem: Int = try await store.concurrentReader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM delete_jobs") ?? -1
        }
        XCTAssertEqual(rem, 0)
    }

    func testPermanentFailureSurfacesAsDeleteFailed() async throws {
        let ids = try await IntegrationTestHelpers.seedEmails(store: store, accountId: "e2e", folder: "INBOX", count: 1)
        provider.nextErrorQueue = [IMAPProviderError.authenticationFailed]

        try await manager.deleteBatch(emailIds: ids)
        await manager.deleteWorker.kick()

        let state: String? = try await store.concurrentReader.read { db in
            try String.fetchOne(db, sql: "SELECT delete_state FROM emails WHERE id=?", arguments: [ids[0]])
        }
        XCTAssertEqual(state, "delete_failed")
    }
}
```

Ensure `MockMailProvider` supports a `nextErrorQueue: [Error]` that pops one error per call (add if missing).

- [ ] **Step 2: Extend MockMailProvider**

In `MockMailProvider.swift`:

```swift
var nextErrorQueue: [Error] = []
var deleteBatchCalls = 0

func deleteMessageBatch(messageRefs: [String]) async throws {
    deleteBatchCalls += 1
    if !nextErrorQueue.isEmpty {
        let err = nextErrorQueue.removeFirst()
        throw err
    }
}
```

Extend `IntegrationTestHelpers` with `makeManager` and `seedEmails` helpers if missing.

- [ ] **Step 3: Run the test**

Run: `swift test --filter DeleteReconciliationE2ETests`
Expected: all three PASS.

- [ ] **Step 4: Commit**

```bash
git add Tests/LiteMailIntegrationTests/DeleteReconciliationE2ETests.swift Tests/LiteMailIntegrationTests/MockMailProvider.swift Tests/LiteMailIntegrationTests/IntegrationTestHelpers.swift
git commit -m "test(delete-reconciliation): E2E happy/transient/permanent paths"
```

---

### Task 18: Manual smoke checklist + one-shot cleanup SQL

**Files:**
- Modify: `docs/superpowers/plans/2026-04-13-phased-delete-reconciliation.md` (append checklist)

- [ ] **Step 1: Run the full suite**

```bash
swift test 2>&1 | tail -30
```

Expected: all pass (protocol tests skipped if Docker not running).

- [ ] **Step 2: Manual smoke on `cthai83@gmail.com`**

1. Run `swift build && swift run LiteMail`.
2. Open the Github label — expect the restored 5k+ messages visible.
3. Select ~5 threads; click Delete in the bulk bar.
4. Expect: rows disappear instantly (pending_delete). Within ~5 seconds, Gmail web shows them moved to Trash.
5. Turn off wifi, select 5 more, click Delete.
6. Expect: rows disappear. After ~30 seconds of retry backoff, rows reappear with red `!` badge (delete_failed).
7. Turn wifi back on, click Retry in bulk bar; rows disappear and are gone server-side.
8. Quit app mid-delete (wifi on) → relaunch; remaining queued jobs finish within 10 seconds.

Document outcomes in a follow-up comment on the plan file. Any failed step → STOP and debug before merging.

- [ ] **Step 3: Optional — clean up the existing suspicious is_deleted=1 rows**

Close LiteMail first. Then:

```bash
DB="$HOME/Library/Application Support/LiteMail/mail.sqlite"
BAK="$HOME/Library/Application Support/LiteMail/mail.sqlite.bak-pre-cleanup-$(date +%Y%m%d-%H%M%S)"
sqlite3 "$DB" ".backup '$BAK'"
sqlite3 "$DB" "UPDATE emails SET is_deleted=0 WHERE account_id='BE84B180-427E-4C84-A479-8A5B256F9D36' AND is_deleted=1 AND folder IN ('Ca&AwE- nh&AOI-n/Facebook','Ca&AwE- nh&AOI-n/Google+','[Gmail]/Sent Mail','Me') AND (flags IS NULL OR flags NOT LIKE '%deleted%');"
```

Only run steps 3 after user confirms the folders they want restored.

- [ ] **Step 4: Commit the checklist update if anything changed**

```bash
git add docs/superpowers/plans/2026-04-13-phased-delete-reconciliation.md
git commit -m "docs(plan): record manual smoke outcomes + cleanup SQL"
```

---

## Appendix: Files touched summary

| File | Role |
|---|---|
| `Sources/LiteMail/Core/MailStore.swift` | v7 migration, `EmailRecord.deleteState`, `DeleteJobRecord`, queue APIs, reconciliation helpers |
| `Sources/LiteMail/Core/DeleteWorker.swift` (new) | Actor that drains the queue |
| `Sources/LiteMail/Core/AccountManager.swift` | `deleteBatch` rewrite, worker lifecycle, `retryFailedDeletes` |
| `Sources/LiteMail/Core/IMAPProvider.swift` | `reconcilePendingDeletes` hook in incremental sync |
| `Sources/LiteMail/Core/MailEngineProtocol.swift` | `EmailHeader.deleteState` field |
| `Sources/LiteMail/App/AppDelegate.swift` | `expandThreadIds` scoping, undo wiring, failure toast |
| `Sources/LiteMail/GUI/MessageListView.swift` | Row badge for `delete_failed` |
| `Sources/LiteMail/GUI/BulkActionBar.swift` | Retry button |
| `Tests/LiteMailTests/MailStoreTests.swift` | Migration + EmailRecord tests |
| `Tests/LiteMailTests/MailStoreBatchTests.swift` | Queue API tests |
| `Tests/LiteMailIntegrationTests/DeleteWorkerTests.swift` (new) | Worker unit tests |
| `Tests/LiteMailIntegrationTests/BatchActionTests.swift` | deleteBatch + undo + retry |
| `Tests/LiteMailIntegrationTests/ThreadExpansionTests.swift` (new) | Thread scoping |
| `Tests/LiteMailIntegrationTests/DeleteReconciliationE2ETests.swift` (new) | End-to-end |
| `Tests/LiteMailIntegrationTests/MockMailProvider.swift` | `nextErrorQueue`, `deleteBatchCalls` |
