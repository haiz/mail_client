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
    private var activatedAccountIds: Set<String> = []
    private var displayedEmailId: Int64?
    private var isSyncing = false
    private var syncStartTime: Date?
    private var syncBaseEmailCount = 0
    private var syncProgressTimer: Timer?
    /// Infinite-scroll pagination state. `isLoadingMoreMessages` guards against
    /// duplicate requests from rapid scroll events; `hasMoreMessages` is set to
    /// false when the last page returned fewer rows than the requested limit.
    private var isLoadingMoreMessages = false
    private var hasMoreMessages = true
    /// True while the user has an active search query. Pagination is disabled in
    /// this mode — search results already include all matches cross-account.
    private var isSearching = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = image
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let wc = MainWindowController()
        windowController = wc

        wc.onFolderSelected = { [weak self] accountId, folder in
            self?.currentAccountId = accountId
            self?.currentFolder = folder
            self?.displayedEmailId = nil
            self?.windowController?.messageListView.currentFolderName = folder
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
        wc.messageListView.onRequestLoadMore = { [weak self] in
            self?.loadMoreMessages()
        }
        wc.messageListView.onCheckedIdsChanged = { [weak self] checkedIds in
            guard let self, let wc = self.windowController else { return }
            if checkedIds.count >= 2 {
                let headers = wc.messageListView.threadGroups
                    .filter { checkedIds.contains($0.primaryHeader.id) }
                    .map(\.primaryHeader)
                wc.detailView.showBulkSummary(headers: headers)
            } else {
                wc.detailView.hideBulkSummary()
            }
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
        wc.sidebarView.onMoveToFolder = { [weak self] emailId, folderId in
            self?.handleAction(.moveToFolder(emailId, folderId))
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
        fileMenu.addItem(withTitle: "Print...", action: #selector(printEmail), keyEquivalent: "p")
        fileMenu.addItem(withTitle: "Export as .eml...", action: #selector(exportEml), keyEquivalent: "e")
        fileMenu.items.last?.keyEquivalentModifierMask = [.command, .shift]
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
                await manager.startDeleteWorker()
                let accounts = try await manager.listAccounts()

                if accounts.isEmpty {
                    // Seed demo data for the default account
                    try await Self.seedDemoData(store: store)
                    currentAccountId = "default"
                } else {
                    let saved = UserDefaults.standard.string(forKey: "lastActiveAccountId")
                    let savedExists = saved.map { id in accounts.contains(where: { $0.id == id }) } ?? false
                    currentAccountId = savedExists ? saved : (accounts.first(where: \.isDefault)?.id ?? accounts.first?.id)
                }
                if let id = currentAccountId {
                    activatedAccountIds.insert(id)
                }

                await MainActor.run {
                    self.loadSidebar()
                    self.loadMessages()
                    self.updateStatusBar()
                    self.startPeriodicSyncLoop()
                    self.windowController?.sidebarView.onAuthErrorFix = { [weak self] (_: String) in self?.openSettings() }
                    // Surface permanent delete failures in the status bar.
                    NotificationCenter.default.addObserver(forName: .deleteJobsPermanentlyFailed,
                                                           object: nil, queue: .main) { [weak self] note in
                        let count = note.userInfo?["count"] as? Int ?? 0
                        guard count > 0 else { return }
                        self?.windowController?.statusBar.updateSyncStatus(
                            "Couldn't delete \(count) message\(count == 1 ? "" : "s") — retry from folder view")
                    }
                    // Reload the message list when the emails-per-page setting changes.
                    NotificationCenter.default.addObserver(forName: .emailListLimitChanged,
                                                           object: nil, queue: .main) { [weak self] _ in
                        self?.loadMessages()
                    }
                    // Kick off an immediate sync so the user sees emails on launch
                    if !accounts.isEmpty {
                        Task { await self.performSyncCycle() }
                    }
                }
            }
        } catch {
            showError("Failed to initialize: \(error.localizedDescription)")
        }
    }

    // MARK: - Data Loading

    private func loadMessages() {
        guard let accountManager, let accountId = currentAccountId else { return }
        // Reset pagination state. Every folder/account switch and every action
        // that calls loadMessages should start from a clean page.
        isLoadingMoreMessages = false
        hasMoreMessages = true
        let limit = DisplayPreferences.emailListLimit

        Task { @MainActor in
            do {
                let headers = try await accountManager.fetchHeaders(accountId: accountId, folder: currentFolder, offset: 0, limit: limit)
                windowController?.messageListView.update(messages: headers)
                // Another page likely exists only if the current page filled the limit.
                hasMoreMessages = headers.count >= limit
                windowController?.messageListView.setCanLoadMore(hasMoreMessages && !isSearching)
                updateStatusBar()
            } catch {
                showError("Failed to load messages: \(error.localizedDescription)")
            }
        }
    }

    /// Fetch the next page and append it to the message list. Fired by
    /// MessageListView when the user scrolls near the bottom.
    private func loadMoreMessages() {
        guard let accountManager, let accountId = currentAccountId else { return }
        guard !isLoadingMoreMessages, hasMoreMessages, !isSearching else { return }
        guard let listView = windowController?.messageListView else { return }
        let currentCount = listView.messages.count
        guard currentCount > 0 else { return }

        isLoadingMoreMessages = true
        let limit = DisplayPreferences.emailListLimit

        Task { @MainActor in
            defer { isLoadingMoreMessages = false }
            do {
                let headers = try await accountManager.fetchHeaders(
                    accountId: accountId,
                    folder: currentFolder,
                    offset: currentCount,
                    limit: limit
                )
                // Guard against stale responses: if the user switched folders/accounts
                // while this request was in flight, its data no longer matches what's
                // on screen. The listView's message count will have been reset by
                // loadMessages(), so a mismatch signals the response is stale.
                guard listView.messages.count == currentCount else { return }

                listView.append(messages: headers)
                hasMoreMessages = headers.count >= limit
                listView.setCanLoadMore(hasMoreMessages && !isSearching)
            } catch {
                // Don't showError — it would pop a modal mid-scroll. Log and stop
                // paginating so the user can retry by reopening the folder.
                NSLog("Failed to load more messages: \(error.localizedDescription)")
                listView.setCanLoadMore(false)
            }
        }
    }

    /// Reload message list + sidebar counts + status bar after a batch action.
    private func refreshAfterBatchAction() {
        loadMessages()
        loadSidebar()
        updateStatusBar()
    }

    private func loadMessageDetail(header: EmailHeader) {
        guard let accountManager else { return }

        // Skip if already displaying this email (e.g. re-triggered by reloadData
        // after markRead — reloadData clears selection to nil then restores it,
        // which fires tableViewSelectionDidChange again for the same email).
        guard header.id != displayedEmailId else { return }
        displayedEmailId = header.id

        // Show header immediately — body loads async below.
        windowController?.detailView.display(header: header, body: nil, isLoading: true)

        // Wire action buttons that don't need the body.
        windowController?.detailView.onArchive = { [weak self] in
            self?.handleAction(.archive(header.id))
        }
        windowController?.detailView.onDelete = { [weak self] in
            self?.handleAction(.delete(header.id))
        }
        windowController?.detailView.onMove = { [weak self] folderId in
            self?.handleAction(.moveToFolder(header.id, folderId))
        }

        // Fetch body, then mark as read AFTER.
        // IMAP is a stateful single-connection protocol — concurrent provider
        // calls (markRead + fetchBody) race on the socket and the body fetch
        // fails silently. Keeping the original order (body first, markRead second)
        // avoids the collision.
        Task { @MainActor in
            do {
                let body = try await accountManager.fetchBody(emailId: header.id)
                windowController?.detailView.display(header: header, body: body)

                // Wire reply/forward (need body for compose window).
                windowController?.detailView.onReply = { [weak self] in
                    self?.openComposer(mode: .reply(to: header, body: body))
                }
                windowController?.detailView.onForward = { [weak self] in
                    self?.openComposer(mode: .forward(original: header, body: body))
                }

                // Populate available folders for the Move menu
                if let accountId = self.currentAccountId,
                   let folders = try? await accountManager.listFolders(accountId: accountId) {
                    windowController?.detailView.availableFolders = folders.filter { $0.id != header.folder }
                }

                // Load and display attachments
                if header.hasAttachments {
                    let attachments = try await accountManager.listAttachments(emailId: header.id)
                    windowController?.detailView.displayAttachments(attachments)
                    windowController?.detailView.onDownloadAttachment = { [weak self] att in
                        self?.downloadAttachment(emailId: header.id, attachment: att)
                    }
                } else {
                    windowController?.detailView.displayAttachments([])
                }

                // Mark as read after body is displayed (fire-and-forget).
                if !header.isRead {
                    Task { @MainActor [weak self] in
                        try? await accountManager.markRead(emailId: header.id, read: true)
                        self?.loadMessages()
                    }
                }
            } catch {
                showError("Failed to load message: \(error.localizedDescription)")
            }
        }
    }

    private func performSearch(query: String) {
        guard let accountManager else { return }

        if query.isEmpty {
            isSearching = false
            loadMessages()
            return
        }

        isSearching = true
        Task { @MainActor in
            do {
                // Cross-account search (accountId: nil)
                let results = try await accountManager.search(query: query, accountId: nil)
                windowController?.messageListView.update(messages: results)
                // Search results are the complete match set — no pagination here.
                windowController?.messageListView.setCanLoadMore(false)
            } catch {
                showError("Search failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Actions

    /// Expand a list of visible-row email IDs to include all thread members.
    /// If a row has a threadId, fetches all messages in that thread from the store.
    /// Falls back to the original ID if no thread is found.
    private func expandThreadIds(_ ids: [Int64]) async throws -> [Int64] {
        guard let accountManager else { return ids }
        var expanded = Set<Int64>(ids)
        let groups = windowController?.messageListView.threadGroups ?? []
        let folder = currentFolder
        for id in ids {
            if let group = groups.first(where: { $0.primaryHeader.id == id }),
               let threadId = group.threadId {
                let members = try await accountManager.fetchThread(threadId: threadId)
                for header in members where header.folder == folder {
                    expanded.insert(header.id)
                }
            }
        }
        return Array(expanded)
    }

    /// Blocking confirmation for bulk-destructive actions. Returns true if user confirms.
    @MainActor
    private func confirmBulkDelete(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete \(count) messages?"
        alert.informativeText = "This will move \(count) messages to Trash on the server. You can undo briefly from the toast, but the action propagates quickly."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

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
                case .moveToFolder(let id, let folder) where id > 0:
                    try await accountManager.move(emailId: id, toFolder: folder)
                    loadMessages()
                case .refresh:
                    await performSyncCycle()
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
                case .batchDelete(let ids) where !ids.isEmpty:
                    let expandedIds = try await expandThreadIds(ids)
                    // Guardrail: undo toast alone isn't enough protection for large deletes.
                    // Require explicit confirmation once the batch gets destructive.
                    if expandedIds.count >= 50, !confirmBulkDelete(count: expandedIds.count) {
                        break
                    }
                    try await accountManager.deleteBatch(emailIds: expandedIds)
                    // Reload list (fetches next page), sidebar counts, status bar
                    refreshAfterBatchAction()
                    windowController?.messageListView.clearCheckedIds()
                    let deleteDesc = expandedIds.count != ids.count
                        ? "Deleted \(ids.count) conversation\(ids.count == 1 ? "" : "s") (\(expandedIds.count) messages)"
                        : "Deleted \(ids.count) conversation\(ids.count == 1 ? "" : "s")"
                    let deleteAction = UndoableBatchAction(
                        description: deleteDesc,
                        reverseOperation: { [weak self] in
                            guard let store = self?.accountManager?.store else { return }
                            try await store.cancelPendingDeletes(emailIds: expandedIds)
                        },
                        emailIds: expandedIds
                    )
                    windowController?.undoToastView.onUndo = { [weak self] in self?.refreshAfterBatchAction() }
                    windowController?.undoToastView.show(action: deleteAction, onExpire: {})
                case .batchArchive(let ids) where !ids.isEmpty:
                    let expandedIds = try await expandThreadIds(ids)
                    let originalRecords = try await accountManager.store.fetchEmailRecords(ids: expandedIds)
                    try await accountManager.archiveBatch(emailIds: expandedIds)
                    refreshAfterBatchAction()
                    windowController?.messageListView.clearCheckedIds()
                    let archiveDesc = expandedIds.count != ids.count
                        ? "Archived \(ids.count) conversation\(ids.count == 1 ? "" : "s") (\(expandedIds.count) messages)"
                        : "Archived \(ids.count) conversation\(ids.count == 1 ? "" : "s")"
                    let archiveAction = UndoableBatchAction(
                        description: archiveDesc,
                        reverseOperation: { [weak self] in
                            guard let store = self?.accountManager?.store else { return }
                            for record in originalRecords {
                                guard let emailId = record.id else { continue }
                                try await store.moveEmailBatch(emailIds: [emailId], toFolder: record.folder)
                            }
                        },
                        emailIds: expandedIds
                    )
                    windowController?.undoToastView.onUndo = { [weak self] in self?.refreshAfterBatchAction() }
                    windowController?.undoToastView.show(action: archiveAction, onExpire: {})
                case .batchMarkRead(let ids) where !ids.isEmpty:
                    let expandedIds = try await expandThreadIds(ids)
                    try await accountManager.markReadBatch(emailIds: expandedIds, read: true)
                    windowController?.messageListView.clearCheckedIds()
                    loadMessages()
                    let markReadAction = UndoableBatchAction(
                        description: "Marked \(ids.count) conversation\(ids.count == 1 ? "" : "s") as read",
                        reverseOperation: { [weak self] in
                            try await self?.accountManager?.markReadBatch(emailIds: expandedIds, read: false)
                        },
                        emailIds: expandedIds
                    )
                    windowController?.undoToastView.onUndo = { [weak self] in self?.refreshAfterBatchAction() }
                    windowController?.undoToastView.show(action: markReadAction, onExpire: {})
                case .batchMarkUnread(let ids) where !ids.isEmpty:
                    let expandedIds = try await expandThreadIds(ids)
                    try await accountManager.markReadBatch(emailIds: expandedIds, read: false)
                    windowController?.messageListView.clearCheckedIds()
                    loadMessages()
                    let markUnreadAction = UndoableBatchAction(
                        description: "Marked \(ids.count) conversation\(ids.count == 1 ? "" : "s") as unread",
                        reverseOperation: { [weak self] in
                            try await self?.accountManager?.markReadBatch(emailIds: expandedIds, read: true)
                        },
                        emailIds: expandedIds
                    )
                    windowController?.undoToastView.onUndo = { [weak self] in self?.refreshAfterBatchAction() }
                    windowController?.undoToastView.show(action: markUnreadAction, onExpire: {})
                case .batchToggleStar(let ids) where !ids.isEmpty:
                    let expandedIds = try await expandThreadIds(ids)
                    try await accountManager.markStarredBatch(emailIds: expandedIds, starred: true)
                    windowController?.messageListView.clearCheckedIds()
                    loadMessages()
                    let starAction = UndoableBatchAction(
                        description: "Starred \(ids.count) conversation\(ids.count == 1 ? "" : "s")",
                        reverseOperation: { [weak self] in
                            try await self?.accountManager?.markStarredBatch(emailIds: expandedIds, starred: false)
                        },
                        emailIds: expandedIds
                    )
                    windowController?.undoToastView.onUndo = { [weak self] in self?.refreshAfterBatchAction() }
                    windowController?.undoToastView.show(action: starAction, onExpire: {})
                case .batchMove(let ids, let folder) where !ids.isEmpty && !folder.isEmpty:
                    let expandedIds = try await expandThreadIds(ids)
                    let preRecords = try await accountManager.store.fetchEmailRecords(ids: expandedIds)
                    try await accountManager.moveBatch(emailIds: expandedIds, toFolder: folder)
                    refreshAfterBatchAction()
                    windowController?.messageListView.clearCheckedIds()
                    let moveDesc = expandedIds.count != ids.count
                        ? "Moved \(ids.count) conversation\(ids.count == 1 ? "" : "s") (\(expandedIds.count) messages)"
                        : "Moved \(ids.count) conversation\(ids.count == 1 ? "" : "s")"
                    let moveAction = UndoableBatchAction(
                        description: moveDesc,
                        reverseOperation: { [weak self] in
                            guard let store = self?.accountManager?.store else { return }
                            for record in preRecords {
                                guard let emailId = record.id else { continue }
                                try await store.moveEmailBatch(emailIds: [emailId], toFolder: record.folder)
                            }
                        },
                        emailIds: expandedIds
                    )
                    windowController?.undoToastView.onUndo = { [weak self] in self?.refreshAfterBatchAction() }
                    windowController?.undoToastView.show(action: moveAction, onExpire: {})
                case .batchMove(let ids, _) where !ids.isEmpty:
                    // batchMove with empty folder — no-op (folder picker not yet implemented)
                    windowController?.messageListView.clearCheckedIds()
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
        composer.contactsStore = contactsStore
        composer.accountId = currentAccountId

        // Populate From selector with all accounts
        Task { @MainActor in
            if let accounts = try? await self.accountManager?.listAccounts() {
                composer.setAccounts(
                    accounts.map { (id: $0.id, email: $0.emailAddress) },
                    selected: self.currentAccountId
                )
            }
        }

        composer.onSend = { [weak self, weak composer] message, completion in
            guard let self else {
                completion("No account selected.")
                return
            }
            let accountId = composer?.selectedAccountId ?? self.currentAccountId
            guard let accountId else {
                completion("No account selected.")
                return
            }
            Task {
                do {
                    try await self.accountManager?.send(message: message, fromAccountId: accountId)
                    await MainActor.run {
                        self.windowController?.statusBar.updateSyncStatus("Message sent")
                        // completion(nil) must be called before composerWindow = nil.
                        // The completion closure captures ComposerWindow via [weak self];
                        // releasing composerWindow first deallocates it, making self nil
                        // and leaving the window stuck in "Sending…" forever.
                        completion(nil)
                        self.composerWindow = nil
                        // Sync so the Sent folder appears promptly
                        Task { await self.performSyncCycle() }
                    }
                } catch {
                    // Use full string description so NIOConnectionError shows its
                    // connectionErrors details instead of the generic "error 1" NSError format.
                    let detail = "\(error)"
                    let friendly = detail.isEmpty ? error.localizedDescription : detail
                    completion(friendly)
                }
            }
        }
        self.composerWindow = composer  // Retain reference
        composer.show()
    }

    // MARK: - Menu Actions

    @objc private func composeNewMessage() { openComposer(mode: .compose) }

    @objc private func printEmail() {
        windowController?.detailView.printEmail()
    }

    @objc private func exportEml() {
        guard let accountManager,
              let header = windowController?.messageListView.selectedHeader else { return }
        Task { @MainActor in
            do {
                let body = try await accountManager.fetchBody(emailId: header.id)
                let eml = Self.buildEml(header: header, body: body)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "\(header.subject ?? "email").eml"
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url {
                    try eml.write(to: url, atomically: true, encoding: .utf8)
                }
            } catch {
                showError("Export failed: \(error.localizedDescription)")
            }
        }
    }

    /// Build a basic RFC 822 .eml string from header + body.
    private static func buildEml(header: EmailHeader, body: EmailBody?) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        var eml = "From: \(header.senderEmail)\r\n"
        eml += "Date: \(dateFormatter.string(from: header.date))\r\n"
        eml += "Subject: \(header.subject ?? "")\r\n"
        eml += "Message-ID: <\(header.messageId)>\r\n"
        eml += "MIME-Version: 1.0\r\n"

        if let html = body?.htmlBody, !html.isEmpty {
            eml += "Content-Type: text/html; charset=utf-8\r\n"
            eml += "\r\n"
            eml += html
        } else {
            eml += "Content-Type: text/plain; charset=utf-8\r\n"
            eml += "\r\n"
            eml += body?.textBody ?? ""
        }
        return eml
    }

    @objc private func syncNow() {
        Task { @MainActor in
            await performSyncCycle()
        }
    }

    /// Runs one sync cycle: updates status bar, syncs all accounts, reloads UI.
    @MainActor
    private func performSyncCycle() async {
        guard let accountManager, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        syncStartTime = Date()
        syncBaseEmailCount = (try? await accountManager.store.emailCount()) ?? 0

        windowController?.statusBar.updateConnection(status: .syncing)
        startSyncProgressTimer()

        // Sync all accounts the user has visited this session.
        var didAttempt = false   // a provider existed and we tried
        var didSucceed = false   // at least one account synced without error
        for accountId in activatedAccountIds {
            do {
                let ran = try await accountManager.performIncrementalSync(accountId: accountId)
                if ran {
                    didAttempt = true
                    didSucceed = true
                    windowController?.sidebarView.setAuthError(for: accountId, hasError: false)
                }
            } catch {
                didAttempt = true  // provider existed but sync failed
                if isAuthError(error) {
                    windowController?.sidebarView.setAuthError(for: accountId, hasError: true)
                }
            }
        }

        stopSyncProgressTimer()
        loadSidebar()
        loadMessages()
        updateStatusBar()

        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none

        if !didAttempt {
            // No account had a provider (e.g. demo/offline account).
            windowController?.statusBar.updateSyncStatus("Offline — no mail server")
            windowController?.statusBar.updateConnection(status: .offline)
        } else if !didSucceed {
            windowController?.statusBar.updateSyncStatus("Sync failed \(fmt.string(from: Date()))")
            windowController?.statusBar.updateConnection(status: .disconnected)
        } else {
            let elapsed = Int(-(syncStartTime?.timeIntervalSinceNow ?? 0))
            let finalCount = (try? await accountManager.store.emailCount()) ?? 0
            let added = max(0, finalCount - syncBaseEmailCount)
            let addedStr = added > 0 ? " · +\(Self.formatCount(added)) emails" : ""
            windowController?.statusBar.updateSyncStatus("Synced \(fmt.string(from: Date())) (\(elapsed)s\(addedStr))")
            windowController?.statusBar.updateConnection(status: .connected)
        }
        syncStartTime = nil
    }

    private func startSyncProgressTimer() {
        syncProgressTimer?.invalidate()
        syncProgressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isSyncing, let start = self.syncStartTime else { return }
                let elapsed = Int(-start.timeIntervalSinceNow)
                let current = (try? await self.accountManager?.store.emailCount()) ?? 0
                let added = max(0, current - self.syncBaseEmailCount)
                let addedStr = added > 0 ? " · +\(Self.formatCount(added)) emails" : ""
                self.windowController?.statusBar.updateSyncStatus("Syncing… \(elapsed)s\(addedStr)")
            }
        }
    }

    private func stopSyncProgressTimer() {
        syncProgressTimer?.invalidate()
        syncProgressTimer = nil
    }

    private static func formatCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    /// Starts a background loop that syncs every 5 minutes.
    private func startPeriodicSyncLoop() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await performSyncCycle()
            }
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

                    // Step 4: Connection succeeded — run initial sync in background (no timeout)
                    Task { await self.performSyncCycle() }

                    // Fire-and-forget contacts fetch for OAuth accounts (Gmail)
                    if config.authType == .oauth2, let contactsStore = self.contactsStore {
                        Task { await contactsStore.fetchAndStore(accountId: config.id) }
                    }

                    await MainActor.run {
                        completion(nil) // Must call before releasing sheet
                        self.loadSidebar()
                        self.switchAccount(config.id) // Switch to the newly added account
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
        UserDefaults.standard.set(accountId, forKey: "lastActiveAccountId")
        activatedAccountIds.insert(accountId)
        currentFolder = "INBOX"
        displayedEmailId = nil
        loadFoldersForCurrentAccount()
        loadMessages()
        Task { await performSyncCycle() }
    }

    private static func defaultFolders() -> [MailFolder] {
        [
            MailFolder(id: "INBOX", name: "Inbox", totalCount: 0, hasUnread: false, role: .inbox),
            MailFolder(id: "[Gmail]/Starred", name: "Starred", totalCount: 0, hasUnread: false, role: .starred),
            MailFolder(id: "[Gmail]/Sent Mail", name: "Sent", totalCount: 0, hasUnread: false, role: .sent),
            MailFolder(id: "[Gmail]/Drafts", name: "Drafts", totalCount: 0, hasUnread: false, role: .drafts),
            MailFolder(id: "[Gmail]/Trash", name: "Trash", totalCount: 0, hasUnread: false, role: .trash),
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

    private func downloadAttachment(emailId: Int64, attachment: AttachmentInfo) {
        guard let accountManager else { return }
        Task { @MainActor in
            do {
                let data = try await accountManager.fetchAttachmentData(emailId: emailId, partId: attachment.partId)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = attachment.filename ?? "attachment"
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url {
                    try data.write(to: url)
                }
            } catch {
                showError("Failed to download attachment: \(error.localizedDescription)")
            }
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func isAuthError(_ error: Error) -> Bool {
        guard let e = error as? IMAPProviderError else { return false }
        switch e {
        case .noCredentials, .authFailed: return true
        default: return false
        }
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
