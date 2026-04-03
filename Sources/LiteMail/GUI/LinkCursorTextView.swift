import AppKit

/// NSTextView subclass that shows a pointing-hand cursor when hovering over links.
///
/// AppKit's automatic link cursor only activates when isEditable = true.
/// This subclass adds a cursorUpdate tracking area and checks the .link
/// attribute at the mouse position to set the cursor manually.
final class LinkCursorTextView: NSTextView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard
            let layout = layoutManager,
            let container = textContainer,
            let storage = textStorage
        else {
            super.cursorUpdate(with: event)
            return
        }
        let adjusted = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        let glyphIndex = layout.glyphIndex(for: adjusted, in: container)
        let charIndex = layout.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < storage.length else {
            super.cursorUpdate(with: event)
            return
        }
        if storage.attribute(.link, at: charIndex, effectiveRange: nil) != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }
}
