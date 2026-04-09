import XCTest
import AppKit
@testable import LiteMail

@MainActor
final class DetailViewTests: XCTestCase {

    func testPlainTextEmail() {
        let detail = DetailView()
        let header = GUITestData.sampleHeaders(count: 1).first!
        let body = GUITestData.sampleBody(emailId: 1, html: false)

        detail.display(header: header, body: body)
        pumpRunLoop()

        XCTAssertNotNil(detail.view)
    }

    func testHTMLEmail() {
        let detail = DetailView()
        let header = GUITestData.sampleHeaders(count: 1).first!
        let body = GUITestData.sampleBody(emailId: 1, html: true)

        detail.display(header: header, body: body)
        pumpRunLoop(seconds: 0.5)

        XCTAssertNotNil(detail.webView)
    }

    func testEmptyState() {
        let detail = DetailView()
        detail.clear()
        pumpRunLoop()

        XCTAssertNil(detail.webView)
    }

    func testReplyCallback() {
        let detail = DetailView()
        var replyCalled = false
        detail.onReply = { replyCalled = true }
        detail.onReply?()
        XCTAssertTrue(replyCalled)
    }

    func testForwardCallback() {
        let detail = DetailView()
        var forwardCalled = false
        detail.onForward = { forwardCalled = true }
        detail.onForward?()
        XCTAssertTrue(forwardCalled)
    }

    func testArchiveCallback() {
        let detail = DetailView()
        var archiveCalled = false
        detail.onArchive = { archiveCalled = true }
        detail.onArchive?()
        XCTAssertTrue(archiveCalled)
    }

    func testDeleteCallback() {
        let detail = DetailView()
        var deleteCalled = false
        detail.onDelete = { deleteCalled = true }
        detail.onDelete?()
        XCTAssertTrue(deleteCalled)
    }

    func testAttachmentDownloadCallback() {
        let detail = DetailView()
        let attachments = GUITestData.sampleAttachments(emailId: 1)

        var downloadedAttachment: AttachmentInfo?
        detail.onDownloadAttachment = { att in downloadedAttachment = att }
        detail.onDownloadAttachment?(attachments.first!)

        XCTAssertEqual(downloadedAttachment?.filename, "photo.jpg")
    }
}
