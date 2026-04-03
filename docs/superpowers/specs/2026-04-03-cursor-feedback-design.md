# Cursor Feedback — Design Spec
**Date:** 2026-04-03

## Problem

The cursor never changes from the default arrow in LiteMail, regardless of what the user hovers over:
- Clickable buttons show no pointing hand
- Hyperlinks in email bodies show no pointing hand
- The split view dividers show no resize cursor

This removes a standard affordance signal that users rely on to understand what is interactive.

## Root Cause

- **Buttons:** `NSButton` does not set cursor rects by default in AppKit. Each button must override `resetCursorRects()` to register a cursor.
- **Split view dividers:** The split view uses `.thin` divider style (1px). Adjacent subviews extend flush to the divider, so the mouse never technically enters the divider's hit region. AppKit's built-in resize cursor logic is blocked.
- **Links:** `NSTextView` cursor-for-link handling requires either `isEditable = true` or an explicit tracking area with `.cursorUpdate` events.

## Solution: Cursor-Aware Subclasses (Option A)

Use the standard AppKit pattern: override `resetCursorRects()` in focused subclasses. No changes to visual appearance or interaction behavior.

---

## Components

### 1. `CursorButton` — `Sources/LiteMail/GUI/CursorButton.swift`

Minimal `NSButton` subclass. Overrides `resetCursorRects()` to add `.pointingHand` over the full bounds.

```swift
class CursorButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
```

All `NSButton(...)` creation sites in the GUI layer are replaced with `CursorButton(...)`. No other behavior changes.

### 2. `CursorSplitView` — `Sources/LiteMail/GUI/CursorSplitView.swift`

`NSSplitView` subclass. In `resetCursorRects()`, iterates adjacent subview pairs, computes each divider's center position, and registers a 6px-wide cursor rect (`.resizeLeftRight` for vertical splits, `.resizeUpDown` for horizontal) centered on the divider. The 6px width gives a real mouse target despite the 1px visual line.

```swift
class CursorSplitView: NSSplitView {
    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor: NSCursor = isVertical ? .resizeLeftRight : .resizeUpDown
        let hitWidth: CGFloat = 6
        for i in 0..<(subviews.count - 1) {
            let a = subviews[i].frame
            let b = subviews[i + 1].frame
            let mid = isVertical ? a.maxX : a.maxY
            let rect: NSRect = isVertical
                ? NSRect(x: mid - hitWidth / 2, y: 0, width: hitWidth, height: bounds.height)
                : NSRect(x: 0, y: mid - hitWidth / 2, width: bounds.width, height: hitWidth)
            addCursorRect(rect, cursor: cursor)
        }
    }
}
```

### 3. Link cursor in `DetailView`

The detail body `NSTextView` is read-only (`isEditable = false`). AppKit's automatic link cursor only activates for editable text views. Fix: add an `NSTrackingArea` with `.cursorUpdate` option to the text view, and override `cursorUpdate(with:)` to check if the mouse is over a `.link` attribute range. If so, push `.pointingHand`; otherwise call `super`.

---

## Change Surface

| File | Change |
|------|--------|
| `GUI/CursorButton.swift` | New file (~15 LOC) |
| `GUI/CursorSplitView.swift` | New file (~30 LOC) |
| `GUI/MainWindowController.swift` | `NSSplitView()` → `CursorSplitView()` (1 line) |
| `GUI/DetailView.swift` | Replace ~8 `NSButton` inits + add link cursor tracking |
| `GUI/SidebarView.swift` | Replace ~2 `NSButton` inits |
| `GUI/ComposerWindow.swift` | Replace ~6 `NSButton` inits |
| `GUI/SettingsWindow.swift` | Replace ~4 `NSButton` inits |
| `GUI/MessageListView.swift` | Replace any `NSButton` inits |

## What Does Not Change

- Visual appearance of buttons, dividers, or links
- Any interaction behavior, callbacks, or actions
- `AccountSwitcherView` (already correctly uses `resetCursorRects`)
- All other AppKit behavior

## Testing Criteria

- [ ] Hover over any toolbar button → pointer hand cursor appears
- [ ] Hover over a hyperlink in an email body → pointer hand cursor appears
- [ ] Hover over the divider between sidebar and message list → resize cursor appears
- [ ] Hover over the divider between message list and detail view → resize cursor appears
- [ ] Cursor returns to arrow when moving off interactive elements
- [ ] No regressions in button click behavior or split view resizing
