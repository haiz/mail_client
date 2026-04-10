import AppKit

/// A group of messages in the same thread (for collapsed thread display).
struct ThreadGroup {
    let primaryHeader: EmailHeader
    let count: Int
    let threadId: String?
}

/// Message list with NSTableView, lazy row loading from GRDB, thread grouping.
/// View-based table with cell recycling for minimal memory usage.
final class MessageListView: NSObject {

    let view: NSView
    private let scrollView: NSScrollView
    let tableView: NSTableView
    private let searchField: NSSearchField

    var onMessageSelected: ((EmailHeader) -> Void)?
    var onSearchChanged: ((String) -> Void)?
    var onCheckedIdsChanged: ((Set<Int64>) -> Void)?

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

        // Table view
        tableView = NSTableView()
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
        container.addSubview(searchField)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            searchField.heightAnchor.constraint(equalToConstant: 28),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
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

        setupEmptyState(in: container)
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

    /// Clear all checkbox selections.
    func clearCheckedIds() {
        checkedIds = []
        tableView.reloadData()
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
        onCheckedIdsChanged?(checkedIds)
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

        // Checkbox — hidden until multi-select is active
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
            // Checkbox at the left edge
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Unread dot anchored off the checkbox trailing edge
            unreadDot.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 2),
            unreadDot.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.heightAnchor.constraint(equalToConstant: 8),

            senderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            senderLabel.leadingAnchor.constraint(equalTo: unreadDot.trailingAnchor, constant: 6),

            threadBadge.centerYAnchor.constraint(equalTo: senderLabel.centerYAnchor),
            threadBadge.leadingAnchor.constraint(equalTo: senderLabel.trailingAnchor, constant: 4),
            threadBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 18),
            threadBadge.heightAnchor.constraint(equalToConstant: 14),
            threadBadge.trailingAnchor.constraint(lessThanOrEqualTo: dateLabel.leadingAnchor, constant: -8),
            senderLabel.trailingAnchor.constraint(lessThanOrEqualTo: threadBadge.leadingAnchor, constant: -4),

            dateLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            subjectLabel.topAnchor.constraint(equalTo: senderLabel.bottomAnchor, constant: 2),
            subjectLabel.leadingAnchor.constraint(equalTo: senderLabel.leadingAnchor),
            subjectLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            starIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            starIcon.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            starIcon.widthAnchor.constraint(equalToConstant: 12),
            starIcon.heightAnchor.constraint(equalToConstant: 12),
        ])
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

        // Checkbox visibility: show when any row is checked, hide when none are
        checkbox.isHidden = !showCheckboxes
        checkbox.state = isChecked ? .on : .off
    }
}
