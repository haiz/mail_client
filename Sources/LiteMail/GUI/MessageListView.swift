import AppKit

/// A group of messages in the same thread (for collapsed thread display).
struct ThreadGroup {
    let primaryHeader: EmailHeader
    let count: Int
    let threadId: String?
}

/// NSTableView subclass that allows embedded controls (checkboxes, buttons) to
/// receive clicks directly instead of the table eating the mouseDown for row selection.
///
/// Two mechanisms work together:
/// 1. `validateProposedFirstResponder` tells AppKit to let NSButtons handle events.
/// 2. `mouseDown` directly detects checkbox clicks by coordinate, bypassing hitTest.
///    This is necessary because after reloadData, recycled cells may have stale layout
///    (checkbox frame still zero-width) until the next display pass.
private final class MessageTableView: NSTableView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        if responder is NSButton { return true }
        return super.validateProposedFirstResponder(responder, for: event)
    }

    override func mouseDown(with event: NSEvent) {
        let pointInTable = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: pointInTable)
        if clickedRow >= 0,
           let cell = view(atColumn: 0, row: clickedRow, makeIfNecessary: false) {
            let pointInCell = cell.convert(event.locationInWindow, from: nil)
            for subview in cell.subviews {
                guard let button = subview as? NSButton, !button.isHidden else { continue }
                if button.frame.insetBy(dx: -4, dy: -6).contains(pointInCell) {
                    button.sendAction(button.action, to: button.target)
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }
}

/// Message list with NSTableView, lazy row loading from GRDB, thread grouping.
/// View-based table with cell recycling for minimal memory usage.
final class MessageListView: NSObject {

    let view: NSView
    private let scrollView: NSScrollView
    let tableView: NSTableView
    private let searchField: NSSearchField
    let bulkActionBar = BulkActionBar()
    private var bulkBarHeightConstraint: NSLayoutConstraint!

    var onMessageSelected: ((EmailHeader) -> Void)?
    var onSearchChanged: ((String) -> Void)?
    var onCheckedIdsChanged: ((Set<Int64>) -> Void)?
    /// Fired when the user scrolls near the bottom and more emails should be loaded.
    /// Guarded internally against re-firing while a previous request is in flight.
    var onRequestLoadMore: (() -> Void)?

    /// Tracks whether a load-more request is currently in flight. Prevents duplicate
    /// fires from trackpad momentum scrolling, which produces many bounds-changed
    /// notifications in rapid succession.
    private var isLoadingMore = false
    /// Whether more pages are available. Set to false when the last page returned
    /// fewer rows than the requested limit, or when in search mode.
    private var canLoadMore = false
    /// Distance from the bottom (in points) at which a load-more is triggered.
    /// ~6 rows of 64pt gives the fetch time to land before the user hits the end.
    private static let loadMoreThreshold: CGFloat = 400

    /// The name of the currently displayed folder, used for the empty state subtitle.
    var currentFolderName: String = "Inbox" {
        didSet { updateEmptyState() }
    }

    // Empty state overlay
    private let emptyStateView = NSView()
    private let emptyTitleLabel = NSTextField(labelWithString: "All caught up")
    private let emptySubtitleLabel = NSTextField(labelWithString: "")

    /// Set of email IDs the user has checked via checkboxes.
    private(set) var checkedIds: Set<Int64> = []

    /// Thread groups for display. Each group shows the latest message with a count.
    private(set) var threadGroups: [ThreadGroup] = []
    /// Flat message list (pre-grouping).
    private(set) var messages: [EmailHeader] = []
    private(set) var selectedHeader: EmailHeader? {
        didSet {
            if let header = selectedHeader, header.id != oldValue?.id {
                onMessageSelected?(header)
            }
        }
    }

    override init() {
        // Search field at top
        searchField = NSSearchField()
        searchField.placeholderString = "Search emails... \u{2318}K"
        searchField.translatesAutoresizingMaskIntoConstraints = false

        // Table view — custom subclass so checkboxes receive clicks directly
        tableView = MessageTableView()
        tableView.headerView = nil
        tableView.rowHeight = 64
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.gridStyleMask = []

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("MessageColumn"))
        column.isEditable = false
        tableView.addTableColumn(column)

        // Scroll view
        scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Container
        let container = NSView()
        bulkActionBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)
        container.addSubview(bulkActionBar)
        container.addSubview(scrollView)

        // BulkActionBar height: 0 when hidden, 36 when visible
        bulkBarHeightConstraint = bulkActionBar.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            bulkActionBar.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 4),
            bulkActionBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bulkActionBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bulkBarHeightConstraint,

            scrollView.topAnchor.constraint(equalTo: bulkActionBar.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container

        super.init()

        tableView.dataSource = self
        tableView.delegate = self
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldChanged)

        // Infinite scroll: listen for scroll events so we can fire onRequestLoadMore
        // when the user reaches the bottom. contentView.postsBoundsChangedNotifications
        // must be explicitly enabled — NSClipView does not post by default.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        setupEmptyState(in: container)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func scrollViewDidScroll() {
        guard !isLoadingMore, canLoadMore, !threadGroups.isEmpty else { return }
        let visible = scrollView.contentView.documentVisibleRect
        let documentHeight = tableView.bounds.height
        // Trigger when the bottom of the visible region is within threshold of the
        // bottom of the document. visible.maxY == documentHeight when fully scrolled.
        guard visible.maxY >= documentHeight - Self.loadMoreThreshold else { return }
        isLoadingMore = true
        onRequestLoadMore?()
    }

    private func setupEmptyState(in container: NSView) {
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        container.addSubview(emptyStateView)

        emptyTitleLabel.font = .systemFont(ofSize: 16, weight: .medium)
        emptyTitleLabel.textColor = .secondaryLabelColor
        emptyTitleLabel.alignment = .center
        emptyTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        emptySubtitleLabel.font = .systemFont(ofSize: 13)
        emptySubtitleLabel.textColor = .secondaryLabelColor
        emptySubtitleLabel.alignment = .center
        emptySubtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        emptyStateView.addSubview(emptyTitleLabel)
        emptyStateView.addSubview(emptySubtitleLabel)

        NSLayoutConstraint.activate([
            // Overlay the scroll view area (below search field)
            emptyStateView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyTitleLabel.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyTitleLabel.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor, constant: -10),

            emptySubtitleLabel.topAnchor.constraint(equalTo: emptyTitleLabel.bottomAnchor, constant: 6),
            emptySubtitleLabel.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
        ])
    }

    private func updateEmptyState() {
        emptySubtitleLabel.stringValue = "No emails in \(currentFolderName)"
        emptyStateView.isHidden = !threadGroups.isEmpty
    }

    func update(messages: [EmailHeader]) {
        let previouslySelectedId = selectedHeader?.id
        self.messages = messages
        self.threadGroups = Self.groupByThread(messages)
        // Fresh page — any in-flight load-more no longer applies.
        isLoadingMore = false
        tableView.reloadData()
        updateEmptyState()

        // Restore selection to the same email, or fall back to row 0
        if let prevId = previouslySelectedId,
           let idx = threadGroups.firstIndex(where: { $0.primaryHeader.id == prevId }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        } else if !threadGroups.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// Append additional pages without disturbing the user's scroll position or
    /// selection. Used by infinite-scroll pagination.
    func append(messages newMessages: [EmailHeader]) {
        isLoadingMore = false
        guard !newMessages.isEmpty else { return }

        let previouslySelectedId = selectedHeader?.id
        let scrollOrigin = scrollView.contentView.bounds.origin

        self.messages.append(contentsOf: newMessages)
        self.threadGroups = Self.groupByThread(self.messages)
        tableView.reloadData()
        updateEmptyState()

        // Restore selection without triggering scrollRowToVisible — the user is
        // scrolling through the list; jumping to the old selected row would be jarring.
        if let prevId = previouslySelectedId,
           let idx = threadGroups.firstIndex(where: { $0.primaryHeader.id == prevId }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        }
        scrollView.contentView.setBoundsOrigin(scrollOrigin)
    }

    /// Enable/disable infinite-scroll pagination. AppDelegate turns this off in
    /// search mode and after the last page returns fewer rows than the limit.
    func setCanLoadMore(_ value: Bool) {
        canLoadMore = value
        if !value {
            isLoadingMore = false
        }
    }

    func selectNextRow() {
        let next = min(tableView.selectedRow + 1, threadGroups.count - 1)
        guard next >= 0 else { return }
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    func selectPreviousRow() {
        let prev = max(tableView.selectedRow - 1, 0)
        tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
        tableView.scrollRowToVisible(prev)
    }

    /// Get table row indices for a set of email IDs.
    func indicesForIds(_ ids: Set<Int64>) -> IndexSet {
        var indexSet = IndexSet()
        for (i, group) in threadGroups.enumerated() {
            if ids.contains(group.primaryHeader.id) {
                indexSet.insert(i)
            }
        }
        return indexSet
    }

    /// Remove rows with animation. Updates data source first, then animates.
    func removeRows(forIds ids: Set<Int64>) {
        let indices = indicesForIds(ids)
        guard !indices.isEmpty else { return }

        // Update data source BEFORE animation
        var remaining: [ThreadGroup] = []
        for (i, group) in threadGroups.enumerated() {
            if !indices.contains(i) {
                remaining.append(group)
            }
        }
        threadGroups = remaining
        checkedIds.subtract(ids)

        // Animate
        tableView.beginUpdates()
        tableView.removeRows(at: indices, withAnimation: .effectFade)
        tableView.endUpdates()

        updateBulkBar()
        onCheckedIdsChanged?(checkedIds)
        updateEmptyState()
    }

    /// Select all loaded emails (including every message within each thread group).
    func selectAllChecked() {
        checkedIds = Set(messages.map { $0.id })
        tableView.reloadData()
        updateBulkBar()
        onCheckedIdsChanged?(checkedIds)
    }

    /// Clear all checkbox selections.
    func clearCheckedIds() {
        checkedIds = []
        tableView.reloadData()
        updateBulkBar()
        onCheckedIdsChanged?(checkedIds)
    }

    /// Toggle the checked state of a single email row.
    func toggleChecked(emailId: Int64) {
        if checkedIds.contains(emailId) {
            checkedIds.remove(emailId)
        } else {
            checkedIds.insert(emailId)
        }
        tableView.reloadData()
        updateBulkBar()
        onCheckedIdsChanged?(checkedIds)
    }

    private func updateBulkBar() {
        let count = checkedIds.count
        bulkActionBar.update(selectedCount: count, totalCount: threadGroups.count)
        let targetHeight: CGFloat = count > 0 ? 36 : 0
        guard bulkBarHeightConstraint.constant != targetHeight else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.allowsImplicitAnimation = true
            bulkBarHeightConstraint.constant = targetHeight
            view.layoutSubtreeIfNeeded()
        }
    }

    /// Group messages by threadId. Messages without a threadId get their own group.
    private static func groupByThread(_ messages: [EmailHeader]) -> [ThreadGroup] {
        var groups: [String: [EmailHeader]] = [:]
        var order: [String] = []

        for msg in messages {
            let key = msg.threadId ?? "solo_\(msg.id)"
            if groups[key] == nil {
                order.append(key)
            }
            groups[key, default: []].append(msg)
        }

        return order.compactMap { key -> ThreadGroup? in
            guard let msgs = groups[key], let latest = msgs.first else { return nil }
            // Messages are already sorted by date desc from the store
            return ThreadGroup(primaryHeader: latest, count: msgs.count, threadId: latest.threadId)
        }
    }

    @objc private func searchFieldChanged() {
        onSearchChanged?(searchField.stringValue)
    }
}

// MARK: - NSTableViewDataSource

extension MessageListView: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        threadGroups.count
    }

    // MARK: - Drag source

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row < threadGroups.count else { return nil }
        let item = NSPasteboardItem()
        item.setString("\(threadGroups[row].primaryHeader.id)", forType: .string)
        return item
    }
}

// MARK: - NSTableViewDelegate

extension MessageListView: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < threadGroups.count else { return nil }
        let group = threadGroups[row]

        let cellId = NSUserInterfaceItemIdentifier("MessageCell")
        let cell: MessageCellView

        if let recycled = tableView.makeView(withIdentifier: cellId, owner: self) as? MessageCellView {
            cell = recycled
        } else {
            cell = MessageCellView()
            cell.identifier = cellId
        }

        let emailId = group.primaryHeader.id
        cell.configure(
            with: group.primaryHeader,
            threadCount: group.count,
            isChecked: checkedIds.contains(emailId),
            showCheckboxes: !checkedIds.isEmpty
        )
        cell.onCheckboxToggled = { [weak self] in
            self?.toggleChecked(emailId: emailId)
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < threadGroups.count else {
            selectedHeader = nil
            return
        }
        selectedHeader = threadGroups[row].primaryHeader
    }
}

// MARK: - NSSearchFieldDelegate

extension MessageListView: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onSearchChanged?(searchField.stringValue)
    }
}

// MARK: - MessageCellView

private final class MessageCellView: NSTableCellView {

    private let senderLabel = NSTextField(labelWithString: "")
    private let subjectLabel = NSTextField(labelWithString: "")
    private let dateLabel = NSTextField(labelWithString: "")
    private let starIcon = NSImageView()
    private let unreadDot = NSView()
    private let threadBadge = NSTextField(labelWithString: "")
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)

    /// Called when the user clicks the checkbox.
    var onCheckboxToggled: (() -> Void)?

    /// Whether checkboxes should always be visible (when any row is checked).
    private var alwaysShowCheckbox = false
    /// Whether the mouse is currently hovering over this cell.
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    /// Fixed leading offset for the content area (sender, subject). Keeps content
    /// stable regardless of checkbox visibility — the checkbox zone always occupies
    /// this space, the checkbox itself is just shown/hidden inside it.
    private static let contentLeading: CGFloat = 44

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        for v in [checkbox, senderLabel, subjectLabel, dateLabel, starIcon, unreadDot, threadBadge] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        // Checkbox — hidden until hover or multi-select is active.
        // No width constraint toggling: the content zone is always fixed-width
        // so toggling the checkbox never shifts senderLabel.
        checkbox.isHidden = true
        checkbox.target = self
        checkbox.action = #selector(checkboxClicked)

        senderLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        senderLabel.lineBreakMode = .byTruncatingTail

        // Thread count badge
        threadBadge.font = .systemFont(ofSize: 10, weight: .medium)
        threadBadge.textColor = .white
        threadBadge.alignment = .center
        threadBadge.wantsLayer = true
        threadBadge.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
        threadBadge.layer?.cornerRadius = 7
        threadBadge.isHidden = true

        subjectLabel.font = .systemFont(ofSize: 12)

        subjectLabel.textColor = .secondaryLabelColor
        subjectLabel.lineBreakMode = .byTruncatingTail

        dateLabel.font = .systemFont(ofSize: 10)
        dateLabel.textColor = .tertiaryLabelColor
        dateLabel.alignment = .right
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        starIcon.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Starred")
        starIcon.contentTintColor = .systemYellow

        unreadDot.wantsLayer = true
        unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        unreadDot.layer?.cornerRadius = 4

        NSLayoutConstraint.activate([
            // Unread dot: fixed left margin, independent of layout chain
            unreadDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            unreadDot.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.heightAnchor.constraint(equalToConstant: 8),

            // Checkbox sits in the leading zone; content is always at contentLeading
            // so showing/hiding the checkbox never shifts senderLabel or subjectLabel.
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Sender at fixed offset — independent of checkbox visibility
            senderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            senderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MessageCellView.contentLeading),

            threadBadge.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
            threadBadge.leadingAnchor.constraint(equalTo: senderLabel.trailingAnchor, constant: 4),
            threadBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
            threadBadge.heightAnchor.constraint(equalToConstant: 14),
            threadBadge.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -8),
            senderLabel.trailingAnchor.constraint(lessThanOrEqualTo: threadBadge.leadingAnchor, constant: -4),

            dateLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            subjectLabel.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 2),
            subjectLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: MessageCellView.contentLeading),
            subjectLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            starIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            starIcon.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            starIcon.widthAnchor.constraint(equalToConstant: 12),
            starIcon.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateCheckboxVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateCheckboxVisibility()
    }

    private func updateCheckboxVisibility() {
        let shouldShow = alwaysShowCheckbox || isHovering
        checkbox.isHidden = !shouldShow
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        threadBadge.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
    }

    @objc private func checkboxClicked() {
        onCheckboxToggled?()
    }

    func configure(with header: EmailHeader, threadCount: Int = 1, isChecked: Bool = false, showCheckboxes: Bool = false) {
        senderLabel.stringValue = header.senderName ?? header.senderEmail
        senderLabel.font = header.isRead
            ? .systemFont(ofSize: 13)
            : .systemFont(ofSize: 13, weight: .semibold)
        senderLabel.textColor = header.isRead ? .secondaryLabelColor : .labelColor

        subjectLabel.stringValue = header.subject ?? "(no subject)"
        subjectLabel.textColor = header.isRead ? .tertiaryLabelColor : .secondaryLabelColor

        dateLabel.stringValue = Self.dateFormatter.string(from: header.date)

        starIcon.isHidden = !header.isStarred
        unreadDot.isHidden = header.isRead

        if threadCount > 1 {
            threadBadge.isHidden = false
            threadBadge.stringValue = "\(threadCount)"
        } else {
            threadBadge.isHidden = true
        }

        // Checkbox visibility: always visible when any row is checked, otherwise only on hover
        alwaysShowCheckbox = showCheckboxes
        checkbox.state = isChecked ? .on : .off
        updateCheckboxVisibility()
    }
}
