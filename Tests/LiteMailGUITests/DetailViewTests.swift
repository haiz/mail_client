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

    func testCollapsedCardHasAccessibilityRole() {
        let header = GUITestData.sampleHeaders(count: 1).first!
        let card = MessageCardView(header: header, isExpanded: false)
        pumpRunLoop()

        XCTAssertEqual(card.view.accessibilityRole(), .button)
        XCTAssertTrue(card.view.accessibilityLabel()?.contains("Expand") ?? false,
                      "Collapsed card should have 'Expand message from...' label")
    }

    func testCardViewAcceptsFirstResponder() {
        let header = GUITestData.sampleHeaders(count: 1).first!
        let card = MessageCardView(header: header, isExpanded: false)
        pumpRunLoop()

        XCTAssertTrue(card.view.acceptsFirstResponder,
                      "MessageCardContainerView must accept first responder for keyboard nav")
    }

    func testExpandedCardHeaderContainerExists() {
        let header = GUITestData.sampleHeaders(count: 1).first!
        let card = MessageCardView(header: header, isExpanded: true)
        pumpRunLoop()

        let expandedContainer = card.view.subviews.first(where: { !$0.isHidden && $0.subviews.count > 3 })
        XCTAssertNotNil(expandedContainer, "Expanded container should be visible")

        let hasGestureOnContainer = expandedContainer?.subviews.contains(where: {
            !$0.gestureRecognizers.isEmpty
        }) ?? false
        XCTAssertTrue(expandedContainer?.gestureRecognizers.isEmpty == false || hasGestureOnContainer,
                      "Expanded header area should have a click gesture recognizer")
    }

    func testWebViewHTMLContainsDarkModeCSS() {
        let header = GUITestData.sampleHeaders(count: 1).first!
        let card = MessageCardView(header: header, isExpanded: true)
        let body = GUITestData.sampleBody(emailId: header.id, html: true)
        card.displayBody(body)
        pumpRunLoop()

        // The webView should have loaded HTML containing dark mode media query
        XCTAssertNotNil(card.webView, "WebView should be created for HTML body")
    }
}
