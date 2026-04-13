import AppKit

/// NSSplitView subclass that shows a resize cursor when hovering over dividers.
///
/// Uses mouseEntered/mouseExited + NSCursor.push()/pop() rather than
/// cursorUpdate + set(), because set() is overridden by the window's
/// cursor-rect system. A pushed cursor stays on the stack and survives.
final class CursorSplitView: NSSplitView {
    private var dividerTrackingAreas: [NSTrackingArea] = []

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in dividerTrackingAreas { removeTrackingArea(area) }
        dividerTrackingAreas.removeAll()

        let hitWidth: CGFloat = 6
        for i in 0..<(subviews.count - 1) {
            let a = subviews[i].frame
            let mid = isVertical ? a.maxX : a.maxY
            let rect: NSRect = isVertical
                ? NSRect(x: mid - hitWidth / 2, y: 0, width: hitWidth, height: bounds.height)
                : NSRect(x: 0, y: mid - hitWidth / 2, width: bounds.width, height: hitWidth)
            let area = NSTrackingArea(
                rect: rect,
                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            dividerTrackingAreas.append(area)
        }
    }

    override func mouseEntered(with event: NSEvent) {
        guard let area = event.trackingArea, dividerTrackingAreas.contains(area) else {
            super.mouseEntered(with: event)
            return
        }
        let cursor: NSCursor = isVertical ? .resizeLeftRight : .resizeUpDown
        cursor.push()
    }

    override func mouseExited(with event: NSEvent) {
        guard let area = event.trackingArea, dividerTrackingAreas.contains(area) else {
            super.mouseExited(with: event)
            return
        }
        NSCursor.pop()
    }
}
