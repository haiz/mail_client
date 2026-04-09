import XCTest
@testable import LiteMail

final class AttachmentTests: XCTestCase {

    func testListAttachments() async throws {
        let (manager, _, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let emailId = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<att@test>", accountId: "test-account", uid: 1, hasAttachments: true)
        )

        try await store.insertAttachments([
            AttachmentRecord(emailId: emailId, partId: "1.1", filename: "photo.jpg", mimeType: "image/jpeg", sizeBytes: 204800),
            AttachmentRecord(emailId: emailId, partId: "1.2", filename: "doc.pdf", mimeType: "application/pdf", sizeBytes: 512000),
        ])

        let attachments = try await manager.listAttachments(emailId: emailId)
        XCTAssertEqual(attachments.count, 2)

        let filenames = Set(attachments.compactMap(\.filename))
        XCTAssertEqual(filenames, Set(["photo.jpg", "doc.pdf"]))
    }

    func testFetchAttachmentData() async throws {
        let (manager, mockProvider, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let emailId = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<att-data@test>", accountId: "test-account", uid: 2, hasAttachments: true)
        )

        try await store.insertAttachments([
            AttachmentRecord(emailId: emailId, partId: "2.1", filename: "data.bin", mimeType: "application/octet-stream", sizeBytes: 100),
        ])

        let testData = Data("binary-content-here".utf8)
        await mockProvider.setStubbedAttachments(["folder:INBOX:uid:2:2.1": testData])

        let data = try await manager.fetchAttachmentData(emailId: emailId, partId: "2.1")
        XCTAssertEqual(data, testData)

        let fetchCalls = await mockProvider.fetchAttachmentCalls
        XCTAssertEqual(fetchCalls.count, 1)
        XCTAssertEqual(fetchCalls.first?.partId, "2.1")
    }

    func testNoAttachments() async throws {
        let (manager, _, store) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let emailId = try await store.insertEmail(
            TestData.makeEmailRecord(messageId: "<no-att@test>", accountId: "test-account", uid: 3)
        )

        let attachments = try await manager.listAttachments(emailId: emailId)
        XCTAssertEqual(attachments.count, 0)
    }
}
