# UI Review System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automated UI review system — app captures screenshots of every screen and email via `--ui-review` flag, Claude Code skill orchestrates build→capture→analyze→fix loop.

**Architecture:** Two components: (1) `UIReviewRunner` in app that creates the window, iterates emails from DB, waits for WKWebView render, captures via `NSView.bitmapImageRepForCachingDisplay()`, outputs PNGs + manifest.json. (2) Global Claude Code skill `~/.claude/commands/ui-review.md` that drives the loop.

**Tech Stack:** Swift, AppKit, WKWebView, GRDB, NSImage/PNG export

**Spec:** `docs/superpowers/specs/2026-04-02-ui-review-system-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/LiteMail/App/main.swift` | Modify | Add `--ui-review` / `--output` flag parsing before `app.run()` |
| `Sources/LiteMail/App/UIReviewRunner.swift` | Create | Orchestrates screenshot capture: init window, iterate screens + emails, capture PNGs, write manifest |
| `~/.claude/commands/ui-review.md` | Create | Claude Code skill: build → run --ui-review → read screenshots → analyze → fix → iterate |

---

### Task 1: Modify `main.swift` to parse `--ui-review` flag

**Files:**
- Modify: `Sources/LiteMail/App/main.swift`

- [ ] **Step 1: Add flag parsing to main.swift**

Replace the entire content of `Sources/LiteMail/App/main.swift` with:

```swift
import AppKit

let args = CommandLine.arguments

if args.contains("--ui-review") {
    let output: String
    if let idx = args.firstIndex(of: "--output"), idx + 1 < args.count {
        output = args[idx + 1]
    } else {
        output = "/tmp/ui-review"
    }

    let app = NSApplication.shared
    let runner = UIReviewRunner(outputDir: output)
    runner.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
```

- [ ] **Step 2: Verify it compiles (will fail — UIReviewRunner doesn't exist yet)**

Run: `cd /Users/haicao/code/others/mail_client && swift build 2>&1 | head -5`
Expected: Error mentioning `UIReviewRunner` not found. This confirms the flag parsing is wired in.

- [ ] **Step 3: Commit**

```bash
git add Sources/LiteMail/App/main.swift
git commit -m "feat: add --ui-review flag parsing to main.swift"
```

---

### Task 2: Create `UIReviewRunner` — scaffold with static screen capture

**Files:**
- Create: `Sources/LiteMail/App/UIReviewRunner.swift`

- [ ] **Step 1: Create UIReviewRunner with basic structure and static screen capture**

Create `Sources/LiteMail/App/UIReviewRunner.swift`:

```swift
import AppKit
import WebKit
import GRDB

/// Captures screenshots of all app screens and emails for automated UI review.
/// Usage: LiteMail --ui-review --output /tmp/ui-review
final class UIReviewRunner: NSObject {
    private let outputDir: String
    private var manifest: UIReviewManifest
    private var windowController: MainWindowController?

    init(outputDir: String) {
        self.outputDir = outputDir
        self.manifest = UIReviewManifest(
            app: "LiteMail",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            windowSize: .init(width: 1100, height: 700),
            screenshots: []
        )
        super.init()
    }

    func run() {
        // Create output directory
        try? FileManager.default.createDirectory(
            atPath: outputDir,
            withIntermediateDirectories: true
        )

        // Setup window (must happen on main thread with NSApp)
        let wc = MainWindowController()
        windowController = wc
        wc.window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 700), display: true)
        wc.show()

        // Give window time to layout
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        // Capture static screens
        captureStaticScreens()

        // Capture emails
        captureEmails()

        // Write manifest
        writeManifest()

        print("UI Review complete. \(manifest.screenshots.count) screenshots saved to \(outputDir)")
        exit(0)
    }

    // MARK: - Static Screens

    private func captureStaticScreens() {
        // 1. Detail empty state (default state — no message selected)
        captureView(windowController!.detailView.view, filename: "01_detail_empty.png", entry: .init(
            file: "01_detail_empty.png", type: "screen", name: "Detail empty state"
        ))

        // 2. Full window view
        if let contentView = windowController?.window.contentView {
            captureView(contentView, filename: "02_full_window.png", entry: .init(
                file: "02_full_window.png", type: "screen", name: "Full window"
            ))
        }

        // 3. Composer window
        let composer = ComposerWindow(mode: .compose)
        composer.window.setFrame(NSRect(x: 0, y: 0, width: 600, height: 500), display: true)
        composer.window.orderFront(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))

        if let composerContent = composer.window.contentView {
            captureView(composerContent, filename: "03_composer.png", entry: .init(
                file: "03_composer.png", type: "screen", name: "Composer window"
            ))
        }
        composer.window.close()
    }

    // MARK: - Email Capture

    private func captureEmails() {
        // Open the database read-only
        let dbDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiteMail", isDirectory: true)
        let dbPath = dbDir.appendingPathComponent("mail.sqlite").path

        guard FileManager.default.fileExists(atPath: dbPath) else {
            print("No database found at \(dbPath). Skipping email capture.")
            return
        }

        guard let store = try? MailStore(path: dbPath) else {
            print("Failed to open database. Skipping email capture.")
            return
        }

        // Get all accounts
        guard let accounts = try? store.listAccounts(), !accounts.isEmpty else {
            print("No accounts found. Skipping email capture.")
            return
        }

        var emailIndex = 0

        for account in accounts {
            // Fetch emails for INBOX (most representative)
            guard let records = try? store.fetchHeaders(
                accountId: account.id, folder: "INBOX", offset: 0, limit: 50
            ) else { continue }

            for record in records {
                let header = Self.recordToHeader(record, accountId: account.id)
                let bodyTuple = try? store.fetchBody(emailId: record.id ?? 0)
                let body: EmailBody? = bodyTuple.map {
                    EmailBody(emailId: record.id ?? 0, textBody: $0.text, htmlBody: $0.html)
                }

                // Display in detail view
                windowController!.detailView.display(header: header, body: body)

                // Wait for render — WKWebView needs event loop time
                let hasHTML = body?.htmlBody != nil && !body!.htmlBody!.isEmpty
                let waitTime: TimeInterval = hasHTML ? 2.0 : 0.3
                RunLoop.current.run(until: Date(timeIntervalSinceNow: waitTime))

                // Capture
                let sanitizedSubject = Self.sanitizeFilename(header.subject ?? "no_subject")
                let filename = String(format: "email_%03d_%@.png", emailIndex, sanitizedSubject)

                captureView(windowController!.detailView.view, filename: filename, entry: .init(
                    file: filename,
                    type: "email",
                    name: header.subject ?? "(no subject)",
                    emailId: record.id,
                    subject: header.subject,
                    sender: header.senderEmail,
                    hasHTML: hasHTML,
                    hasAttachments: header.hasAttachments
                ))

                emailIndex += 1
            }
        }
    }

    // MARK: - Helpers

    private func captureView(_ view: NSView, filename: String, entry: ScreenshotEntry) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("Failed to capture \(filename)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)

        guard let tiffData = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffData),
              let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            print("Failed to convert \(filename) to PNG")
            return
        }

        let filePath = (outputDir as NSString).appendingPathComponent(filename)
        try? pngData.write(to: URL(fileURLWithPath: filePath))
        manifest.screenshots.append(entry)
    }

    private func writeManifest() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return }
        let path = (outputDir as NSString).appendingPathComponent("manifest.json")
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private static func sanitizeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-_"))
        return String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.prefix(40))
    }

    private static func recordToHeader(_ r: EmailRecord, accountId: String) -> EmailHeader {
        EmailHeader(
            id: r.id ?? 0,
            accountId: r.accountId ?? accountId,
            messageId: r.messageId,
            threadId: r.threadId,
            folder: r.folder,
            senderName: r.senderName,
            senderEmail: r.senderEmail,
            subject: r.subject,
            date: Date(timeIntervalSince1970: TimeInterval(r.date)),
            isRead: r.isRead,
            isStarred: r.isStarred,
            hasAttachments: r.hasAttachments,
            snippet: nil
        )
    }
}

// MARK: - Manifest Types

struct UIReviewManifest: Codable {
    let app: String
    let timestamp: String
    let windowSize: WindowSize
    var screenshots: [ScreenshotEntry]

    struct WindowSize: Codable {
        let width: Int
        let height: Int
    }
}

struct ScreenshotEntry: Codable {
    let file: String
    let type: String      // "screen" or "email"
    let name: String
    var emailId: Int64?
    var subject: String?
    var sender: String?
    var hasHTML: Bool?
    var hasAttachments: Bool?
}
```

- [ ] **Step 2: Build and verify compilation**

Run: `cd /Users/haicao/code/others/mail_client && swift build 2>&1 | tail -3`
Expected: Build succeeds (or minor fixes needed for access control — some properties like `detailView.view` or `ComposerWindow(mode:)` may need to be `internal` not `private`).

- [ ] **Step 3: Fix any access control issues**

If `ComposerWindow.init(mode:)` or `MainWindowController.detailView` are not accessible, change their access level from `private` to `internal` (Swift default). Check:
- `MainWindowController.detailView` — should already be `let` (internal by default) ✓
- `ComposerWindow.init(mode:)` — verify it's not private
- `MailStore.listAccounts()` and `MailStore.fetchHeaders()` — these are actor methods, need `await`. Wrap calls in `Task` or use `nonisolated` if read-only.

Since `MailStore` is an `actor`, the calls must use `await`. Update `captureEmails()` to be called from an async context:

Change `captureEmails()` call in `run()` to:

```swift
// In run(), replace the captureEmails() call with:
let semaphore = DispatchSemaphore(value: 0)
Task {
    await self.captureEmailsAsync()
    semaphore.signal()
}
semaphore.wait()
```

And rename `captureEmails()` to `captureEmailsAsync()` making it `async`. The full method becomes:

```swift
private func captureEmailsAsync() async {
    let dbDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        .appendingPathComponent("LiteMail", isDirectory: true)
    let dbPath = dbDir.appendingPathComponent("mail.sqlite").path

    guard FileManager.default.fileExists(atPath: dbPath) else {
        print("No database found at \(dbPath). Skipping email capture.")
        return
    }

    guard let store = try? MailStore(path: dbPath) else {
        print("Failed to open database. Skipping email capture.")
        return
    }

    guard let accounts = try? await store.listAccounts(), !accounts.isEmpty else {
        print("No accounts found. Skipping email capture.")
        return
    }

    var emailIndex = 0

    for account in accounts {
        guard let records = try? await store.fetchHeaders(
            accountId: account.id, folder: "INBOX", offset: 0, limit: 50
        ) else { continue }

        for record in records {
            let header = Self.recordToHeader(record, accountId: account.id)
            let bodyTuple = try? await store.fetchBody(emailId: record.id ?? 0)
            let body: EmailBody? = bodyTuple.map {
                EmailBody(emailId: record.id ?? 0, textBody: $0.text, htmlBody: $0.html)
            }

            windowController!.detailView.display(header: header, body: body)

            let hasHTML = body?.htmlBody != nil && !body!.htmlBody!.isEmpty
            let waitTime: TimeInterval = hasHTML ? 2.0 : 0.3
            RunLoop.current.run(until: Date(timeIntervalSinceNow: waitTime))

            let sanitizedSubject = Self.sanitizeFilename(header.subject ?? "no_subject")
            let filename = String(format: "email_%03d_%@.png", emailIndex, sanitizedSubject)

            captureView(windowController!.detailView.view, filename: filename, entry: .init(
                file: filename,
                type: "email",
                name: header.subject ?? "(no subject)",
                emailId: record.id,
                subject: header.subject,
                sender: header.senderEmail,
                hasHTML: hasHTML,
                hasAttachments: header.hasAttachments
            ))

            emailIndex += 1
        }
    }
}
```

- [ ] **Step 4: Build and verify**

Run: `cd /Users/haicao/code/others/mail_client && swift build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Test the --ui-review flag**

Run: `cd /Users/haicao/code/others/mail_client && .build/debug/LiteMail --ui-review --output /tmp/ui-review-test 2>&1`
Expected: App launches briefly, captures screenshots, prints summary, exits.
Then verify: `ls /tmp/ui-review-test/` should show PNG files and `manifest.json`.

- [ ] **Step 6: Verify manifest.json is valid**

Run: `cat /tmp/ui-review-test/manifest.json | python3 -m json.tool | head -20`
Expected: Pretty-printed JSON with app name, timestamp, and screenshots array.

- [ ] **Step 7: Commit**

```bash
git add Sources/LiteMail/App/UIReviewRunner.swift
git commit -m "feat: add UIReviewRunner for automated screenshot capture"
```

---

### Task 3: Handle WKWebView async rendering properly

**Files:**
- Modify: `Sources/LiteMail/App/UIReviewRunner.swift`

WKWebView renders HTML asynchronously. Using `RunLoop.current.run(until:)` with a fixed 2-second delay is unreliable — some emails render faster, some slower. We need to detect when rendering is complete.

- [ ] **Step 1: Add WKNavigationDelegate conformance**

Add to `UIReviewRunner.swift`, after the existing class definition:

```swift
extension UIReviewRunner: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webViewFinishedLoading = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        print("WebView failed to load: \(error.localizedDescription)")
        webViewFinishedLoading = true  // Continue anyway
    }
}
```

Add a property to the class:

```swift
private var webViewFinishedLoading = false
```

- [ ] **Step 2: Update email capture to use delegate-based waiting**

Replace the fixed `RunLoop` wait in `captureEmailsAsync()` with:

```swift
// After calling detailView.display(header:body:)
if hasHTML {
    // Set ourselves as navigation delegate on the detail view's webView
    webViewFinishedLoading = false
    if let wv = windowController?.detailView.webView {
        wv.navigationDelegate = self
    }

    // Wait for didFinish or timeout (5 seconds)
    let deadline = Date(timeIntervalSinceNow: 5.0)
    while !webViewFinishedLoading && Date() < deadline {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
    }

    // Extra 0.3s for final paint
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
} else {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
}
```

Note: `DetailView.webView` is currently `private`. Change it to `private(set) var webView: WKWebView?` to allow read access from UIReviewRunner.

- [ ] **Step 3: Build and test with HTML email**

Run: `cd /Users/haicao/code/others/mail_client && swift build && .build/debug/LiteMail --ui-review --output /tmp/ui-review-test2 2>&1`
Expected: Screenshots include properly rendered HTML emails (not blank white).

- [ ] **Step 4: Verify HTML email screenshots are not blank**

Open a few email screenshots: `open /tmp/ui-review-test2/email_000_*.png`
Expected: Email content is visible, not blank or half-rendered.

- [ ] **Step 5: Commit**

```bash
git add Sources/LiteMail/App/UIReviewRunner.swift Sources/LiteMail/GUI/DetailView.swift
git commit -m "feat: proper WKWebView render-wait with navigation delegate"
```

---

### Task 4: Create the Claude Code `/ui-review` skill

**Files:**
- Create: `~/.claude/commands/ui-review.md`

- [ ] **Step 1: Create the skill file**

Create `~/.claude/commands/ui-review.md`:

```markdown
---
description: "Automated UI review: build app, capture screenshots, analyze visual quality, fix issues, iterate"
---

# UI Review Skill

You are performing an automated UI review. Follow this loop exactly.

## Arguments

$ARGUMENTS contains the max number of iterations (default: 3 if empty).

## Setup

1. Detect the build system:
   - If `Package.swift` exists: build command is `swift build`, binary is `.build/debug/<executable name from Package.swift>`
   - If `*.xcodeproj` exists: build command is `xcodebuild -scheme <scheme> -configuration Debug build`, binary is from derived data
   - If `Makefile` exists: build command is `make`

2. Set output directory: `/tmp/ui-review`

3. Check for reference images in `docs/ui-reference/`. If they exist, read them — they define the target visual style.

## Loop (repeat up to $ARGUMENTS times, default 3)

### Step 1: Build
Run the build command. If it fails, fix the build error and retry.

### Step 2: Capture
Run: `<binary> --ui-review --output /tmp/ui-review`
This captures screenshots of all screens and emails.

### Step 3: Read manifest
Read `/tmp/ui-review/manifest.json` to get the list of screenshots.

### Step 4: Analyze screenshots
Read each screenshot PNG using the Read tool. For each one, evaluate against these design rules:

**Layout & Spacing**
- Consistent spacing (8px grid)
- Proper padding inside containers (min 8px, typical 12-16px)
- No overlapping or clipped elements
- No truncated text that shouldn't be truncated
- Aligned elements in same row

**Typography**
- Clear hierarchy: title > subtitle > body > caption
- Appropriate line height
- Consistent font family (system font)

**Color & Contrast**
- Text contrast ratio >= 4.5:1 (WCAG AA)
- Interactive elements visually distinct
- Consistent accent color usage
- Dark mode: no pure white on pure black

**Email Rendering**
- HTML emails: proper content display, no white flash
- Images render or show placeholder
- No unwanted horizontal scroll
- Plain text emails: proper wrapping

**Consistency**
- Same element types look the same across screens
- Uniform spacing between list items
- Consistent button styles

If reference images exist in `docs/ui-reference/`, also compare:
- Color palette similarity
- Spacing patterns
- Typography scale
- Overall visual polish level

### Step 5: Report
List all issues found with severity:
- **Critical**: broken rendering, unreadable text, major layout break
- **Minor**: spacing inconsistency, slight alignment issue, color tweaks

### Step 6: Fix
Edit the relevant Swift/AppKit code to fix issues, starting with critical ones.
After editing, go back to Step 1.

## Stopping

Stop the loop when:
- No more issues found
- Max iterations reached
- Only trivial issues remain that aren't worth another iteration

## Final report

After the loop ends, summarize:
- Total issues found and fixed
- Remaining known issues (if any)
- Before/after comparison (describe improvements)
```

- [ ] **Step 2: Verify the skill is discoverable**

Run: `ls ~/.claude/commands/ui-review.md`
Expected: File exists.

- [ ] **Step 3: Commit (in the project repo — the skill file is outside the repo, so just commit any remaining app changes)**

```bash
cd /Users/haicao/code/others/mail_client
git add -A
git commit -m "feat: complete ui-review system — app mode + claude code skill"
```

---

### Task 5: End-to-end verification

**Files:** None (verification only)

- [ ] **Step 1: Clean build**

Run: `cd /Users/haicao/code/others/mail_client && swift build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED

- [ ] **Step 2: Run --ui-review and verify full output**

Run:
```bash
rm -rf /tmp/ui-review
.build/debug/LiteMail --ui-review --output /tmp/ui-review
echo "---"
cat /tmp/ui-review/manifest.json | python3 -m json.tool
echo "---"
ls -la /tmp/ui-review/*.png | wc -l
```

Expected:
- manifest.json is valid JSON with screenshots array
- PNG files exist for static screens + emails (count depends on DB contents)
- App exited cleanly

- [ ] **Step 3: Verify screenshots are readable images**

Run: `open /tmp/ui-review/01_detail_empty.png /tmp/ui-review/02_full_window.png`
Expected: Images open in Preview, showing actual rendered UI content.

- [ ] **Step 4: Test normal app launch still works**

Run: `.build/debug/LiteMail &` then after 3 seconds `kill %1`
Expected: App launches normally (no --ui-review behavior).

- [ ] **Step 5: Test the skill invocation**

In a new Claude Code session, run `/ui-review` and verify it:
1. Builds the app
2. Runs --ui-review
3. Reads screenshots
4. Provides analysis

- [ ] **Step 6: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: end-to-end verification fixes for ui-review system"
```
