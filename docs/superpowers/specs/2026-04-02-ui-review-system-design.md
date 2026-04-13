# UI Review System — Design Spec

## Goal

Automated UI review workflow: Claude Code builds the app, captures screenshots of every screen and email, analyzes visual quality against design rules and optional reference images, fixes issues, and iterates — fully autonomous.

Reusable across macOS AppKit projects via a shared Claude Code skill and a standard `--ui-review` convention.

## Architecture

Two components:

1. **App-side**: `--ui-review` mode built into the app
2. **Claude Code-side**: `/ui-review` skill that orchestrates the loop

```
┌──────────────────────────────────────────────────┐
│                Claude Code Skill                  │
│                                                   │
│  ┌───────┐   ┌──────────┐   ┌────────────────┐  │
│  │ Build │──▶│ Run app   │──▶│ Read manifest  │  │
│  │       │   │--ui-review│   │ + screenshots  │  │
│  └───────┘   └──────────┘   └───────┬────────┘  │
│                                      │           │
│                              ┌───────▼────────┐  │
│                              │ Analyze against │  │
│                              │ design rules +  │  │
│                              │ reference imgs  │  │
│                              └───────┬────────┘  │
│                                      │           │
│                              ┌───────▼────────┐  │
│                              │ Edit code      │  │
│                              │ (fix issues)   │  │
│                              └───────┬────────┘  │
│                                      │           │
│                                      ▼           │
│                              Loop back to Build  │
└──────────────────────────────────────────────────┘
```

---

## Part 1: App-side — `--ui-review` mode

### Entry point

In `main.swift`, detect `--ui-review` flag:

```swift
let args = CommandLine.arguments
if args.contains("--ui-review") {
    let output: String
    if let idx = args.firstIndex(of: "--output"), idx + 1 < args.count {
        output = args[idx + 1]
    } else {
        output = "/tmp/ui-review"
    }
    let app = NSApplication.shared  // required for AppKit rendering
    let runner = UIReviewRunner(outputDir: output)
    runner.run()  // runs a short event loop, captures screenshots, then calls exit(0)
} else {
    // normal app launch
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
```

### Database path

UIReviewRunner uses the same DB path as the main app (`~/Library/Application Support/LiteMail/mail.db`). It opens `MailStore` read-only to fetch emails and bodies for rendering. If the DB doesn't exist or is empty, the runner captures only static screens (empty states) and notes this in the manifest.

### UIReviewRunner

A new file: `Sources/LiteMail/App/UIReviewRunner.swift`

Responsibilities:
1. Initialize `NSApplication` (needed for AppKit rendering)
2. Create `MainWindowController` and show the window off-screen or at a fixed size
3. Capture static screens:
   - `01_inbox.png` — inbox with emails loaded from DB
   - `02_inbox_empty.png` — inbox with no emails (empty state)
   - `03_composer.png` — compose window
   - `04_detail_empty.png` — detail view with no message selected
4. Iterate through all emails in DB:
   - For each email: call `detailView.display(header:body:)` 
   - Wait for render completion (especially WKWebView: listen for `webView(_:didFinish:)` delegate callback)
   - Capture the detail view via `NSView.bitmapImageRepForCachingDisplay()`
   - Save as `email_{id}_{sanitized_subject}.png`
5. Write `manifest.json`
6. Exit app with code 0

### WKWebView render wait

HTML emails render asynchronously in WKWebView. The runner must:
- Set itself as `WKNavigationDelegate`
- After calling `display()`, wait for `webView(_:didFinish:)` callback
- Add a timeout (5 seconds) to handle emails that fail to render
- Only then capture the screenshot

### Screenshot capture

```swift
func captureView(_ view: NSView) -> NSImage? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    let image = NSImage(size: view.bounds.size)
    image.addRepresentation(rep)
    return image
}
```

### manifest.json format

```json
{
  "app": "LiteMail",
  "timestamp": "2026-04-02T10:30:00Z",
  "window_size": {"width": 1100, "height": 700},
  "screenshots": [
    {
      "file": "01_inbox.png",
      "type": "screen",
      "name": "Inbox with emails"
    },
    {
      "file": "02_inbox_empty.png",
      "type": "screen",
      "name": "Inbox empty state"
    },
    {
      "file": "03_composer.png",
      "type": "screen",
      "name": "Composer window"
    },
    {
      "file": "04_detail_empty.png",
      "type": "screen",
      "name": "Detail empty state"
    },
    {
      "file": "email_42_Welcome_to_LiteMail.png",
      "type": "email",
      "email_id": 42,
      "subject": "Welcome to LiteMail",
      "sender": "support@litemail.app",
      "has_html": true,
      "has_attachments": false
    }
  ]
}
```

---

## Part 2: Claude Code Skill — `/ui-review`

### Skill location

`~/.claude/commands/ui-review.md` (global, reusable across projects)

### Skill behavior

When invoked, the skill instructs Claude Code to:

1. **Build**: Detect build system (`Package.swift` → `swift build`, `.xcodeproj` → `xcodebuild`) and run
2. **Run**: Execute the built binary with `--ui-review --output /tmp/ui-review/` (binary name from Package.swift or xcodeproj)
3. **Read manifest**: `/tmp/ui-review/manifest.json`
4. **Read screenshots**: Use Read tool on each PNG
5. **Analyze**: Check each screenshot against design rules + reference images
6. **Report**: List issues found with severity (critical / minor)
7. **Fix**: Edit the relevant Swift/AppKit code
8. **Iterate**: Repeat from step 1
9. **Stop**: When no more issues found, or after max iterations (default 3)

### Design Rules (built into skill)

The skill contains these analysis criteria:

**Layout & Spacing**
- Consistent spacing using 8px grid
- Proper padding inside containers (min 8px, typical 12-16px)
- No overlapping elements
- No clipped/truncated text that shouldn't be truncated
- Alignment: elements in same row aligned vertically

**Typography**
- Clear hierarchy: title (16-18pt bold) > subtitle (13-14pt medium) > body (13pt regular) > caption (11pt light)
- Line height appropriate for readability
- No font mixing (stick to system font unless intentional)

**Color & Contrast**
- Text contrast ratio >= 4.5:1 against background (WCAG AA)
- Interactive elements visually distinct from static content
- Consistent use of accent color
- Dark mode: no pure white text on pure black (use slight gray)

**Email Rendering**
- HTML emails: no white flash, proper dark mode CSS injection
- Images render (or show placeholder)
- Wide content doesn't cause horizontal scroll
- Plain text emails: monospace or proportional with proper wrapping

**Consistency**
- Same element types look the same across all screens
- Spacing between list items is uniform
- Button styles consistent (same padding, font, corner radius)

### Reference Images (optional)

If `docs/ui-reference/` exists and contains images, the skill will:
- Read each reference image
- Compare visual style (colors, spacing, typography, layout patterns) against current screenshots
- Use the reference as the "target style" when suggesting fixes

### Iteration control

- Default: max 3 iterations per invocation
- User can override: `/ui-review 5` for 5 iterations
- Each iteration focuses on the highest-severity issues first
- Skill reports a summary after each iteration: what was fixed, what remains

### Convention for other projects

Any macOS app can use this skill by implementing:
1. `--ui-review --output <dir>` CLI flag
2. Output PNG screenshots + `manifest.json` in the format above
3. (Optional) Put reference screenshots in `docs/ui-reference/`

The skill detects the build system automatically:
- `Package.swift` present → `swift build`
- `.xcodeproj` present → `xcodebuild`
- `Makefile` present → `make`

---

## Files to create/modify

| File | Action | Description |
|------|--------|-------------|
| `Sources/LiteMail/App/main.swift` | Modify | Add `--ui-review` flag detection |
| `Sources/LiteMail/App/UIReviewRunner.swift` | Create | Screenshot capture + iteration logic |
| `~/.claude/commands/ui-review.md` | Create | Claude Code skill (reusable) |
| `docs/ui-reference/` | Create dir | Optional reference images folder |

## Out of scope

- iOS/SwiftUI support (AppKit only for now)
- Video recording of interactions
- Automated A/B comparison between git branches
- Performance profiling during UI review
