import XCTest
@testable import LiteMail

final class ComposeTests: XCTestCase {

    func testComposeSend() async throws {
        let (manager, mockProvider, _) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let message = TestData.makeOutgoingMessage(
            to: ["recipient@example.com"],
            subject: "Hello",
            bodyText: "World"
        )

        try await manager.send(message: message, fromAccountId: "test-account")

        let sendCalls = await mockProvider.sendCalls
        XCTAssertEqual(sendCalls.count, 1)
        XCTAssertEqual(sendCalls.first?.to, ["recipient@example.com"])
        XCTAssertEqual(sendCalls.first?.subject, "Hello")
        XCTAssertEqual(sendCalls.first?.bodyText, "World")
    }

    func testSaveDraft() async throws {
        let (manager, _, _) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let draft = TestData.makeOutgoingMessage(subject: "Draft subject", bodyText: "Draft body")

        // saveDraft should not throw
        try await manager.saveDraft(draft, accountId: "test-account")
    }

    func testDraftStatusTransitions() async throws {
        let (_, _, store) = try await makeTestAccountManager()

        let outbox = OutboxRecord(
            toRecipients: "[\"to@test.com\"]",
            subject: "Draft",
            bodyText: "body",
            status: "drafted",
            accountId: "test-account"
        )
        let id = try await store.queueOutgoing(outbox)

        try await store.updateOutboxStatus(id: id, status: "sending")
        try await store.updateOutboxStatus(id: id, status: "sent")

        let afterSent = try await store.fetchPendingOutbox()
        XCTAssertTrue(afterSent.allSatisfy { $0.id != id })
    }

    func testReplyHasInReplyTo() async throws {
        let (manager, mockProvider, _) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let reply = OutgoingMessage(
            to: ["original-sender@test.com"],
            cc: [],
            bcc: [],
            subject: "Re: Original Subject",
            bodyText: "My reply",
            inReplyTo: "<original-msg-id@test>"
        )

        try await manager.send(message: reply, fromAccountId: "test-account")

        let sendCalls = await mockProvider.sendCalls
        XCTAssertEqual(sendCalls.count, 1)
        XCTAssertEqual(sendCalls.first?.inReplyTo, "<original-msg-id@test>")
        XCTAssertEqual(sendCalls.first?.subject, "Re: Original Subject")
    }

    func testForwardIncludesAttachments() async throws {
        let (manager, mockProvider, _) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        let forward = OutgoingMessage(
            to: ["forward-to@test.com"],
            cc: [],
            bcc: [],
            subject: "Fwd: Original Subject",
            bodyText: "---------- Forwarded message ----------\nOriginal body",
            attachments: [
                OutgoingAttachment(filename: "doc.pdf", mimeType: "application/pdf", data: Data("pdf-content".utf8))
            ]
        )

        try await manager.send(message: forward, fromAccountId: "test-account")

        let sendCalls = await mockProvider.sendCalls
        XCTAssertEqual(sendCalls.count, 1)
        XCTAssertEqual(sendCalls.first?.attachments.count, 1)
        XCTAssertEqual(sendCalls.first?.attachments.first?.filename, "doc.pdf")
    }

    func testSendFailureThrows() async throws {
        let (manager, mockProvider, _) = try await makeTestAccountManager()
        try await manager.addAccount(TestData.makeAccountConfig())

        await mockProvider.setStubbedError(NSError(domain: "SMTP", code: 550, userInfo: [NSLocalizedDescriptionKey: "Relay denied"]))

        let message = TestData.makeOutgoingMessage()

        do {
            try await manager.send(message: message, fromAccountId: "test-account")
            XCTFail("Expected send to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Relay denied"))
        }
    }
}
