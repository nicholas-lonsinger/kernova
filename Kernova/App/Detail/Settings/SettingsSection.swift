import AppKit

/// Grouped section frame for the VM settings form.
///
/// Renders an inset rounded background with a header row that supports
/// an optional lock icon for sections that disable while the VM is
/// running, plus an optional trailing info button that reveals
/// per-section help text in a popover.
///
/// The section is pure chrome: title + body card. Each section coordinator
/// installs its own body view via ``setBody(_:)``. The body is typically
/// an ``NSGridView`` built with ``makeFormGrid(_:)`` for form-style
/// sections (label/control pairs) or a vertical ``NSStackView`` for
/// list-style sections (Storage Disks, Removable Media, Shared
/// Directories).
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
        // width like SwiftUI's VStack does. The body card must fill the
        // section's width so the grid/list inside it has room to lay out;
        // the header hugs its content on the leading edge (title + optional
        // lock + optional info button cluster).
        NSLayoutConstraint.activate([
            backgroundView.widthAnchor.constraint(equalTo: widthAnchor)
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
    func setBody(_ view: NSView) {
        for sub in bodyContainer.arrangedSubviews {
            sub.removeFromSuperview()
        }
        bodyContainer.addArrangedSubview(view)
        pinBodyWidth(view)
    }

    /// Force the body view to fill the body container's full cross-axis
    /// width.
    ///
    /// Same NSStackView caveat as in `init` — `.leading` alignment does not
    /// stretch arranged subviews. Without this pin, list-section rows
    /// collapse to their intrinsic width and AttachmentRowView's trailing
    /// toggle/remove controls float into the middle of the card.
    private func pinBodyWidth(_ view: NSView) {
        view.widthAnchor.constraint(equalTo: bodyContainer.widthAnchor).isActive = true
    }
}

// MARK: - Form body helper

/// A single row in a settings form grid.
///
/// `info` is optional per-row popover content. When non-nil, the label
/// cell becomes `[NSTextField, InfoButton]` packed at 4pt spacing —
/// used today only by ``GuestAgentSettingsSection``'s two toggles, but
/// the capability is mixed (section-level + per-row) so any future row
/// can opt in.
struct FormRow {
    let label: String
    let control: NSView
    let info: (() -> NSView)?

    init(_ label: String, control: NSView, info: (() -> NSView)? = nil) {
        self.label = label
        self.control = control
        self.info = info
    }
}

/// Centering wrapper around a two-column form grid, returned by ``makeFormGrid(_:)``.
///
/// Hosts the inner `NSGridView` and centers it horizontally inside
/// itself. When pinned to the section card's body width by
/// ``SettingsSection.setBody(_:)``, the grid sits at its natural width
/// (sized to widest label + spacing + widest control) in the middle of
/// the card. Callers that need to manipulate individual rows (e.g. hide
/// the MAC Address row when no value is available) reach in via
/// ``grid``.
@MainActor
final class FormGridContainer: NSView {
    /// The inner `NSGridView` whose rows correspond 1:1 with the
    /// `FormRow` array passed to ``makeFormGrid(_:)``.
    let grid: NSGridView

    init(grid: NSGridView) {
        self.grid = grid
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
            grid.centerXAnchor.constraint(equalTo: centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FormGridContainer does not support NSCoder")
    }
}

/// Build a centering wrapper around a two-column `NSGridView` of label/control pairs.
///
/// Right-aligned labels in column 0, left-aligned controls in column 1.
/// The returned ``FormGridContainer`` centers the grid horizontally,
/// giving the macOS System Settings look: labels and controls cluster
/// around the card's centerX with empty space on both sides, rather than
/// spreading across the full width or hugging one edge.
///
/// Mirrors the column placement settings from the existing wizard grids
/// at `ResourceConfigStepViewController.swift:66` and
/// `ReviewStepViewController.swift:6`.
@MainActor
func makeFormGrid(_ rows: [FormRow]) -> FormGridContainer {
    let grid = NSGridView(numberOfColumns: 2, rows: 0)
    grid.columnSpacing = 12
    grid.rowSpacing = 8
    grid.translatesAutoresizingMaskIntoConstraints = false

    for row in rows {
        let labelText = NSTextField(labelWithString: row.label)
        labelText.font = .systemFont(ofSize: NSFont.systemFontSize)

        let labelCell: NSView
        if let info = row.info {
            let infoBtn = InfoButton(label: row.label, contentBuilder: info)
            let pair = NSStackView(views: [labelText, infoBtn])
            pair.orientation = .horizontal
            pair.alignment = .centerY
            pair.spacing = 4
            labelCell = pair
        } else {
            labelCell = labelText
        }

        grid.addRow(with: [labelCell, row.control])
    }

    if let col0 = grid.column(at: 0) as NSGridColumn? {
        col0.xPlacement = .trailing
    }
    if grid.numberOfColumns > 1, let col1 = grid.column(at: 1) as NSGridColumn? {
        col1.xPlacement = .leading
    }

    return FormGridContainer(grid: grid)
}

// MARK: - Layout helpers used by list sections

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
