import XCTest
@testable import LiteMail

final class FolderLabelTests: XCTestCase {

    func testListFolders() async throws {
        let (manager, _, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        // listFolders requires sync_state entries
        try await store.updateSyncState(SyncStateRecord(accountId: "test-account", folder: "INBOX"))
        try await store.updateSyncState(SyncStateRecord(accountId: "test-account", folder: "[Gmail]/Sent Mail"))

        _ = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<f1@test>", folder: "INBOX", accountId: "test-account", uid: 1, isRead: false)
        )
        _ = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<f2@test>", folder: "INBOX", accountId: "test-account", uid: 2, isRead: true)
        )
        _ = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<f3@test>", folder: "[Gmail]/Sent Mail", accountId: "test-account", uid: 3, isRead: true)
        )

        let folders = try await manager.listFolders(accountId: "test-account")

        let inbox = folders.first(where: { $0.id == "INBOX" })
        XCTAssertNotNil(inbox, "Should find INBOX folder. Got folders: \(folders.map { "\($0.id):\($0.name)" })")
        XCTAssertEqual(inbox?.totalCount, 2, "INBOX should have 2 total emails")
        XCTAssertTrue(inbox?.hasUnread == true, "INBOX should have unread emails")
    }

    func testAllLabelsForAccount() async throws {
        let (manager, _, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let id1 = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<lbl1@test>", accountId: "test-account", uid: 1)
        )
        let id2 = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<lbl2@test>", accountId: "test-account", uid: 2)
        )

        try await store.addLabel(emailId: id1, label: "work")
        try await store.addLabel(emailId: id1, label: "urgent")
        try await store.addLabel(emailId: id2, label: "work")
        try await store.addLabel(emailId: id2, label: "personal")

        let allLabels = try await manager.allLabels(accountId: "test-account")
        XCTAssertEqual(Set(allLabels), Set(["work", "urgent", "personal"]))
    }

    func testFetchLabelsForEmail() async throws {
        let (manager, _, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let emailId = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<lbl-fetch@test>", accountId: "test-account", uid: 1)
        )

        try await store.addLabel(emailId: emailId, label: "alpha")
        try await store.addLabel(emailId: emailId, label: "beta")

        let labels = try await manager.fetchLabels(emailId: emailId)
        XCTAssertEqual(Set(labels), Set(["alpha", "beta"]))
    }

    func testCreateFolder() async throws {
        let (manager, mockProvider, _) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        try await manager.createFolder(name: "Custom Folder", accountId: "test-account")

        let createCalls = await mockProvider.createFolderCalls
        XCTAssertEqual(createCalls.count, 1)
        XCTAssertEqual(createCalls.first, "Custom Folder")
    }
}
