import AppKit

/// Grouped section frame for the VM settings form.
///
/// Renders the inset rounded background that SwiftUI's
/// `.formStyle(.grouped)` provides, with a header row that supports an
/// optional lock icon for sections that disable while the VM is running.
@MainActor
final class SettingsSection: NSStackView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let lockIcon = NSImageView()
    private let bodyContainer = NSStackView()
    private let backgroundView = NSView()

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

        let header = NSStackView(views: lockable ? [lockIcon, titleLabel] : [titleLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)

        bodyContainer.orientation = .vertical
        bodyContainer.alignment = .leading
        bodyContainer.spacing = 8
        bodyContainer.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false

        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        backgroundView.layer?.borderColor = NSColor.separatorColor.cgColor
        backgroundView.layer?.borderWidth = 1
        backgroundView.layer?.cornerRadius = 8
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.addFullSizeSubview(bodyContainer)

        setViews([header, backgroundView], in: .leading)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsSection does not support NSCoder")
    }

    /// Show or hide the lock icon next to the title.
    func setLocked(_ locked: Bool) {
        lockIcon.isHidden = !locked
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
    }

    /// Append a row to the section body.
    func addRow(_ view: NSView) {
        bodyContainer.addArrangedSubview(view)
    }

    /// Remove all rows from the section body.
    func removeAllRows() {
        for sub in bodyContainer.arrangedSubviews {
            sub.removeFromSuperview()
        }
    }
}

/// Builds a horizontal row with a leading label and trailing control,
/// matching SwiftUI's `LabeledContent` layout.
@MainActor
func makeLabeledRow(_ label: String, control: NSView) -> NSStackView {
    let labelView = NSTextField(labelWithString: label)
    labelView.font = .systemFont(ofSize: NSFont.systemFontSize)
    labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let row = NSStackView(views: [labelView, spacer, control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    return row
}
