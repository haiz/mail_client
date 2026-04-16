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
}
