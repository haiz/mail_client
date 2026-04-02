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
        do {
            try FileManager.default.createDirectory(
                atPath: outputDir,
                withIntermediateDirectories: true
            )
        } catch {
            print("Failed to create output directory: \(error)")
        }

        let wc = MainWindowController()
        windowController = wc
        wc.window.setFrame(NSRect(x: 0, y: 0, width: 1100, height: 700), display: true)
        wc.show()

        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

        captureStaticScreens()

        // Bridge sync → async for actor-based MailStore
        // NOTE: Cannot use DispatchSemaphore here — captureEmailsAsync() uses
        // MainActor.run which needs the main thread, but semaphore.wait() blocks it.
        // Instead, pump the RunLoop so MainActor work can execute while we wait.
        var finished = false
        Task {
            await self.captureEmailsAsync()
            finished = true
        }
        while !finished {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        }

        writeManifest()

        print("UI Review complete. \(manifest.screenshots.count) screenshots saved to \(outputDir)")
        exit(0)
    }

    // MARK: - Static Screens

    private func captureStaticScreens() {
        guard let wc = windowController else { return }

        captureView(wc.detailView.view, filename: "01_detail_empty.png", entry: .init(
            file: "01_detail_empty.png", type: "screen", name: "Detail empty state"
        ))

        if let contentView = wc.window.contentView {
            captureView(contentView, filename: "02_full_window.png", entry: .init(
                file: "02_full_window.png", type: "screen", name: "Full window"
            ))
        }

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

    private func captureEmailsAsync() async {
        guard let wc = windowController else { return }

        let dbDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiteMail", isDirectory: true)
        let dbPath = dbDir.appendingPathComponent("mail.sqlite").path

        guard FileManager.default.fileExists(atPath: dbPath) else {
            print("No database found at \(dbPath). Skipping email capture.")
            return
        }

        let store: MailStore
        do {
            store = try MailStore(path: dbPath)
        } catch {
            print("Failed to open database: \(error)")
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

                // Must dispatch to main thread for UI updates
                await MainActor.run {
                    wc.detailView.display(header: header, body: body)
                }

                let hasHTML = body?.htmlBody.map { !$0.isEmpty } ?? false
                let waitTime: TimeInterval = hasHTML ? 2.0 : 0.3

                // Run the run loop on main thread to allow rendering
                await MainActor.run {
                    RunLoop.current.run(until: Date(timeIntervalSinceNow: waitTime))
                }

                let sanitizedSubject = Self.sanitizeFilename(header.subject ?? "no_subject")
                let filename = String(format: "email_%03d_%@.png", emailIndex, sanitizedSubject)

                await MainActor.run {
                    captureView(wc.detailView.view, filename: filename, entry: .init(
                        file: filename,
                        type: "email",
                        name: header.subject ?? "(no subject)",
                        emailId: record.id,
                        subject: header.subject,
                        sender: header.senderEmail,
                        hasHTML: hasHTML,
                        hasAttachments: header.hasAttachments
                    ))
                }

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
        do {
            try pngData.write(to: URL(fileURLWithPath: filePath))
        } catch {
            print("Failed to write \(filename): \(error)")
        }
        manifest.screenshots.append(entry)
    }

    private func writeManifest() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return }
        let path = (outputDir as NSString).appendingPathComponent("manifest.json")
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            print("Failed to write manifest: \(error)")
        }
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
    let type: String
    let name: String
    var emailId: Int64?
    var subject: String?
    var sender: String?
    var hasHTML: Bool?
    var hasAttachments: Bool?
}
