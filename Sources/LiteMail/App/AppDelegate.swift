import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var engine: MailEngine?
    private var currentFolder = "INBOX"
    private var syncTimer: Timer?
    private var backfillTask: Task<Void, Never>?

    // TODO: Replace with real OAuth credentials
    private let clientId = "YOUR_CLIENT_ID.apps.googleusercontent.com"
    private let redirectURI = URL(string: "com.litemail:/oauth2callback")!
    private let userEmail = "user@gmail.com"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let wc = MainWindowController()
        windowController = wc

        // Wire up GUI callbacks
        wc.onFolderSelected = { [weak self] folder in
            self?.currentFolder = folder
            self?.loadMessages(folder: folder)
        }
        wc.onMessageSelected = { [weak self] header in
            self?.loadMessageDetail(header: header)
        }
        wc.onAction = { [weak self] action in
            self?.handleAction(action)
        }
        wc.messageListView.onSearchChanged = { [weak self] query in
            self?.performSearch(query: query)
        }

        // Build menu bar
        setupMainMenu()

        wc.show()

        // Request notification permission
        NotificationManager.shared.requestPermission()

        // Initialize engine
        initializeEngine()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        syncTimer?.invalidate()
        backfillTask?.cancel()
    }

    // MARK: - Menu Bar

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About LiteMail", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit LiteMail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Message", action: #selector(composeNewMessage), keyEquivalent: "n")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu (for search field)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Message menu
        let msgMenuItem = NSMenuItem()
        let msgMenu = NSMenu(title: "Message")
        msgMenu.addItem(withTitle: "Reply", action: #selector(replyToMessage), keyEquivalent: "r")
        msgMenu.addItem(withTitle: "Forward", action: #selector(forwardMessage), keyEquivalent: "f")
        msgMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        msgMenu.addItem(.separator())
        msgMenu.addItem(withTitle: "Archive", action: #selector(archiveMessage), keyEquivalent: "e")
        msgMenu.items.last?.keyEquivalentModifierMask = []
        msgMenu.addItem(withTitle: "Delete", action: #selector(deleteMessage), keyEquivalent: "\u{08}")
        msgMenu.addItem(.separator())
        msgMenu.addItem(withTitle: "Sync Now", action: #selector(syncNow), keyEquivalent: "r")
        msgMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        msgMenuItem.submenu = msgMenu
        mainMenu.addItem(msgMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Engine Initialization

    private func initializeEngine() {
        let dbDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiteMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("mail.sqlite").path

        do {
            engine = try MailEngine(
                dbPath: dbPath,
                clientId: clientId,
                redirectURI: redirectURI,
                userEmail: userEmail
            )

            // Seed demo data if the store is empty
            Task {
                let count = try await engine!.store.emailCount()
                if count == 0 {
                    try await Self.seedDemoData(store: engine!.store)
                }
                await MainActor.run {
                    self.loadMessages(folder: "INBOX")
                    self.updateStatusBar()
                }
            }
        } catch {
            showError("Failed to initialize: \(error.localizedDescription)")
        }
    }

    // MARK: - Data Loading

    private func loadMessages(folder: String) {
        guard let engine else { return }

        Task { @MainActor in
            do {
                let headers = try await engine.fetchHeaders(folder: folder, offset: 0, limit: 200)
                windowController?.messageListView.update(messages: headers)
                updateStatusBar()
            } catch {
                showError("Failed to load messages: \(error.localizedDescription)")
            }
        }
    }

    private func loadMessageDetail(header: EmailHeader) {
        guard let engine else { return }

        Task { @MainActor in
            do {
                let body = try await engine.fetchBody(emailId: header.id)
                windowController?.detailView.display(header: header, body: body)

                if !header.isRead {
                    try await engine.markRead(emailId: header.id, read: true)
                }
            } catch {
                showError("Failed to load message: \(error.localizedDescription)")
            }
        }
    }

    private func performSearch(query: String) {
        guard let engine else { return }

        if query.isEmpty {
            loadMessages(folder: currentFolder)
            return
        }

        Task { @MainActor in
            do {
                let results = try await engine.search(query: query)
                windowController?.messageListView.update(messages: results)
            } catch {
                showError("Search failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Periodic Sync & Backfill

    private func startPeriodicSync() {
        // Incremental sync every 5 minutes
        syncTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.performIncrementalSync()
        }
    }

    private func performIncrementalSync() {
        guard let engine else { return }

        Task { @MainActor in
            windowController?.statusBar.updateConnection(status: .syncing)
            do {
                try await engine.performIncrementalSync()
                windowController?.statusBar.updateConnection(status: .connected)
                loadMessages(folder: currentFolder)
                updateStatusBar()
            } catch {
                windowController?.statusBar.updateConnection(status: .reconnecting)
            }
        }
    }

    private func startBackfill() {
        guard let engine else { return }

        backfillTask = Task {
            while !Task.isCancelled {
                do {
                    try await engine.syncEngine.performBodyBackfill(batchSize: 50)
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    try? await Task.sleep(for: .seconds(60))
                }
            }
        }
    }

    // MARK: - Actions

    private func handleAction(_ action: MailAction) {
        guard let engine else { return }

        Task { @MainActor in
            do {
                switch action {
                case .archive(let id) where id > 0:
                    try await engine.archive(emailId: id)
                    loadMessages(folder: currentFolder)
                case .delete(let id) where id > 0:
                    try await engine.delete(emailId: id)
                    loadMessages(folder: currentFolder)
                case .toggleStar(let id) where id > 0:
                    if let header = windowController?.messageListView.selectedHeader {
                        try await engine.markStarred(emailId: id, starred: !header.isStarred)
                        loadMessages(folder: currentFolder)
                    }
                case .markRead(let id) where id > 0:
                    try await engine.markRead(emailId: id, read: true)
                    loadMessages(folder: currentFolder)
                case .markUnread(let id) where id > 0:
                    try await engine.markRead(emailId: id, read: false)
                    loadMessages(folder: currentFolder)
                case .refresh:
                    performIncrementalSync()
                case .compose:
                    openComposer(mode: .compose)
                case .reply(let id) where id > 0:
                    if let header = windowController?.messageListView.selectedHeader {
                        let body = try await engine.fetchBody(emailId: id)
                        openComposer(mode: .reply(to: header, body: body))
                    }
                case .forward(let id) where id > 0:
                    if let header = windowController?.messageListView.selectedHeader {
                        let body = try await engine.fetchBody(emailId: id)
                        openComposer(mode: .forward(original: header, body: body))
                    }
                case .search(let query):
                    performSearch(query: query)
                default:
                    break
                }
            } catch {
                showError("Action failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Composer

    private func openComposer(mode: ComposerWindow.Mode) {
        let composer = ComposerWindow(mode: mode)
        composer.onSend = { [weak self] message in
            self?.sendMessage(message)
        }
        composer.onSaveDraft = { [weak self] draft in
            Task {
                try? await self?.engine?.saveDraft(draft)
            }
        }
        composer.show()
    }

    private func sendMessage(_ message: OutgoingMessage) {
        guard let engine else { return }

        Task { @MainActor in
            do {
                try await engine.send(message: message)
                windowController?.statusBar.updateSyncStatus("Message queued")
            } catch {
                showError("Failed to send: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Menu Actions

    @objc private func composeNewMessage() {
        openComposer(mode: .compose)
    }

    @objc private func replyToMessage() {
        if let header = windowController?.messageListView.selectedHeader {
            handleAction(.reply(header.id))
        }
    }

    @objc private func forwardMessage() {
        if let header = windowController?.messageListView.selectedHeader {
            handleAction(.forward(header.id))
        }
    }

    @objc private func archiveMessage() {
        if let header = windowController?.messageListView.selectedHeader {
            handleAction(.archive(header.id))
        }
    }

    @objc private func deleteMessage() {
        if let header = windowController?.messageListView.selectedHeader {
            handleAction(.delete(header.id))
        }
    }

    @objc private func syncNow() {
        performIncrementalSync()
    }

    @objc private func openSettings() {
        Task { @MainActor in
            let emailCount = (try? await engine?.store.emailCount()) ?? 0
            let settings = SettingsWindow(userEmail: userEmail, emailCount: emailCount, lastSync: Date())
            settings.onSignOut = { [weak self] in
                self?.engine?.auth.signOut()
            }
            settings.onSyncNow = { [weak self] in
                self?.performIncrementalSync()
            }
            settings.show()
        }
    }

    // MARK: - Status Bar

    private func updateStatusBar() {
        guard let engine else { return }

        Task { @MainActor in
            let count = (try? await engine.store.emailCount()) ?? 0
            windowController?.statusBar.updateEmailCount(count)
            windowController?.statusBar.updateMemory()
        }
    }

    // MARK: - Helpers

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Demo Data

    private static func seedDemoData(store: MailStore) async throws {
        let now = Int(Date().timeIntervalSince1970)
        let emails: [(String, String, String, String, Int, Bool, Bool)] = [
            // (sender, email, subject, body, minutesAgo, isRead, isStarred)
            ("Alex Chen", "alex@company.com", "Re: API migration timeline",
             "I've updated the RFC with the new endpoints. Can you review the breaking changes in section 3? The main concern is the auth token format change — existing clients will need to re-authenticate.\n\nKey changes:\n• /api/v2/users now returns paginated results by default\n• OAuth scopes are more granular (read:user vs read:user:email)\n• Rate limiting moved from 100/min to 60/min with burst support\n\nI think we should give partners 90 days notice minimum.",
             5, false, false),
            ("GitHub", "notifications@github.com", "[litemail] New issue: OAuth refresh token",
             "A new issue has been opened by @user:\n\nThe refresh token flow fails silently when the access token expires during an active IMAP IDLE session. Expected behavior: automatic re-authentication.",
             42, false, false),
            ("Sarah Kim", "sarah@design.co", "Design review notes",
             "Great progress on the mockups! A few thoughts:\n\n1. Sidebar spacing feels tight at 180px — try 200px\n2. The unread dot color should match the accent color\n3. Love the status bar idea with live RAM display\n4. Command palette animation could be snappier\n\nOverall direction is solid. Ship it.",
             120, false, true),
            ("Stripe", "receipts@stripe.com", "Your March invoice",
             "Your invoice for March 2026 is ready.\n\nTotal: $49.00\nPlan: Pro\nPeriod: Mar 1 - Mar 31, 2026\n\nView your invoice at dashboard.stripe.com",
             180, true, false),
            ("David Park", "david@startup.io", "Re: Weekend plans",
             "Sounds good! Let's do the hike on Saturday morning. I'll bring the coffee and trail mix. Meet at the trailhead at 8am?",
             300, true, false),
            ("Linear", "notifications@linear.app", "Weekly digest: 12 issues completed",
             "Here's your team's weekly progress:\n\n✅ 12 completed\n🔄 3 in review\n⏳ 8 in progress\n📋 5 backlog\n\nTop contributor: You (7 issues)\nVelocity: +15% from last week",
             420, true, false),
            ("AWS", "no-reply@amazonaws.com", "Your bill for February 2026",
             "Your AWS bill for the period of Feb 1 - Feb 28, 2026 is now available.\n\nTotal charges: $127.43\n\nTop services:\n• EC2: $45.20\n• RDS: $38.10\n• S3: $12.05\n• CloudFront: $8.92",
             600, true, false),
            ("Mom", "mom@family.com", "Call me when you're free 💕",
             "Hi sweetie! Haven't heard from you in a while. Dad and I are doing well. The garden is blooming. Call us when you get a chance, no rush.\n\nLove, Mom",
             900, false, false),
            ("Hacker News", "hn@ycombinator.com", "Your post hit the front page",
             "Congratulations! Your submission 'Show HN: LiteMail — a native macOS mail client in 20MB RAM' has reached the front page of Hacker News.\n\nCurrent stats:\n• 342 points\n• 127 comments\n• #3 position\n\nKeep building!",
             1200, false, true),
            ("Security Alert", "security@google.com", "New sign-in to your Google Account",
             "A new sign-in was detected on your Google Account.\n\nDevice: MacBook Pro\nLocation: San Francisco, CA\nTime: March 29, 2026, 10:42 PM PST\n\nIf this was you, no further action is needed.",
             1500, true, false),
        ]

        for (i, email) in emails.enumerated() {
            let record = EmailRecord(
                messageId: "<demo-\(i)@litemail.local>",
                threadId: i <= 1 ? "thread-api-migration" : "thread-\(i)",
                folder: "INBOX",
                senderName: email.0,
                senderEmail: email.1,
                subject: email.2,
                date: now - email.4 * 60,
                isRead: email.5,
                isStarred: email.6,
                isDeleted: false,
                hasAttachments: false
            )
            let id = try await store.insertEmail(record)
            try await store.insertBody(emailId: id, text: email.3, html: nil)
        }
    }
}
