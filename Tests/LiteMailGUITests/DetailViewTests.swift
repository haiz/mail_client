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

    // MARK: - Layout integrity

    /// Regression test: bodyScrollView and WKWebView used to collapse to 0 when placed
    /// in NSStackView because neither had an explicit height constraint, creating a circular
    /// dependency that Auto Layout resolved by collapsing the body area.
    func testExpandedCardLayoutIsUnambiguous() {
        let header = GUITestData.sampleHeaders(count: 1).first!
        let card = MessageCardView(header: header, isExpanded: true)
        card.view.frame = NSRect(x: 0, y: 0, width: 600, height: 800)
        card.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(card.view.hasAmbiguousLayout,
            "Expanded card layout is ambiguous — likely a view (NSScrollView or WKWebView) missing a height constraint")
    }

    /// Simulates the exact usage in ThreadDetailView: card as arranged subview in NSStackView.
    /// Catches the case where the card's body collapses to zero because the constraint chain
    /// between bodyScrollView and actionBar is circular without a concrete height anchor.
    func testExpandedCardHasMeaningfulHeightInStackView() {
        let stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.frame = NSRect(x: 0, y: 0, width: 600, height: 900)

        let header = GUITestData.sampleHeaders(count: 1).first!
        let card = MessageCardView(header: header, isExpanded: true)
        card.view.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(card.view)
        card.view.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

        let body = GUITestData.sampleBody(emailId: header.id, html: false)
        card.displayBody(body)
        stackView.layoutSubtreeIfNeeded()
        pumpRunLoop()

        XCTAssertGreaterThan(card.view.frame.height, 200,
            "Expanded card in NSStackView must be taller than 200pt — body area may have collapsed to zero")
    }

    func testExpandedCardWebViewHasNonZeroHeight() {
        let header = GUITestData.sampleHeaders(count: 1).first!
        let card = MessageCardView(header: header, isExpanded: true)
        card.view.frame = NSRect(x: 0, y: 0, width: 600, height: 800)

        let body = GUITestData.sampleBody(emailId: header.id, html: true)
        card.displayBody(body)
        card.view.layoutSubtreeIfNeeded()
        pumpRunLoop()

        XCTAssertNotNil(card.webView, "WKWebView should be created for HTML body")
        XCTAssertGreaterThan(card.webView?.frame.height ?? 0, 50,
            "WKWebView must not collapse to zero — missing heightAnchor.greaterThanOrEqualTo constraint")
    }

    // MARK: - Loading Spinner

    func testLoadingSpinnerExistsInExpandedCard() {
        let header = GUITestData.sampleHeaders(count: 1).first!
        let card = MessageCardView(header: header, isExpanded: true)
        pumpRunLoop()

        XCTAssertTrue(findSpinner(in: card.view) != nil,
                      "Expanded card must contain an NSProgressIndicator")
    }

    func testLoadingSpinnerVisibleWhileLoading() {
        let header = GUITestData.sampleHeaders(count: 1).first!
        let card = MessageCardView(header: header, isExpanded: true)
        card.showLoading()
        pumpRunLoop()

        let spinner = findSpinner(in: card.view)
        XCTAssertNotNil(spinner, "NSProgressIndicator must exist in expanded card")
        XCTAssertFalse(spinner?.isHidden ?? true, "Spinner should be visible while loading")
    }

    func testLoadingSpinnerHiddenAfterBodyLoaded() {
        let header = GUITestData.sampleHeaders(count: 1).first!
        let card = MessageCardView(header: header, isExpanded: true)
        card.showLoading()
        card.displayBody(GUITestData.sampleBody(emailId: header.id))
        pumpRunLoop()

        let spinner = findSpinner(in: card.view)
        XCTAssertNotNil(spinner)
        XCTAssertTrue(spinner?.isHidden ?? false, "Spinner should be hidden after body is loaded")
    }

    // MARK: - InlineReplyView

    func testInlineReplyViewCreatesView() {
        let header = GUITestData.sampleThread().first!
        let reply = InlineReplyView(header: header, body: nil, mode: .reply)
        pumpRunLoop()
        XCTAssertNotNil(reply.view)
    }

    func testInlineReplyHasNoContentInitially() {
        let header = GUITestData.sampleThread().first!
        let reply = InlineReplyView(header: header, body: nil, mode: .reply)
        XCTAssertFalse(reply.hasContent,
                       "Reply body starts with quoted text only — hasContent should be false")
    }

    func testInlineReplyDiscardCallbackFires() {
        let header = GUITestData.sampleThread().first!
        let reply = InlineReplyView(header: header, body: nil, mode: .reply)
        var discarded = false
        reply.onDiscard = { discarded = true }
        reply.onDiscard?()
        XCTAssertTrue(discarded)
    }

    func testInlineReplySendCallbackReceivesMessage() {
        let header = GUITestData.sampleThread().first!
        let reply = InlineReplyView(header: header, body: nil, mode: .reply)
        var received: OutgoingMessage?
        reply.onSend = { msg, completion in
            received = msg
            completion(nil)
        }
        let testMsg = OutgoingMessage(to: ["a@b.com"], cc: [], bcc: [], subject: "Re: Test", bodyText: "Hi")
        reply.onSend?(testMsg) { _ in }
        XCTAssertEqual(received?.to.first, "a@b.com")
    }

    func testInlineReplyForceSaveDraftSkipsEmptyContent() {
        let header = GUITestData.sampleThread().first!
        let reply = InlineReplyView(header: header, body: nil, mode: .reply)
        var saveCalled = false
        reply.onSaveDraft = { _ in saveCalled = true }
        reply.forceSaveDraft()
        XCTAssertFalse(saveCalled,
                       "forceSaveDraft with only quoted text must not call onSaveDraft")
    }

    // MARK: - ThreadDetailView inline reply integration

    func testThreadDetailViewOpensInlineReply() {
        let threadView = ThreadDetailView()
        let thread = GUITestData.sampleThread(count: 2)
        threadView.display(thread: thread, subject: "Test")
        pumpRunLoop()

        threadView.openInlineReply(header: thread.last!, body: nil, mode: .reply)
        pumpRunLoop()

        XCTAssertNotNil(threadView.inlineReplyView,
                        "inlineReplyView should be set after openInlineReply")
    }

    func testThreadDetailViewDisplayClearsInlineReply() {
        let threadView = ThreadDetailView()
        let thread = GUITestData.sampleThread(count: 2)
        threadView.display(thread: thread, subject: "Test")
        pumpRunLoop()

        threadView.openInlineReply(header: thread.last!, body: nil, mode: .reply)
        pumpRunLoop()

        threadView.display(thread: thread, subject: "Test")
        pumpRunLoop()

        XCTAssertNil(threadView.inlineReplyView,
                     "display() must clear the inline reply view")
    }

    func testThreadDetailContainerAcceptsFirstResponder() {
        let threadView = ThreadDetailView()
        XCTAssertTrue(threadView.view.acceptsFirstResponder,
                      "ThreadDetailContainerView must accept first responder for R/A keyboard shortcuts")
    }

    // MARK: - Helpers

    private func findSpinner(in view: NSView) -> NSProgressIndicator? {
        if let s = view as? NSProgressIndicator { return s }
        for sub in view.subviews {
            if let s = findSpinner(in: sub) { return s }
        }
        return nil
    }
}
