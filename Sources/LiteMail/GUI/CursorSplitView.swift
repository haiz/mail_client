import AppKit

/// NSSplitView subclass that adds a resize cursor rect centered on each divider.
///
/// NSSplitView with .thin divider style has a 1px divider. Adjacent subviews
/// extend flush to the divider edge, so the mouse never enters the divider's
/// hit region. This subclass registers a 6pt-wide cursor rect centered on
/// each divider position, giving the user a real grab target.
final class CursorSplitView: NSSplitView {
    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor: NSCursor = isVertical ? .resizeLeftRight : .resizeUpDown
        let hitWidth: CGFloat = 6
        for i in 0..<(subviews.count - 1) {
            let a = subviews[i].frame
            let mid = isVertical ? a.maxX : a.maxY
            let rect: NSRect = isVertical
                ? NSRect(x: mid - hitWidth / 2, y: 0, width: hitWidth, height: bounds.height)
                : NSRect(x: 0, y: mid - hitWidth / 2, width: bounds.width, height: hitWidth)
            addCursorRect(rect, cursor: cursor)
        }
    }
}
