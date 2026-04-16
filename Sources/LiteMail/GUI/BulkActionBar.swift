import AppKit

/// Contextual toolbar that appears when one or more message checkboxes are checked.
/// Matches DetailView's action bar style: SF Symbol icons, 12pt labels, 36px height.
final class BulkActionBar: NSView {

    // MARK: - Subviews

    private let countLabel = NSTextField(labelWithString: "")
    private let selectAllButton: NSButton
    private let deselectButton: NSButton
    private let stackView: NSStackView
    private let topBorder = NSBox()

    // Action buttons
    private let archiveButton: CursorButton
    private let deleteButton: CursorButton
    private let markReadButton: CursorButton
    private let starButton: CursorButton
    private let moveButton: CursorButton

    // MARK: - Callbacks

    var onArchive: (() -> Void)?
    var onDelete: (() -> Void)?
    var onMarkRead: (() -> Void)?
    var onStar: (() -> Void)?
    var onMove: (() -> Void)?
    var onDeselectAll: (() -> Void)?
    var onSelectAll: (() -> Void)?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        // "N selected" label
        countLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        countLabel.textColor = .labelColor
        countLabel.setContentHuggingPriority(.required, for: .horizontal)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // "Select All" / "Deselect All" link buttons
        selectAllButton = NSButton(title: "Select All", target: nil, action: nil)
        selectAllButton.bezelStyle = .inline
        selectAllButton.isBordered = false
        selectAllButton.font = .systemFont(ofSize: 11)
        selectAllButton.contentTintColor = .linkColor
        selectAllButton.setContentHuggingPriority(.required, for: .horizontal)

        deselectButton = NSButton(title: "Deselect All", target: nil, action: nil)
        deselectButton.bezelStyle = .inline
        deselectButton.isBordered = false
        deselectButton.font = .systemFont(ofSize: 11)
        deselectButton.contentTintColor = .linkColor
        deselectButton.setContentHuggingPriority(.required, for: .horizontal)

        // Action buttons — SF Symbols, toolbar style matching DetailView
        func makeButton(_ symbolName: String, _ description: String) -> CursorButton {
            let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)!
            let btn = CursorButton(image: img, target: nil, action: nil)
            btn.bezelStyle = .accessoryBarAction
            btn.isBordered = false
            btn.contentTintColor = .labelColor
            btn.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                btn.widthAnchor.constraint(equalToConstant: 28),
                btn.heightAnchor.constraint(equalToConstant: 28),
            ])
            return btn
        }

        archiveButton  = makeButton("archivebox",   "Archive")
        deleteButton   = makeButton("trash",        "Delete")
        markReadButton = makeButton("envelope.open", "Mark as Read")
        starButton     = makeButton("star",         "Star")
        moveButton     = makeButton("folder",       "Move to Folder")

        // Spacer that pushes action buttons to the right
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Horizontal stack: [countLabel] [selectAll] [deselectAll] [spacer] [archive] [delete] [read] [star] [move]
        stackView = NSStackView(views: [
            countLabel,
            selectAllButton,
            deselectButton,
            spacer,
            archiveButton,
            deleteButton,
            markReadButton,
            starButton,
            moveButton,
        ])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Top border — matches NSBox separator style used elsewhere in the app
        topBorder.boxType = .separator
        topBorder.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: frameRect)

        addSubview(topBorder)
        addSubview(stackView)

        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),

            stackView.topAnchor.constraint(equalTo: topBorder.bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Height is controlled externally by MessageListView's bulkBarHeightConstraint
        ])

        // Wire button targets
        archiveButton.target  = self;  archiveButton.action  = #selector(archiveTapped)
        deleteButton.target   = self;  deleteButton.action   = #selector(deleteTapped)
        markReadButton.target = self;  markReadButton.action = #selector(markReadTapped)
        starButton.target     = self;  starButton.action     = #selector(starTapped)
        moveButton.target     = self;  moveButton.action     = #selector(moveTapped)
        selectAllButton.target = self;  selectAllButton.action = #selector(selectAllTapped)
        deselectButton.target = self;  deselectButton.action = #selector(deselectAllTapped)

        // Initially hidden
        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    /// Show or hide the bar based on `selectedCount`, animating alpha.
    /// `totalCount` is the total visible emails (for "Select All (N)" label).
    func update(selectedCount: Int, totalCount: Int = 0) {
        countLabel.stringValue = "\(selectedCount) selected"
        if totalCount > 0 && selectedCount < totalCount {
            selectAllButton.title = "Select All (\(totalCount))"
            selectAllButton.isHidden = false
        } else {
            selectAllButton.isHidden = true
        }

        if selectedCount >= 1 {
            guard isHidden || alphaValue < 1 else { return }
            isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                animator().alphaValue = 1
            }
        } else {
            guard !isHidden else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.isHidden = true
            })
        }
    }

    // MARK: - Actions

    @objc private func archiveTapped()    { onArchive?() }
    @objc private func deleteTapped()     { onDelete?() }
    @objc private func markReadTapped()   { onMarkRead?() }
    @objc private func starTapped()       { onStar?() }
    @objc private func moveTapped()       { onMove?() }
    @objc private func selectAllTapped()   { onSelectAll?() }
    @objc private func deselectAllTapped(){ onDeselectAll?() }
}
