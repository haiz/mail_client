import XCTest
import AppKit
@testable import LiteMail

@MainActor
final class ComposerTests: XCTestCase {

    func testNewCompose() {
        let composer = ComposerWindow(mode: .compose)
        composer.setAccounts([
            (id: "acc1", email: "user1@test.com"),
            (id: "acc2", email: "user2@test.com"),
        ], selected: "acc1")
        pumpRunLoop()

        XCTAssertNotNil(composer.window)
        XCTAssertEqual(composer.selectedAccountId, "acc1")
    }

    func testReplyCompose() {
        let originalHeader = GUITestData.sampleHeaders(count: 1).first!
        let originalBody = GUITestData.sampleBody(emailId: 1)

        let composer = ComposerWindow(mode: .reply(to: originalHeader, body: originalBody))
        composer.setAccounts([(id: GUITestData.testAccountId, email: GUITestData.testEmail)], selected: GUITestData.testAccountId)
        pumpRunLoop()

        XCTAssertNotNil(composer.window)
    }

    func testForwardCompose() {
        let originalHeader = GUITestData.sampleHeaders(count: 1).first!
        let originalBody = GUITestData.sampleBody(emailId: 1)

        let composer = ComposerWindow(mode: .forward(original: originalHeader, body: originalBody))
        composer.setAccounts([(id: GUITestData.testAccountId, email: GUITestData.testEmail)], selected: GUITestData.testAccountId)
        pumpRunLoop()

        XCTAssertNotNil(composer.window)
    }

    func testSendCallback() {
        let composer = ComposerWindow(mode: .compose)
        composer.setAccounts([(id: "acc1", email: "test@test.com")], selected: "acc1")
        pumpRunLoop()

        var sentMessage: OutgoingMessage?
        composer.onSend = { message, completion in
            sentMessage = message
            completion(nil)
        }

        let testMessage = OutgoingMessage(to: ["recipient@test.com"], cc: [], bcc: [], subject: "Test", bodyText: "Body")
        composer.onSend?(testMessage) { _ in }

        XCTAssertNotNil(sentMessage)
        XCTAssertEqual(sentMessage?.to, ["recipient@test.com"])
    }

    func testDraftSaveCallback() {
        let composer = ComposerWindow(mode: .compose)
        pumpRunLoop()

        var savedDraft: OutgoingMessage?
        composer.onSaveDraft = { draft in savedDraft = draft }

        let draft = OutgoingMessage(to: ["someone@test.com"], cc: [], bcc: [], subject: "Draft", bodyText: "In progress")
        composer.onSaveDraft?(draft)

        XCTAssertNotNil(savedDraft)
        XCTAssertEqual(savedDraft?.subject, "Draft")
    }
}
