import AppKit

/// NSButton subclass that shows a pointing-hand cursor on hover.
final class CursorButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
