import AppKit

/// Grouped section frame for the VM settings form.
///
/// Renders an inset rounded background with a header row that supports
/// an optional lock icon for sections that disable while the VM is
/// running, plus an optional trailing info button that reveals
/// per-section help text in a popover.
@MainActor
final class SettingsSection: NSStackView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let lockIcon = NSImageView()
    private let bodyContainer = NSStackView()
    private let backgroundView = NSView()
    private let header = NSStackView()
    private var infoButton: InfoButton?

    init(title: String, lockable: Bool = false) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .secondaryLabelColor

        lockIcon.image = .systemSymbol("lock.fill", accessibilityDescription: "Locked while the VM is running")
        lockIcon.contentTintColor = .systemOrange
        lockIcon.imageScaling = .scaleProportionallyUpOrDown
        lockIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            lockIcon.widthAnchor.constraint(equalToConstant: 12),
            lockIcon.heightAnchor.constraint(equalToConstant: 12),
        ])
        lockIcon.toolTip = "Locked while the VM is running"
        lockIcon.isHidden = true
        if !lockable {
            lockIcon.removeFromSuperview()
        }

        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        let initial: [NSView] = lockable ? [lockIcon, titleLabel] : [titleLabel]
        header.setViews(initial, in: .leading)

        bodyContainer.orientation = .vertical
        bodyContainer.alignment = .leading
        bodyContainer.spacing = 8
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        backgroundView.layer?.borderColor = NSColor.separatorColor.cgColor
        backgroundView.layer?.borderWidth = 1
        backgroundView.layer?.cornerRadius = 8
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.addSubview(bodyContainer)
        NSLayoutConstraint.activate([
            bodyContainer.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 12),
            bodyContainer.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 12),
            bodyContainer.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -12),
            bodyContainer.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -12),
        ])

        setViews([header, backgroundView], in: .leading)
        // RATIONALE: NSStackView's `.leading` alignment only pins cross-axis
        // edges; it does not stretch arranged subviews to fill the stack's
        // width like SwiftUI's VStack does. Without these explicit width
        // pins the header and rounded background collapse to their intrinsic
        // content widths and the section appears squashed against the
        // leading edge of the detail pane.
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: widthAnchor),
            backgroundView.widthAnchor.constraint(equalTo: widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsSection does not support NSCoder")
    }

    /// Show or hide the lock icon next to the title.
    func setLocked(_ locked: Bool) {
        lockIcon.isHidden = !locked
    }

    /// Attach an info button after the title that presents `build()` in a
    /// popover when clicked.
    ///
    /// Re-calling replaces the existing button so callers can swap help
    /// content per guest OS without leaking views.
    func setInfoHelp(title: String, build: @escaping () -> NSView) {
        if let existing = infoButton {
            header.removeArrangedSubview(existing)
            existing.removeFromSuperview()
        }
        let button = InfoButton(label: title, contentBuilder: build)
        header.addArrangedSubview(button)
        infoButton = button
    }

    /// Replace the section body with the given view.
    ///
    /// Convenience for sections that own a single composite body view; the
    /// previous body is removed.
    func setBody(_ view: NSView) {
        for sub in bodyContainer.arrangedSubviews {
            sub.removeFromSuperview()
        }
        bodyContainer.addArrangedSubview(view)
        pinRowWidth(view)
    }

    /// Append a row to the section body.
    func addRow(_ view: NSView) {
        bodyContainer.addArrangedSubview(view)
        pinRowWidth(view)
    }

    /// Remove all rows from the section body.
    func removeAllRows() {
        for sub in bodyContainer.arrangedSubviews {
            sub.removeFromSuperview()
        }
    }

    /// Force the row to fill the body container's full cross-axis width.
    ///
    /// Same NSStackView caveat as in `init` — `.leading` alignment does not
    /// stretch arranged subviews. Without this pin, the trailing
    /// `settingsSpacer()` in label/value rows has no surplus width to
    /// consume and the value collapses next to its label.
    private func pinRowWidth(_ view: NSView) {
        view.widthAnchor.constraint(equalTo: bodyContainer.widthAnchor).isActive = true
    }
}

/// Builds a horizontal row with a leading label and trailing control.
@MainActor
func makeLabeledRow(_ label: String, control: NSView) -> NSStackView {
    let labelView = NSTextField(labelWithString: label)
    labelView.font = .systemFont(ofSize: NSFont.systemFontSize)
    labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)

    let row = NSStackView(views: [labelView, settingsSpacer(), control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
}

/// Vertical stack used for grouping the rows of a settings-section body.
@MainActor
func settingsStackRows(_ views: [NSView]) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    return stack
}

/// Horizontal stack with `.centerY` alignment — for button rows, label +
/// stepper pairs, and other inline groupings.
@MainActor
func settingsHorizontalStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = spacing
    return stack
}

/// Flexible-width spacer for pushing trailing content rightwards inside a
/// horizontal stack.
@MainActor
func settingsSpacer() -> NSView {
    let v = NSView()
    v.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return v
}
