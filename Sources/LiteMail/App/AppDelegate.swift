import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController?
    private var accountManager: AccountManager?
    private var currentAccountId: String?
    private var currentFolder = "INBOX"
    private var settingsWindow: SettingsWindow?
    private var addAccountSheet: AddAccountSheet?
    private var composerWindow: ComposerWindow?
    private var contactsStore: ContactsStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let wc = MainWindowController()
        windowController = wc

        wc.onFolderSelected = { [weak self] accountId, folder in
            self?.currentAccountId = accountId
            self?.currentFolder = folder
            self?.loadMessages()
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
        wc.sidebarView.onAccountSwitched = { [weak self] accountId in
            self?.switchAccount(accountId)
        }
        wc.sidebarView.onCompose = { [weak self] in
            self?.openComposer(mode: .compose)
        }
        wc.sidebarView.onRefresh = { [weak self] in
            self?.syncNow()
        }

        setupMainMenu()
        wc.show()

        NotificationManager.shared.requestPermission()
        initializeAccountManager()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await accountManager?.stopAllSync() }
    }

    // MARK: - Menu Bar

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About LiteMail", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit LiteMail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Message", action: #selector(composeNewMessage), keyEquivalent: "n")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let msgMenuItem = NSMenuItem()
        let msgMenu = NSMenu(title: "Message")
        msgMenu.addItem(withTitle: "Sync Now", action: #selector(syncNow), keyEquivalent: "r")
        msgMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
        msgMenuItem.submenu = msgMenu
        mainMenu.addItem(msgMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Initialization

    private func initializeAccountManager() {
        let dbDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiteMail", isDirectory: true)
        try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("mail.sqlite").path

        do {
            let store = try MailStore(path: dbPath)
            let authManager = AuthManager()
            let manager = AccountManager(store: store, authManager: authManager)
            self.accountManager = manager
            self.contactsStore = ContactsStore(mailStore: store, authManager: authManager)

            Task {
                try await manager.loadAccounts()
                let accounts = try await manager.listAccounts()

                if accounts.isEmpty {
                    // Seed demo data for the default account
                    try await Self.seedDemoData(store: store)
                    currentAccountId = "default"
                } else {
                    currentAccountId = accounts.first(where: \.isDefault)?.id ?? accounts.first?.id
                }

                await MainActor.run {
                    self.loadSidebar()
                    self.loadMessages()
                    self.updateStatusBar()
                }
            }
        } catch {
            showError("Failed to initialize: \(error.localizedDescription)")
        }
    }

    // MARK: - Data Loading

    private func loadMessages() {
        guard let accountManager, let accountId = currentAccountId else { return }

        Task { @MainActor in
            do {
                let headers = try await accountManager.fetchHeaders(accountId: accountId, folder: currentFolder, offset: 0, limit: 200)
                windowController?.messageListView.update(messages: headers)
                updateStatusBar()
            } catch {
                showError("Failed to load messages: \(error.localizedDescription)")
            }
        }
    }

    private func loadMessageDetail(header: EmailHeader) {
        guard let accountManager else { return }

        Task { @MainActor in
            do {
                let body = try await accountManager.fetchBody(emailId: header.id)
                windowController?.detailView.display(header: header, body: body)

                // Wire detail view action buttons
                windowController?.detailView.onReply = { [weak self] in
                    self?.openComposer(mode: .reply(to: header, body: body))
                }
                windowController?.detailView.onForward = { [weak self] in
                    self?.openComposer(mode: .forward(original: header, body: body))
                }
                windowController?.detailView.onArchive = { [weak self] in
                    self?.handleAction(.archive(header.id))
                }
                windowController?.detailView.onDelete = { [weak self] in
                    self?.handleAction(.delete(header.id))
                }

                if !header.isRead {
                    try await accountManager.markRead(emailId: header.id, read: true)
                    loadMessages()
                }
            } catch {
                showError("Failed to load message: \(error.localizedDescription)")
            }
        }
    }

    private func performSearch(query: String) {
        guard let accountManager else { return }

        if query.isEmpty {
            loadMessages()
            return
        }

        Task { @MainActor in
            do {
                // Cross-account search (accountId: nil)
                let results = try await accountManager.search(query: query, accountId: nil)
                windowController?.messageListView.update(messages: results)
            } catch {
                showError("Search failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Actions

    private func handleAction(_ action: MailAction) {
        guard let accountManager else { return }

        Task { @MainActor in
            do {
                switch action {
                case .archive(let id) where id > 0:
                    try await accountManager.archive(emailId: id)
                    loadMessages()
                case .delete(let id) where id > 0:
                    try await accountManager.delete(emailId: id)
                    loadMessages()
                case .toggleStar(let id) where id > 0:
                    if let header = windowController?.messageListView.selectedHeader {
                        try await accountManager.markStarred(emailId: id, starred: !header.isStarred)
                        loadMessages()
                    }
                case .markRead(let id) where id > 0:
                    try await accountManager.markRead(emailId: id, read: true)
                    loadMessages()
                case .markUnread(let id) where id > 0:
                    try await accountManager.markRead(emailId: id, read: false)
                    loadMessages()
                case .refresh:
                    try await accountManager.syncAllAccounts()
                    loadMessages()
                case .compose:
                    openComposer(mode: .compose)
                case .reply(let id) where id > 0:
                    if let header = windowController?.messageListView.selectedHeader {
                        let body = try await accountManager.fetchBody(emailId: id)
                        openComposer(mode: .reply(to: header, body: body))
                    }
                case .forward(let id) where id > 0:
                    if let header = windowController?.messageListView.selectedHeader {
                        let body = try await accountManager.fetchBody(emailId: id)
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
            guard let self, let accountId = self.currentAccountId else { return }
            self.composerWindow = nil  // Release after send
            Task {
                try? await self.accountManager?.send(message: message, fromAccountId: accountId)
            }
        }
        self.composerWindow = composer  // Retain reference
        composer.show()
    }

    // MARK: - Menu Actions

    @objc private func composeNewMessage() { openComposer(mode: .compose) }

    @objc private func syncNow() {
        Task { @MainActor in
            try? await accountManager?.syncAllAccounts()
            loadMessages()
        }
    }

    @objc private func openSettings() {
        Task { @MainActor in
            guard let accountManager else { return }
            let accounts = try await accountManager.listAccounts()
            let count = (try? await accountManager.store.emailCount()) ?? 0
            let settings = SettingsWindow(accounts: accounts, emailCount: count)
            settings.onAddAccount = { [weak self] in
                self?.showAddAccount()
            }
            settings.onRemoveAccount = { [weak self] accountId in
                Task {
                    try? await self?.accountManager?.removeAccount(id: accountId)
                    await MainActor.run { self?.loadSidebar() }
                }
            }
            settings.onSyncNow = { [weak self] in
                self?.syncNow()
            }
            self.settingsWindow = settings  // Retain reference
            settings.show()
        }
    }

    private func showAddAccount() {
        guard let window = windowController?.window else { return }
        let sheet = AddAccountSheet()
        if let accountManager {
            sheet.oauthFlow = GmailOAuthFlow(authManager: accountManager.authManager)
        }
        sheet.onAddAccount = { [weak self] config, password, completion in
            guard let self, let accountManager = self.accountManager else {
                completion("App not initialized")
                return
            }

            Task {
                do {
                    // Step 1: Store credentials before connecting
                    if let password {
                        accountManager.authManager.storePassword(accountId: config.id, password: password)
                    }

                    // Step 2: Add account to DB + create provider
                    try await accountManager.addAccount(config)

                    // Step 3: Try to connect with 15-second timeout
                    guard let provider = await accountManager.getProvider(for: config.id) else {
                        throw AddAccountError.providerNotCreated
                    }

                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await provider.connect() }
                        group.addTask {
                            try await Task.sleep(for: .seconds(15))
                            throw AddAccountError.connectionTimeout
                        }
                        // First to finish wins. If timeout fires first, connect is cancelled.
                        try await group.next()
                        group.cancelAll()
                    }

                    // Step 4: Connection succeeded — run initial sync (30s timeout, non-blocking on failure)
                    Task {
                        try? await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask { try await provider.performInitialSync() }
                            group.addTask {
                                try await Task.sleep(for: .seconds(30))
                                throw AddAccountError.syncTimeout
                            }
                            try await group.next()
                            group.cancelAll()
                        }
                        await MainActor.run {
                            self.loadSidebar()
                            self.loadMessages()
                            self.updateStatusBar()
                        }
                    }

                    // Fire-and-forget contacts fetch for OAuth accounts (Gmail)
                    if config.authType == .oauth2, let contactsStore = self.contactsStore {
                        Task { await contactsStore.fetchAndStore(accountId: config.id) }
                    }

                    await MainActor.run {
                        completion(nil) // Must call before releasing sheet
                        self.loadSidebar()
                        self.loadMessages()
                        self.addAccountSheet = nil // Release after sheet dismisses
                    }
                } catch {
                    // Connection failed — remove the account we just added
                    try? await accountManager.removeAccount(id: config.id)

                    let errorMsg = Self.friendlyError(error)
                    await MainActor.run {
                        completion(errorMsg)
                    }
                }
            }
        }
        self.addAccountSheet = sheet
        sheet.show(relativeTo: window)
    }

    private enum AddAccountError: Error, LocalizedError {
        case providerNotCreated
        case connectionTimeout
        case syncTimeout
        var errorDescription: String? {
            switch self {
            case .providerNotCreated: "Failed to create mail provider."
            case .connectionTimeout: "Connection timed out after 15 seconds."
            case .syncTimeout: "Sync timed out."
            }
        }
    }

    private static func friendlyError(_ error: Error) -> String {
        let msg = error.localizedDescription
        if msg.contains("SSL") || msg.contains("TLS") || msg.contains("handshake") {
            return "Connection failed: SSL/TLS error. Check host and port."
        }
        if msg.contains("auth") || msg.contains("Auth") || msg.contains("login") || msg.contains("Login") {
            return "Authentication failed. Check your email and password."
        }
        if msg.contains("resolve") || msg.contains("host") || msg.contains("DNS") {
            return "Server not found. Check the hostname."
        }
        if msg.contains("timeout") || msg.contains("Timeout") {
            return "Connection timed out. Server may be unreachable."
        }
        if msg.contains("refused") || msg.contains("Refused") {
            return "Connection refused. Check host and port."
        }
        return "Connection failed: \(msg)"
    }

    private func loadSidebar() {
        guard let accountManager else { return }
        Task { @MainActor in
            let accounts = try await accountManager.listAccounts()

            // Set account list in dropdown
            let accountList = accounts.map { (id: $0.id, email: $0.emailAddress) }
            windowController?.sidebarView.setAccounts(accountList, activeId: currentAccountId)

            // Load folders for the active account
            loadFoldersForCurrentAccount()
        }
    }

    private func loadFoldersForCurrentAccount() {
        guard let accountManager, let accountId = currentAccountId else { return }
        Task { @MainActor in
            let folders = try await accountManager.listFolders(accountId: accountId)
            let displayFolders = folders.isEmpty ? Self.defaultFolders() : folders
            windowController?.sidebarView.updateFolders(displayFolders)
        }
    }

    private func switchAccount(_ accountId: String) {
        currentAccountId = accountId
        currentFolder = "INBOX"
        loadFoldersForCurrentAccount()
        loadMessages()
    }

    private static func defaultFolders() -> [MailFolder] {
        [
            MailFolder(id: "INBOX", name: "Inbox", unreadCount: 0),
            MailFolder(id: "[Gmail]/Starred", name: "Starred", unreadCount: 0),
            MailFolder(id: "[Gmail]/Sent Mail", name: "Sent", unreadCount: 0),
            MailFolder(id: "[Gmail]/Drafts", name: "Drafts", unreadCount: 0),
            MailFolder(id: "[Gmail]/Trash", name: "Trash", unreadCount: 0),
        ]
    }

    // MARK: - Status Bar

    private func updateStatusBar() {
        guard let accountManager else { return }
        Task { @MainActor in
            let count = (try? await accountManager.store.emailCount()) ?? 0
            windowController?.statusBar.updateEmailCount(count)
            windowController?.statusBar.updateMemory()
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Demo Data

    private static func seedDemoData(store: MailStore) async throws {
        // Insert a default account record
        let defaultAccount = AccountRecord(
            id: "default",
            emailAddress: "demo@litemail.local",
            displayName: "Demo Account",
            protocolType: "imap",
            imapHost: nil,
            imapPort: nil,
            smtpHost: nil,
            smtpPort: nil,
            jmapUrl: nil,
            authType: "password",
            keychainRef: "default",
            isDefault: true,
            createdAt: Int(Date().timeIntervalSince1970)
        )
        try await store.insertAccount(defaultAccount)

        let now = Int(Date().timeIntervalSince1970)
        let emails: [(String, String, String, String, Int, Bool, Bool)] = [
            ("Alex Chen", "alex@company.com", "Re: API migration timeline",
             "I've updated the RFC with the new endpoints. Can you review the breaking changes in section 3?\n\nKey changes:\n• /api/v2/users now returns paginated results\n• OAuth scopes are more granular\n• Rate limiting moved from 100/min to 60/min with burst support",
             5, false, false),
            ("GitHub", "notifications@github.com", "[litemail] New issue: OAuth refresh token",
             "A new issue has been opened by @user:\n\nThe refresh token flow fails silently when the access token expires during an active IMAP IDLE session.",
             42, false, false),
            ("Sarah Kim", "sarah@design.co", "Design review notes",
             "Great progress on the mockups! A few thoughts:\n\n1. Sidebar spacing feels tight at 180px\n2. The unread dot color should match the accent color\n3. Love the status bar idea\n4. Command palette animation could be snappier",
             120, false, true),
            ("Stripe", "receipts@stripe.com", "Your March invoice",
             "Your invoice for March 2026 is ready.\n\nTotal: $49.00\nPlan: Pro\nPeriod: Mar 1 - Mar 31, 2026",
             180, true, false),
            ("David Park", "david@startup.io", "Re: Weekend plans",
             "Sounds good! Let's do the hike on Saturday morning. I'll bring the coffee.",
             300, true, false),
            ("Linear", "notifications@linear.app", "Weekly digest: 12 issues completed",
             "Here's your team's weekly progress:\n\n12 completed, 3 in review, 8 in progress",
             420, true, false),
            ("AWS", "no-reply@amazonaws.com", "Your bill for February 2026",
             "Your AWS bill for Feb 1 - Feb 28, 2026 is now available.\nTotal charges: $127.43",
             600, true, false),
            ("Mom", "mom@family.com", "Call me when you're free",
             "Hi sweetie! Haven't heard from you in a while. Dad and I are doing well. Call us when you get a chance.\n\nLove, Mom",
             900, false, false),
            ("Hacker News", "hn@ycombinator.com", "Your post hit the front page",
             "Congratulations! Your submission 'Show HN: LiteMail' has reached the front page.\n\n342 points, 127 comments, #3 position",
             1200, false, true),
            ("Security Alert", "security@google.com", "New sign-in to your Google Account",
             "A new sign-in was detected on your Google Account.\n\nDevice: MacBook Pro\nLocation: San Francisco, CA",
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
                hasAttachments: false,
                accountId: "default"
            )
            let id = try await store.insertEmail(record)
            try await store.insertBody(emailId: id, text: email.3, html: nil)
        }
    }
}
