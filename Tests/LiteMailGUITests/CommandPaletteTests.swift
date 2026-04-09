import XCTest
import AppKit
@testable import LiteMail

@MainActor
final class CommandPaletteTests: XCTestCase {

    func testShowAndDismiss() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)

        let palette = CommandPalette(parentWindow: window)
        palette.show()
        pumpRunLoop()

        XCTAssertTrue(palette.isVisible)

        palette.dismiss()
        pumpRunLoop()

        XCTAssertFalse(palette.isVisible)
    }

    func testActionCallback() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)

        let palette = CommandPalette(parentWindow: window)

        var receivedAction: MailAction?
        palette.onAction = { action in receivedAction = action }

        palette.onAction?(.compose)

        if case .compose = receivedAction {
            // Expected
        } else {
            XCTFail("Expected compose action")
        }
    }

    func testShowDismissShow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)

        let palette = CommandPalette(parentWindow: window)

        palette.show()
        pumpRunLoop()
        XCTAssertTrue(palette.isVisible)

        palette.dismiss()
        pumpRunLoop()
        XCTAssertFalse(palette.isVisible)

        palette.show()
        pumpRunLoop()
        XCTAssertTrue(palette.isVisible)

        palette.dismiss()
    }
}
