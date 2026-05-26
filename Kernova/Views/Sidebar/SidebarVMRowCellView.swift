import AppKit

/// Leaf-row cell for a single virtual machine in the sidebar.
///
/// A guest-OS icon tinted to the VM's state color, the VM name, and an optional
/// guest-agent accessory. While the VM is preparing or transitioning the icon is
/// swapped in place for a spinner.
///
/// The cell owns a per-instance ``ObservationLoop`` so it repaints itself when
/// its bound VM's observable state changes (status, name, agent status), the
/// AppKit analogue of SwiftUI re-rendering the row. The loop is replaced on
/// every ``configure(instance:isRenaming:onCommitRename:onCancelRename:onMountAgent:onDismissAgentNudge:)``
/// and torn down in ``prepareForReuse()``; both closures capture `self` weakly
/// and read the instance through `self.instance` so a deleted VM is never kept
/// alive.
///
/// Inline rename reuses the name field: the controller flips the row into
/// editing via ``setRenaming(_:)`` and the cell, acting as the field's
/// delegate, commits on Return/focus-loss and cancels on Escape.
@MainActor
final class SidebarVMRowCellView: NSTableCellView, NSTextFieldDelegate {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarVMRowCell")

    private weak var instance: VMInstance?
    private var rowObservation: ObservationLoop?
    private var onCommitRename: ((String) -> Void)?
    private var onCancelRename: (() -> Void)?

    /// `true` while the name field is in its editable rename state.
    private(set) var isRenaming = false

    /// Suppresses the commit path while an Escape-driven cancel tears down the
    /// field editor (ending editing would otherwise also fire a commit).
    private var isCancellingRename = false

    // MARK: - Subviews

    private let iconView = NSImageView()
    private let nameField = NSTextField()
    private let agentButton = SidebarAgentStatusButtonView()
    private let spinner = NSProgressIndicator()

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarVMRowCellView does not support NSCoder")
    }

    private func buildLayout() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.font = Typography.body
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.cell?.usesSingleLineMode = true
        nameField.delegate = self
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        spinner.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Keep the trailing accessory rigid so the name field is the sole
        // flexible element: it claims all spare width and truncates only when
        // genuinely out of room.
        agentButton.setContentHuggingPriority(.required, for: .horizontal)
        agentButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // The icon and spinner share the leading slot: exactly one is visible at
        // a time, so the stack collapses the hidden one and the visible view
        // owns that position. Both are pinned to the same 20pt width to keep the
        // name field from shifting when they swap.
        let row = NSStackView(views: [iconView, spinner, nameField, agentButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Spacing.small
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        // Auto-adjust the primary label for selection highlighting. The icon is
        // deliberately not wired to `imageView`; its state color is baked into a
        // non-template symbol image (see `applyIconStateColor()`) so the source
        // list's selection vibrancy leaves it alone instead of drawing it white.
        textField = nameField

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -2),

            iconView.widthAnchor.constraint(equalToConstant: 20),
            spinner.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    // MARK: - Configure

    func configure(
        instance: VMInstance,
        isRenaming: Bool,
        onCommitRename: @escaping (String) -> Void,
        onCancelRename: @escaping () -> Void,
        onMountAgent: @escaping () -> Void,
        onDismissAgentNudge: @escaping () -> Void
    ) {
        let isRebindToDifferentVM = self.instance !== instance
        self.instance = instance
        self.onCommitRename = onCommitRename
        self.onCancelRename = onCancelRename

        // A recycled cell may still show the previous VM's open agent popover;
        // close it on rebind so its action can't fire against the new VM.
        if isRebindToDifferentVM { agentButton.reset() }
        agentButton.onMount = onMountAgent
        agentButton.onDismiss = onDismissAgentNudge

        applyLiveState()
        setRenaming(isRenaming)

        rowObservation?.cancel()
        rowObservation = observeRecurring(
            track: { [weak self] in
                guard let self, let instance = self.instance else { return }
                _ = instance.name
                _ = instance.configuration.guestOS
                _ = instance.status
                _ = instance.isPreparing
                _ = instance.virtualMachine
                _ = instance.statusToolTip
                _ = instance.statusDisplayNSColor
                _ = instance.agentStatus
                _ = instance.installState
                _ = instance.configuration.agentInstallNudgeDismissed
                _ = instance.configuration.lastSeenAgentVersion
            },
            apply: { [weak self] in
                self?.applyLiveState()
            }
        )
    }

    private func applyLiveState() {
        guard let instance else { return }

        // Don't overwrite the field while the user is mid-rename.
        if !isRenaming {
            nameField.stringValue = instance.name
        }

        let busy = instance.isPreparing || instance.status.isTransitioning
        if busy {
            iconView.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            iconView.isHidden = false
            applyIconStateColor()
            iconView.toolTip = instance.statusToolTip
        }

        if let agentStatus = Self.visibleAgentStatus(for: instance) {
            agentButton.isHidden = false
            let dismissible = agentStatus == .waiting
            agentButton.configure(
                status: agentStatus, vmName: instance.name, hasDismissAction: dismissible
            )
        } else {
            // No badge for this state: hide it and dismiss any popover/spinner
            // left from a prior state so nothing lingers on the recycled view.
            agentButton.reset()
            agentButton.isHidden = true
        }
    }

    /// Renders the OS symbol in the VM's state color.
    ///
    /// The color is baked into the symbol via a palette configuration and the
    /// result is marked non-template. A plain template image tinted with
    /// `contentTintColor` would be drawn white by the source list's selection
    /// vibrancy when its row is highlighted; a non-template, pre-colored image
    /// is exempt, so the state color survives selection. The point size is
    /// folded into the same configuration so the glyph matches the spinner's
    /// visual weight (the SF Symbol default reads small beside it).
    private func applyIconStateColor() {
        guard let instance else { return }
        let guestOS = instance.configuration.guestOS
        let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [instance.statusDisplayNSColor]))
        let symbol = NSImage.systemSymbol(
            guestOS.iconName, accessibilityDescription: guestOS.displayName
        )
        let colored = symbol.withSymbolConfiguration(configuration) ?? symbol
        colored.isTemplate = false
        iconView.image = colored
    }

    /// Rebuilds the icon so its baked palette color re-resolves for the new
    /// light/dark appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard instance != nil, !iconView.isHidden else { return }
        applyIconStateColor()
    }

    // MARK: - Inline rename

    /// Flips the name field between display and editable states.
    ///
    /// Driven by the controller when `activeRename` enters/leaves
    /// `.sidebar(id)` for this row; also re-applied on reconfigure so a reload
    /// mid-rename keeps the field editable.
    func setRenaming(_ renaming: Bool) {
        guard renaming != isRenaming else { return }
        isRenaming = renaming

        if renaming {
            nameField.isEditable = true
            nameField.isSelectable = true
            nameField.isBordered = true
            nameField.bezelStyle = .roundedBezel
            nameField.drawsBackground = true
            if let instance { nameField.stringValue = instance.name }
            window?.makeFirstResponder(nameField)
            nameField.currentEditor()?.selectAll(nil)
        } else {
            nameField.isEditable = false
            nameField.isSelectable = false
            nameField.isBordered = false
            nameField.drawsBackground = false
            if let instance { nameField.stringValue = instance.name }
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isRenaming, !isCancellingRename else { return }
        let newName = nameField.stringValue
        setRenaming(false)
        onCommitRename?(newName)
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        isCancellingRename = true
        setRenaming(false)
        isCancellingRename = false
        onCancelRename?()
        return true
    }

    /// Re-establishes first-responder focus when a renaming cell joins a window.
    ///
    /// During `reloadData` the cell is configured (and `setRenaming` runs)
    /// before it's in the window hierarchy, so the `makeFirstResponder` there
    /// no-ops; this catches that case on attach.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard isRenaming, let window else { return }
        window.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        rowObservation?.cancel()
        rowObservation = nil
        setRenaming(false)
        instance = nil
        onCommitRename = nil
        onCancelRename = nil
        spinner.stopAnimation(nil)
        // Close any popover, stop the agent spinner, and drop the closures —
        // they capture the bound VMInstance and would otherwise keep it alive.
        agentButton.reset()
        agentButton.onMount = nil
        agentButton.onDismiss = nil
        agentButton.isHidden = true
    }

    // MARK: - Agent visibility

    /// The agent status to surface as a sidebar indicator, or `nil` to hide.
    ///
    /// Ported verbatim from the former SwiftUI `VMRowView`: hidden for Linux
    /// guests, during macOS install, when `.current`, when `.waiting` was
    /// dismissed, and when a stopped/cold-paused VM has previously seen an
    /// agent (so `.waiting` doesn't nag).
    static func visibleAgentStatus(for instance: VMInstance) -> AgentStatus? {
        guard instance.configuration.guestOS == .macOS else { return nil }
        guard instance.installState == nil else { return nil }
        let status = instance.agentStatus
        if case .current = status { return nil }
        if case .waiting = status, instance.configuration.agentInstallNudgeDismissed {
            return nil
        }
        let isLiveSession = instance.virtualMachine != nil
        if !isLiveSession, case .waiting = status,
            instance.configuration.lastSeenAgentVersion != nil
        {
            return nil
        }
        return status
    }
}
