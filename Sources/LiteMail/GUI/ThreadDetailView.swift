import AppKit

/// Orchestrates a scrollable list of MessageCardViews for thread display.
/// Replaces the old single-message DetailView.
final class ThreadDetailView: NSObject {

    let view: NSView

    // Thread content
    private let scrollView: NSScrollView
    private let stackView: NSStackView
    private let subjectLabel = NSTextField(labelWithString: "")
    private var cards: [MessageCardView] = []

    // Empty state
    private let emptyContainer = NSView()
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "No message selected")
    private let emptySubtitle = NSTextField(labelWithString: "Select an email to read it here\n\u{2318}K to search \u{2022} j/k to navigate")

    // Bulk summary state
    private let summaryContainer = NSView()
    private let summaryIcon = NSImageView()
    private let summaryTitle = NSTextField(labelWithString: "")
    private let summaryList = NSTextField(labelWithString: "")

    // Callbacks
    var onReply: ((EmailHeader, EmailBody?) -> Void)?
    var onForward: ((EmailHeader, EmailBody?) -> Void)?
    var onArchive: ((Int64) -> Void)?
    var onDelete: ((Int64) -> Void)?
    var onMove: ((Int64, String) -> Void)?
    var onDownloadAttachment: ((Int64, AttachmentInfo) -> Void)?
    var onFetchBody: ((Int64) -> Void)?

    /// The current account's email, used for "to me" vs "to recipients" display.
    var accountEmail: String?

    /// Available folders for the Move menu. Set by AppDelegate.
    var availableFolders: [MailFolder] = [] {
        didSet { cards.forEach { $0.availableFolders = availableFolders } }
    }

    /// Number of cards currently displayed.
    var cardCount: Int { cards.count }

    /// Whether the card at a given index is expanded.
    func isCardExpanded(at index: Int) -> Bool {
        guard index >= 0, index < cards.count else { return false }
        return cards[index].isExpanded
    }

    override init() {
        view = NSView()
        view.wantsLayer = true

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.spacing = 1
        stackView.alignment = .leading
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        super.init()

        setupLayout()
        showEmpty()
    }

    // MARK: - Layout

    private func setupLayout() {
        subjectLabel.translatesAutoresizingMaskIntoConstraints = false
        subjectLabel.font = .systemFont(ofSize: 22, weight: .bold)
        subjectLabel.lineBreakMode = .byWordWrapping
        subjectLabel.maximumNumberOfLines = 2
        subjectLabel.textColor = .labelColor
        view.addSubview(subjectLabel)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            subjectLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            subjectLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            subjectLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),

            scrollView.topAnchor.constraint(equalTo: subjectLabel.bottomAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        // Empty state
        setupEmptyState()
        setupSummaryState()
    }

    private func setupEmptyState() {
        emptyContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyContainer)

        emptyIcon.image = NSImage(systemSymbolName: "envelope.open", accessibilityDescription: nil)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.symbolConfiguration = .init(pointSize: 40, weight: .ultraLight)
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false

        emptyTitle.font = .systemFont(ofSize: 18, weight: .medium)
        emptyTitle.textColor = .secondaryLabelColor
        emptyTitle.alignment = .center
        emptyTitle.translatesAutoresizingMaskIntoConstraints = false

        emptySubtitle.font = .systemFont(ofSize: 12)
        emptySubtitle.textColor = .tertiaryLabelColor
        emptySubtitle.alignment = .center
        emptySubtitle.maximumNumberOfLines = 3
        emptySubtitle.translatesAutoresizingMaskIntoConstraints = false

        emptyContainer.addSubview(emptyIcon)
        emptyContainer.addSubview(emptyTitle)
        emptyContainer.addSubview(emptySubtitle)

        NSLayoutConstraint.activate([
            emptyContainer.topAnchor.constraint(equalTo: view.topAnchor),
            emptyContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyIcon.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
            emptyIcon.centerYAnchor.constraint(equalTo: emptyContainer.centerYAnchor, constant: -40),
            emptyIcon.widthAnchor.constraint(equalToConstant: 48),
            emptyIcon.heightAnchor.constraint(equalToConstant: 48),
            emptyTitle.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 12),
            emptyTitle.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
            emptySubtitle.topAnchor.constraint(equalTo: emptyTitle.bottomAnchor, constant: 6),
            emptySubtitle.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
            emptySubtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 250),
        ])
    }

    private func setupSummaryState() {
        summaryContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summaryContainer)
        summaryContainer.isHidden = true

        summaryIcon.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        summaryIcon.contentTintColor = .tertiaryLabelColor
        summaryIcon.symbolConfiguration = .init(pointSize: 40, weight: .ultraLight)
        summaryIcon.translatesAutoresizingMaskIntoConstraints = false

        summaryTitle.font = .systemFont(ofSize: 18, weight: .medium)
        summaryTitle.textColor = .secondaryLabelColor
        summaryTitle.alignment = .center
        summaryTitle.translatesAutoresizingMaskIntoConstraints = false

        summaryList.font = .systemFont(ofSize: 12)
        summaryList.textColor = .tertiaryLabelColor
        summaryList.alignment = .center
        summaryList.maximumNumberOfLines = 6
        summaryList.lineBreakMode = .byWordWrapping
        summaryList.translatesAutoresizingMaskIntoConstraints = false

        summaryContainer.addSubview(summaryIcon)
        summaryContainer.addSubview(summaryTitle)
        summaryContainer.addSubview(summaryList)

        NSLayoutConstraint.activate([
            summaryContainer.topAnchor.constraint(equalTo: view.topAnchor),
            summaryContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summaryContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            summaryIcon.centerXAnchor.constraint(equalTo: summaryContainer.centerXAnchor),
            summaryIcon.centerYAnchor.constraint(equalTo: summaryContainer.centerYAnchor, constant: -50),
            summaryIcon.widthAnchor.constraint(equalToConstant: 48),
            summaryIcon.heightAnchor.constraint(equalToConstant: 48),
            summaryTitle.topAnchor.constraint(equalTo: summaryIcon.bottomAnchor, constant: 12),
            summaryTitle.centerXAnchor.constraint(equalTo: summaryContainer.centerXAnchor),
            summaryList.topAnchor.constraint(equalTo: summaryTitle.bottomAnchor, constant: 10),
            summaryList.centerXAnchor.constraint(equalTo: summaryContainer.centerXAnchor),
            summaryList.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
    }

    // MARK: - Display

    func display(thread headers: [EmailHeader], subject: String) {
        emptyContainer.isHidden = true
        summaryContainer.isHidden = true
        subjectLabel.isHidden = false
        scrollView.isHidden = false

        subjectLabel.stringValue = subject

        // Clear old cards
        cards.forEach { $0.view.removeFromSuperview() }
        cards.removeAll()

        // Create cards — newest is last in array (sorted date ASC)
        let lastIndex = headers.count - 1
        for (index, header) in headers.enumerated() {
            let shouldExpand = index == lastIndex || !header.isRead
            let card = MessageCardView(header: header, isExpanded: shouldExpand, accountEmail: accountEmail)

            card.onToggleExpand = { [weak self, weak card] in
                guard let card else { return }
                let newState = !card.isExpanded
                card.setExpanded(newState)
                if newState && card.cachedBody == nil {
                    self?.onFetchBody?(header.id)
                }
            }
            card.onReply = { [weak self] h, b in self?.onReply?(h, b) }
            card.onForward = { [weak self] h, b in self?.onForward?(h, b) }
            card.onArchive = { [weak self] id in self?.onArchive?(id) }
            card.onDelete = { [weak self] id in self?.onDelete?(id) }
            card.onMove = { [weak self] id, f in self?.onMove?(id, f) }
            card.onDownloadAttachment = { [weak self] att in self?.onDownloadAttachment?(header.id, att) }
            card.availableFolders = availableFolders

            card.view.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(card.view)
            card.view.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true

            // Request body for auto-expanded cards
            if shouldExpand {
                card.showLoading()
                onFetchBody?(header.id)
            }

            cards.append(card)
        }
    }

    func clear() {
        cards.forEach { $0.view.removeFromSuperview() }
        cards.removeAll()
        showEmpty()
    }

    private func showEmpty() {
        emptyContainer.isHidden = false
        summaryContainer.isHidden = true
        subjectLabel.isHidden = true
        scrollView.isHidden = true
    }

    func showBulkSummary(headers: [EmailHeader]) {
        let count = headers.count
        summaryTitle.stringValue = "\(count) conversation\(count == 1 ? "" : "s") selected"

        let preview = headers.prefix(5).map { h -> String in
            let sender = h.senderName ?? h.senderEmail
            let subject = h.subject ?? "(no subject)"
            return "\(sender) — \(subject)"
        }.joined(separator: "\n")
        summaryList.stringValue = preview

        summaryContainer.isHidden = false
        emptyContainer.isHidden = true
        subjectLabel.isHidden = true
        scrollView.isHidden = true
    }

    func hideBulkSummary() {
        summaryContainer.isHidden = true
    }

    /// Deliver a fetched body to the card displaying the given email id.
    func deliverBody(_ body: EmailBody?, forEmailId emailId: Int64, attachments: [AttachmentInfo] = []) {
        for card in cards where card.emailId == emailId {
            card.displayBody(body)
            card.displayAttachments(attachments)
            return
        }
    }
}
