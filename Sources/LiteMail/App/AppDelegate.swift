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
            loadMessages(folder: "INBOX")
            updateStatusBar()
            startPeriodicSync()
            startBackfill()
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
}
