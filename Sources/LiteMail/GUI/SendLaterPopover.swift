import AppKit

/// Popover shown from the "Send Later" button in the composer.
/// Provides quick-pick options and a custom date/time picker.
final class SendLaterPopover: NSObject {

    private let popover = NSPopover()
    private let viewController = SendLaterViewController()

    /// Called with the chosen send date when the user confirms.
    var onSchedule: ((Date) -> Void)?

    override init() {
        super.init()
        popover.contentViewController = viewController
        popover.behavior = .semitransient
        viewController.onSchedule = { [weak self] date in
            self?.popover.close()
            self?.onSchedule?(date)
        }
    }

    func show(relativeTo view: NSView) {
        if popover.isShown { popover.close(); return }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

// MARK: - SendLaterViewController

private final class SendLaterViewController: NSViewController {

    var onSchedule: ((Date) -> Void)?
    private let datePicker = NSDatePicker()

    // Dates for quick-pick buttons, indexed by button tag
    private var quickPickDates: [Date] = []

    override func loadView() {
        let cal = Calendar.current
        let now = Date()

        quickPickDates = [
            Self.tonight7pm(cal: cal, now: now),
            Self.tomorrow8am(cal: cal, now: now),
            Self.nextMonday8am(cal: cal, now: now),
        ]
        let titles = ["Tonight 7 PM", "Tomorrow 8 AM", "Next Monday 8 AM"]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, title) in titles.enumerated() {
            let btn = NSButton(title: title, target: self, action: #selector(quickPickTapped(_:)))
            btn.bezelStyle = .recessed
            btn.isBordered = false
            btn.font = .systemFont(ofSize: 13)
            btn.contentTintColor = .linkColor
            btn.tag = index
            btn.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(btn)
        }

        let sep = NSBox()
        sep.boxType = .separator

        let pickLabel = NSTextField(labelWithString: "Custom:")
        pickLabel.font = .systemFont(ofSize: 11)
        pickLabel.textColor = .secondaryLabelColor

        datePicker.datePickerStyle = .textFieldAndStepper
        datePicker.datePickerElements = [.yearMonthDay, .hourMinute]
        datePicker.minDate = now
        datePicker.dateValue = now.addingTimeInterval(3600)

        let scheduleBtn = CursorButton(title: "Schedule", target: self, action: #selector(scheduleCustomTapped))
        scheduleBtn.bezelStyle = .rounded

        let customRow = NSStackView(views: [datePicker, scheduleBtn])
        customRow.spacing = 8
        customRow.alignment = .centerY

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 170))
        for v in [stack, sep, pickLabel, customRow] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            sep.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 8),
            sep.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            sep.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),

            pickLabel.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 8),
            pickLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),

            customRow.topAnchor.constraint(equalTo: pickLabel.bottomAnchor, constant: 4),
            customRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            customRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            customRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        view = container
    }

    @objc private func quickPickTapped(_ sender: NSButton) {
        guard sender.tag < quickPickDates.count else { return }
        onSchedule?(quickPickDates[sender.tag])
    }

    @objc private func scheduleCustomTapped() {
        onSchedule?(datePicker.dateValue)
    }

    // MARK: - Date helpers

    private static func tonight7pm(cal: Calendar, now: Date) -> Date {
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = 19; comps.minute = 0; comps.second = 0
        let candidate = cal.date(from: comps) ?? now.addingTimeInterval(3600)
        return candidate > now ? candidate : cal.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }

    private static func tomorrow8am(cal: Calendar, now: Date) -> Date {
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = 8; comps.minute = 0; comps.second = 0
        let today8am = cal.date(from: comps) ?? now
        return cal.date(byAdding: .day, value: 1, to: today8am) ?? today8am
    }

    private static func nextMonday8am(cal: Calendar, now: Date) -> Date {
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = 8; comps.minute = 0; comps.second = 0
        let today8am = cal.date(from: comps) ?? now
        // weekday: 1=Sun, 2=Mon … 7=Sat
        let weekday = cal.component(.weekday, from: now)
        let daysUntilMon = (9 - weekday) % 7
        let daysToAdd = daysUntilMon == 0 ? 7 : daysUntilMon
        return cal.date(byAdding: .day, value: daysToAdd, to: today8am) ?? today8am
    }
}
