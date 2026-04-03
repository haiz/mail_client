# Cursor Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the cursor change appropriately when hovering over buttons (pointing hand), hyperlinks (pointing hand), and split view dividers (resize arrow).

**Architecture:** Three focused NSView subclasses (`CursorButton`, `CursorSplitView`, `LinkCursorTextView`) each override `resetCursorRects()` or add a tracking area. All existing button creation sites are updated to use `CursorButton` instead of `NSButton`. No visual or behavioral changes.

**Tech Stack:** Swift, AppKit (`NSButton`, `NSSplitView`, `NSTextView`, `NSCursor`, `NSTrackingArea`)

---

## File Map

| Action | File | What changes |
|--------|------|--------------|
| Create | `Sources/LiteMail/GUI/CursorButton.swift` | New NSButton subclass |
| Create | `Sources/LiteMail/GUI/CursorSplitView.swift` | New NSSplitView subclass |
| Create | `Sources/LiteMail/GUI/LinkCursorTextView.swift` | New NSTextView subclass |
| Modify | `Sources/LiteMail/GUI/MainWindowController.swift` | 1 line: NSSplitView() → CursorSplitView() |
| Modify | `Sources/LiteMail/GUI/DetailView.swift` | 5 NSButton(...) → CursorButton(...), bodyTextView init → LinkCursorTextView() |
| Modify | `Sources/LiteMail/GUI/SidebarView.swift` | 2 NSButton(...) → CursorButton(...) |
| Modify | `Sources/LiteMail/GUI/ComposerWindow.swift` | 5 NSButton(...) → CursorButton(...) |
| Modify | `Sources/LiteMail/GUI/SettingsWindow.swift` | 4 NSButton(...) → CursorButton(...) |
| Modify | `Sources/LiteMail/GUI/AddAccountSheet.swift` | 2 NSButton(...) → CursorButton(...) |

---

## Task 1: Create `CursorButton`

**Files:**
- Create: `Sources/LiteMail/GUI/CursorButton.swift`

Note: AppKit cursor behavior requires a running window to verify; automated unit tests are not applicable here. Verification is a manual build + run step at the end.

- [ ] **Step 1: Create the file**

```swift
import AppKit

/// NSButton subclass that shows a pointing-hand cursor on hover.
final class CursorButton: NSButton {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/LiteMail/GUI/CursorButton.swift
git commit -m "feat: add CursorButton subclass for pointing-hand cursor"
```

---

## Task 2: Create `CursorSplitView`

**Files:**
- Create: `Sources/LiteMail/GUI/CursorSplitView.swift`

- [ ] **Step 1: Create the file**

```swift
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
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/LiteMail/GUI/CursorSplitView.swift
git commit -m "feat: add CursorSplitView subclass for resize cursor on dividers"
```

---

## Task 3: Create `LinkCursorTextView`

**Files:**
- Create: `Sources/LiteMail/GUI/LinkCursorTextView.swift`

`NSTextView` with `isEditable = false` does not show a pointing hand over links automatically. This subclass adds a `.cursorUpdate` tracking area and checks the character attributes at the mouse position.

- [ ] **Step 1: Create the file**

```swift
import AppKit

/// NSTextView subclass that shows a pointing-hand cursor when hovering over links.
///
/// AppKit's automatic link cursor only activates when isEditable = true.
/// This subclass adds a cursorUpdate tracking area and checks the .link
/// attribute at the mouse position to set the cursor manually.
final class LinkCursorTextView: NSTextView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Remove any previously added tracking areas owned by self
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
```

- [ ] **Step 2: Build to confirm it compiles**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/LiteMail/GUI/LinkCursorTextView.swift
git commit -m "feat: add LinkCursorTextView for pointing-hand cursor over email links"
```

---

## Task 4: Wire `CursorSplitView` in `MainWindowController`

**Files:**
- Modify: `Sources/LiteMail/GUI/MainWindowController.swift`

- [ ] **Step 1: Find the NSSplitView instantiation**

Open `Sources/LiteMail/GUI/MainWindowController.swift`. Look for this line (around line 40):
```swift
splitView = NSSplitView()
```

- [ ] **Step 2: Replace with CursorSplitView**

Change:
```swift
splitView = NSSplitView()
```
To:
```swift
splitView = CursorSplitView()
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/LiteMail/GUI/MainWindowController.swift
git commit -m "feat: use CursorSplitView so dividers show resize cursor"
```

---

## Task 5: Update `DetailView` buttons and body text view

**Files:**
- Modify: `Sources/LiteMail/GUI/DetailView.swift`

- [ ] **Step 1: Replace the 5 NSButton initialisers**

In `DetailView.swift` around lines 68–81, change each `NSButton(image:...)` to `CursorButton(image:...)`:

```swift
replyButton = CursorButton(image: NSImage(systemSymbolName: "arrowshape.turn.up.left.fill", accessibilityDescription: "Reply")!, target: nil, action: nil)
forwardButton = CursorButton(image: NSImage(systemSymbolName: "arrowshape.turn.up.right.fill", accessibilityDescription: "Forward")!, target: nil, action: nil)
archiveButton = CursorButton(image: NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: "Archive")!, target: nil, action: nil)
deleteButton = CursorButton(image: NSImage(systemSymbolName: "trash.fill", accessibilityDescription: "Delete")!, target: nil, action: nil)
```

And on line 81:
```swift
viewSourceButton = CursorButton(image: NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "View Source")!, target: nil, action: nil)
```

- [ ] **Step 2: Replace `NSTextView()` with `LinkCursorTextView()`**

Line 92 currently reads:
```swift
bodyTextView = NSTextView()
```

Change to:
```swift
bodyTextView = LinkCursorTextView()
```

The property declaration at line 30 is typed as `NSTextView` — since `LinkCursorTextView` is a subclass, no type annotation change is needed.

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/LiteMail/GUI/DetailView.swift
git commit -m "feat: use CursorButton and LinkCursorTextView in DetailView"
```

---

## Task 6: Update `SidebarView` buttons

**Files:**
- Modify: `Sources/LiteMail/GUI/SidebarView.swift`

- [ ] **Step 1: Replace the 2 button initialisers**

Lines 53–66. Change:
```swift
composeButton = NSButton(
    image: NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Compose")!,
    target: nil, action: nil
)
```
To:
```swift
composeButton = CursorButton(
    image: NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Compose")!,
    target: nil, action: nil
)
```

And:
```swift
refreshButton = NSButton(
    image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!,
    target: nil, action: nil
)
```
To:
```swift
refreshButton = CursorButton(
    image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!,
    target: nil, action: nil
)
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/LiteMail/GUI/SidebarView.swift
git commit -m "feat: use CursorButton in SidebarView"
```

---

## Task 7: Update `ComposerWindow` buttons

**Files:**
- Modify: `Sources/LiteMail/GUI/ComposerWindow.swift`

- [ ] **Step 1: Replace the 5 button initialisers**

Line 69: `sendButton = NSButton(title: "Send", ...)` → `sendButton = CursorButton(title: "Send", ...)`

Line 142: `let boldBtn = NSButton(title: "B", ...)` → `let boldBtn = CursorButton(title: "B", ...)`

Line 145: `let italicBtn = NSButton(title: "I", ...)` → `let italicBtn = CursorButton(title: "I", ...)`

Line 148: `let underlineBtn = NSButton(title: "U", ...)` → `let underlineBtn = CursorButton(title: "U", ...)`

Line 150: `let linkBtn = NSButton(image: NSImage(systemSymbolName: "link", ...), ...)` → `let linkBtn = CursorButton(image: NSImage(systemSymbolName: "link", ...), ...)`

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/LiteMail/GUI/ComposerWindow.swift
git commit -m "feat: use CursorButton in ComposerWindow"
```

---

## Task 8: Update `SettingsWindow` and `AddAccountSheet` buttons

**Files:**
- Modify: `Sources/LiteMail/GUI/SettingsWindow.swift`
- Modify: `Sources/LiteMail/GUI/AddAccountSheet.swift`

- [ ] **Step 1: Update SettingsWindow (4 buttons)**

Lines 62, 65, 76, 89. Change each `NSButton(title:` to `CursorButton(title:`:

```swift
let addButton = CursorButton(title: "Add Account...", target: self, action: #selector(addClicked))
let removeButton = CursorButton(title: "Remove", target: self, action: #selector(removeClicked))
let syncButton = CursorButton(title: "Sync All", target: self, action: #selector(syncClicked))
let saveSigButton = CursorButton(title: "Save Signature", target: self, action: #selector(saveSignature))
```

- [ ] **Step 2: Update AddAccountSheet (2 buttons)**

Lines 55, 59. Change each `NSButton(title:` to `CursorButton(title:`:

```swift
addButton = CursorButton(title: "Add Account", target: nil, action: nil)
cancelButton = CursorButton(title: "Cancel", target: nil, action: nil)
```

- [ ] **Step 3: Build**

```bash
swift build 2>&1 | tail -5
```

Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Sources/LiteMail/GUI/SettingsWindow.swift Sources/LiteMail/GUI/AddAccountSheet.swift
git commit -m "feat: use CursorButton in SettingsWindow and AddAccountSheet"
```

---

## Task 9: Manual Verification

- [ ] **Step 1: Run the app**

```bash
swift run LiteMail
```

- [ ] **Step 2: Verify cursor feedback**

Check each of the following (cursor should change away from the default arrow):

| Action | Expected cursor |
|--------|-----------------|
| Hover over Reply/Forward/Archive/Delete/ViewSource buttons | Pointing hand |
| Hover over Compose button in sidebar | Pointing hand |
| Hover over Refresh button in sidebar | Pointing hand |
| Hover over Send button in composer | Pointing hand |
| Hover over B / I / U / link buttons in composer | Pointing hand |
| Hover over Add Account / Remove / Sync / Save Signature | Pointing hand |
| Hover over email body hyperlink (plain-text email) | Pointing hand |
| Hover over divider between sidebar and message list | Left-right resize arrow |
| Hover over divider between message list and detail view | Left-right resize arrow |
| Move cursor off any of the above | Default arrow |
| Click any button | Behavior unchanged |
| Drag split view dividers | Resize still works normally |
