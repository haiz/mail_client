import XCTest
@testable import LiteMail

final class EmailActionTests: XCTestCase {

    func testMarkReadUnread() async throws {
        let (manager, mockProvider, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let emailId = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<read@test>", accountId: "test-account", uid: 10, isRead: false)
        )

        try await manager.markRead(emailId: emailId, read: true)

        let record = try await store.fetchEmailRecord(id: emailId)
        XCTAssertEqual(record?.isRead, true)

        try await Task.sleep(nanoseconds: 100_000_000)
        let readCalls = await mockProvider.markReadCalls
        XCTAssertEqual(readCalls.count, 1)
        XCTAssertEqual(readCalls.first?.read, true)

        try await manager.markRead(emailId: emailId, read: false)
        let recordAfter = try await store.fetchEmailRecord(id: emailId)
        XCTAssertEqual(recordAfter?.isRead, false)
    }

    func testMarkStarred() async throws {
        let (manager, mockProvider, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let emailId = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<star@test>", accountId: "test-account", uid: 11, isStarred: false)
        )

        try await manager.markStarred(emailId: emailId, starred: true)

        let record = try await store.fetchEmailRecord(id: emailId)
        XCTAssertEqual(record?.isStarred, true)

        try await Task.sleep(nanoseconds: 100_000_000)
        let starCalls = await mockProvider.markStarredCalls
        XCTAssertEqual(starCalls.count, 1)
        XCTAssertEqual(starCalls.first?.starred, true)
    }

    func testArchive() async throws {
        let (manager, mockProvider, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let emailId = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<archive@test>", folder: "INBOX", accountId: "test-account", uid: 12)
        )

        try await manager.archive(emailId: emailId)

        let record = try await store.fetchEmailRecord(id: emailId)
        XCTAssertEqual(record?.folder, "[Gmail]/All Mail")

        try await Task.sleep(nanoseconds: 100_000_000)
        let moveCalls = await mockProvider.moveCalls
        XCTAssertEqual(moveCalls.count, 1)
        XCTAssertEqual(moveCalls.first?.toFolderId, "[Gmail]/All Mail")
    }

    func testDelete() async throws {
        let (manager, mockProvider, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let emailId = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<delete@test>", accountId: "test-account", uid: 13)
        )

        try await manager.delete(emailId: emailId)

        let record = try await store.fetchEmailRecord(id: emailId)
        XCTAssertEqual(record?.isDeleted, true)

        try await Task.sleep(nanoseconds: 100_000_000)
        let deleteCalls = await mockProvider.deleteCalls
        XCTAssertEqual(deleteCalls.count, 1)
    }

    func testMoveToFolder() async throws {
        let (manager, mockProvider, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let emailId = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<move@test>", folder: "INBOX", accountId: "test-account", uid: 14)
        )

        try await manager.move(emailId: emailId, toFolder: "[Gmail]/Trash")

        let record = try await store.fetchEmailRecord(id: emailId)
        XCTAssertEqual(record?.folder, "[Gmail]/Trash")

        try await Task.sleep(nanoseconds: 100_000_000)
        let moveCalls = await mockProvider.moveCalls
        XCTAssertEqual(moveCalls.count, 1)
        XCTAssertEqual(moveCalls.first?.toFolderId, "[Gmail]/Trash")
    }

    func testAddRemoveLabel() async throws {
        let (manager, _, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let emailId = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<label@test>", accountId: "test-account", uid: 15)
        )

        try await manager.addLabel(emailId: emailId, label: "important")
        try await manager.addLabel(emailId: emailId, label: "work")

        var labels = try await manager.fetchLabels(emailId: emailId)
        XCTAssertEqual(Set(labels), Set(["important", "work"]))

        try await manager.removeLabel(emailId: emailId, label: "important")

        labels = try await manager.fetchLabels(emailId: emailId)
        XCTAssertEqual(labels, ["work"])
    }
}
