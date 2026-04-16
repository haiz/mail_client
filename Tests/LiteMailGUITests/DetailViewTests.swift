import XCTest
import AppKit
@testable import LiteMail

@MainActor
final class ThreadViewTests: XCTestCase {

    func testCollapsedCardShowsSenderAndDate() {
        let header = GUITestData.sampleHeaders(count: 1).first!
        let card = MessageCardView(header: header, isExpanded: false)
        pumpRunLoop()

        XCTAssertFalse(card.isExpanded)
        XCTAssertNotNil(card.view)
    }

    func testCollapsedCardShowsSnippet() {
        let header = GUITestData.sampleHeaders(count: 1).first!
        let card = MessageCardView(header: header, isExpanded: false)
        pumpRunLoop()

        XCTAssertFalse(card.isExpanded)
    }

    func testCollapsedCardShowsAttachmentIcon() {
        let header = GUITestData.sampleHeaders(count: 3)[2]
        XCTAssertTrue(header.hasAttachments)
        let card = MessageCardView(header: header, isExpanded: false)
        pumpRunLoop()

        XCTAssertFalse(card.isExpanded)
    }

    // MARK: - ThreadDetailView Tests

    func testThreadDisplayCreatesCards() {
        let threadView = ThreadDetailView()
        let thread = GUITestData.sampleThread(count: 3)
        threadView.display(thread: thread, subject: "Re: Thread Subject")
        pumpRunLoop()
        XCTAssertEqual(threadView.cardCount, 3)
    }

    func testAutoExpandNewestAndUnread() {
        let threadView = ThreadDetailView()
        let thread = GUITestData.sampleThread(count: 3)
        threadView.display(thread: thread, subject: "Re: Thread Subject")
        pumpRunLoop()
        XCTAssertTrue(threadView.isCardExpanded(at: 2))
        XCTAssertFalse(threadView.isCardExpanded(at: 0))
        XCTAssertFalse(threadView.isCardExpanded(at: 1))
    }

    func testSingleEmailUsesThreadLayout() {
        let threadView = ThreadDetailView()
        let single = [GUITestData.sampleHeaders(count: 1).first!]
        threadView.display(thread: single, subject: "Single Email")
        pumpRunLoop()
        XCTAssertEqual(threadView.cardCount, 1)
        XCTAssertTrue(threadView.isCardExpanded(at: 0))
    }

    func testEmptyState() {
        let threadView = ThreadDetailView()
        threadView.clear()
        pumpRunLoop()
        XCTAssertEqual(threadView.cardCount, 0)
    }

    func testBulkSummary() {
        let threadView = ThreadDetailView()
        let headers = GUITestData.sampleHeaders(count: 3)
        threadView.showBulkSummary(headers: headers)
        pumpRunLoop()
        XCTAssertNotNil(threadView.view)
    }
}
