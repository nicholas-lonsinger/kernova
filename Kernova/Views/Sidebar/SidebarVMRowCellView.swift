import AppKit

/// Leaf-row cell for a single virtual machine in the sidebar.
///
/// The cell owns a per-instance ``ObservationLoop`` so it repaints itself when
/// its bound VM's observable state changes; it is replaced on every `configure`
/// and torn down in ``prepareForReuse()``. Both closures capture `self` weakly
/// and read the instance through `self.instance`, so a deleted VM is never kept
/// alive.
///
/// Inline rename reuses the name field: the controller flips the row into editing
/// via ``setRenaming(_:)`` and the cell, acting as the field's delegate, commits
/// on Return/focus-loss and cancels on Escape.
@MainActor
final class SidebarVMRowCellView: NSTableCellView, NSTextFieldDelegate {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarVMRowCell")

    /// Layout metrics shared by `buildLayout()` and the snap-to-fit measurement,
    /// so the rendered row and the measurement can't drift apart.
    private static let rowLeadingInset: CGFloat = 4
    private static let rowTrailingInset: CGFloat = 8
    private static let iconSlotWidth: CGFloat = 20

    private weak var instance: VMInstance?
    /// The app-wide install-prompt suppression as of the last `configure`.
    ///
    /// Snapshotted rather than read live: it lives in `AppPreferences`, so the
    /// cell's own observation loop can't see it change — the controller reloads
    /// the rows off its `@Observable` mirror instead.
    private var installPromptDisabled = false
    private var rowObservation: ObservationLoop?
    /// Commits the edited name; the `Bool` is `true` when editing ended by Return,
    /// which decides whether the controller restores sidebar focus.
    private var onCommitRename: ((String, Bool) -> Void)?
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
    /// A flexible filler trailing the name so the name field can hug its text
    /// while renaming; inert in the display state.
    private let nameSpacer = NSView()
    /// Caps the name field at its text width while renaming so the box hugs it.
    ///
    /// A `<=` bound, *not* `==`, so a long name in a narrow sidebar fills the
    /// available width and scrolls rather than the box demanding room and
    /// stretching the window.
    private var nameEditMaxWidth: NSLayoutConstraint?

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
        nameField.cell?.isScrollable = true
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // The filler hugs slightly more eagerly than the name field, so the name
        // claims the spare width in the display state, and while renaming the
        // filler absorbs the slack instead of the box ballooning.
        nameSpacer.translatesAutoresizingMaskIntoConstraints = false
        nameSpacer.setContentHuggingPriority(.defaultLow + 1, for: .horizontal)
        nameSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        spinner.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Keep the trailing accessory rigid so the name field is the sole flexible
        // element, truncating only when genuinely out of room.
        agentButton.setContentHuggingPriority(.required, for: .horizontal)
        agentButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        // The icon and spinner share the leading slot: exactly one is visible at a
        // time, and both are pinned to the same width so the name field doesn't
        // shift when they swap.
        let row = NSStackView(views: [iconView, spinner, nameField, nameSpacer, agentButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Spacing.small
        // No gap between the name and its filler.
        row.setCustomSpacing(0, after: nameField)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        // Inactive here, so the name fills the row in its display state.
        let editMax = nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        editMax.priority = .defaultHigh
        nameEditMaxWidth = editMax

        // The icon is deliberately not wired to `imageView`: its state color is
        // baked into a non-template symbol image, so the source list's selection
        // vibrancy leaves it alone instead of drawing it white.
        textField = nameField

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.rowLeadingInset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.rowTrailingInset),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -2),

            iconView.widthAnchor.constraint(equalToConstant: Self.iconSlotWidth),
            spinner.widthAnchor.constraint(equalToConstant: Self.iconSlotWidth),
        ])
    }

    // MARK: - Configure

    func configure(
        instance: VMInstance,
        isRenaming: Bool,
        installPromptDisabled: Bool,
        onCommitRename: @escaping (String, Bool) -> Void,
        onCancelRename: @escaping () -> Void,
        onMountAgent: @escaping () -> Void,
        onDismissAgentNudge: @escaping () -> Void
    ) {
        let isRebindToDifferentVM = self.instance !== instance
        self.instance = instance
        self.installPromptDisabled = installPromptDisabled
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
                _ = instance.setupState
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

        if let agentStatus = Self.visibleAgentStatus(
            for: instance, installPromptDisabled: installPromptDisabled)
        {
            agentButton.isHidden = false
            let dismissible = agentStatus == .waiting
            agentButton.configure(
                status: agentStatus, vmName: instance.name, hasDismissAction: dismissible
            )
        } else {
            // Dismiss any popover/spinner left from a prior state so nothing
            // lingers on the recycled view.
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
    /// is exempt.
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

    /// `true` when `point` (in this cell's coordinate space) is over the editable
    /// name, so a slow-second-click rename starts only over the name itself.
    func isPointOverName(_ point: NSPoint) -> Bool {
        // Convert into the name field's own space — its `frame` is relative to the
        // inset row stack, not the cell, so comparing directly never matches.
        guard !nameField.isHidden else { return false }
        return nameField.bounds.contains(nameField.convert(point, from: self))
    }

    /// Flips the name field between display and editable states.
    ///
    /// Re-applied on reconfigure, so a reload mid-rename keeps the field editable.
    func setRenaming(_ renaming: Bool) {
        guard renaming != isRenaming else { return }
        isRenaming = renaming

        if renaming {
            nameField.isEditable = true
            nameField.isSelectable = true
            nameField.isBezeled = true
            nameField.drawsBackground = true
            if let instance { nameField.stringValue = instance.name }
            // Re-capped as the user types.
            updateRenameBoxWidth(for: nameField.stringValue)
            nameEditMaxWidth?.isActive = true
            window?.makeFirstResponder(nameField)
            // Re-seed after taking focus: the makeFirstResponder above can
            // synchronously commit the detail surface's pending rename, changing
            // the name after the seed above.
            if let instance, nameField.stringValue != instance.name {
                nameField.stringValue = instance.name
                nameField.currentEditor()?.string = instance.name
                updateRenameBoxWidth(for: instance.name)
            }
            nameField.currentEditor()?.selectAll(nil)
        } else {
            nameField.isEditable = false
            nameField.isSelectable = false
            nameField.isBordered = false
            nameField.isBezeled = false
            nameField.drawsBackground = false
            // Back to filling the row for the display label.
            nameEditMaxWidth?.isActive = false
            if let instance { nameField.stringValue = instance.name }
        }
    }

    /// Ends a live edit session through the normal commit path.
    ///
    /// Resigns the field editor while `isRenaming` is still set, so
    /// `controlTextDidEndEditing` commits the in-flight text. Callers must use
    /// this BEFORE `setRenaming(false)`, which flips the commit gate without
    /// resigning the editor — a later resign then silently drops the typed text.
    func commitActiveRenameSession() {
        guard isRenaming, nameField.currentEditor() != nil else { return }
        window?.makeFirstResponder(nil)
    }

    /// Caps the rename box at the width of `text` so it hugs the name.
    private func updateRenameBoxWidth(for text: String) {
        nameEditMaxWidth?.constant = InlineRenameSizing.boxWidth(for: text, font: Typography.body)
    }

    func controlTextDidChange(_ obj: Notification) {
        // Grow/shrink the box with the live text so it stays snug while typing.
        let live = nameField.currentEditor()?.string ?? nameField.stringValue
        updateRenameBoxWidth(for: live)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isRenaming, !isCancellingRename else { return }
        let newName = nameField.stringValue
        // Whether editing ended by Return (vs a click elsewhere): the controller
        // restores sidebar focus only for Return.
        let endedByReturn =
            (obj.userInfo?["NSTextMovement"] as? Int) == NSTextMovement.return.rawValue
        setRenaming(false)
        onCommitRename?(newName, endedByReturn)
    }

    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        isCancellingRename = true
        // Revert the live buffer and resign so the field editor actually tears
        // down — setting `isEditable = false` in `setRenaming(false)` alone leaves
        // it active, so the box would stay in its editing state.
        if let instance { nameField.currentEditor()?.string = instance.name }
        window?.makeFirstResponder(nil)
        setRenaming(false)
        isCancellingRename = false
        onCancelRename?()
        return true
    }

    /// Re-establishes first-responder focus when a renaming cell joins a window.
    ///
    /// During `reloadData` the cell is configured (and `setRenaming` runs) before
    /// it's in the window hierarchy, so the `makeFirstResponder` there no-ops.
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

    // MARK: - Intrinsic width

    /// The cell content width — excluding the outline view's per-row indentation,
    /// which the caller adds — at which `name` stops truncating.
    static func contentWidth(forName name: String, showsAgentAccessory: Bool) -> CGFloat {
        let nameWidth = ceil(measuredNameWidth(for: name))
        var width =
            Self.rowLeadingInset + Self.iconSlotWidth + Spacing.small + nameWidth
            + Self.rowTrailingInset
        if showsAgentAccessory {
            width += Spacing.small + SidebarAgentStatusButtonView.width
        }
        return width
    }

    /// A borderless field configured like the row's `nameField`, reused to
    /// measure label widths. Its `fittingSize` includes `NSTextField`'s internal
    /// text inset — which a bare `NSString.size(withAttributes:)` omits, leaving
    /// the snapped sidebar a few points too narrow and the name still truncated.
    private static let measuringNameField: NSTextField = {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.isEditable = false
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        return field
    }()

    /// Memoized name-to-width measurements for the sidebar snap-to-fit.
    ///
    /// The snap recomputes the fit width on every `constrainSplitPosition` call
    /// (many per second during a drag) over every VM, so caching the text-layout
    /// pass keeps that hot path off the layout engine. Cleared when the font
    /// changes, so it keeps tracking `Typography.body`.
    private static var nameWidthCache: [String: CGFloat] = [:]
    private static var nameWidthCacheFont: NSFont?

    private static func measuredNameWidth(for name: String) -> CGFloat {
        let font = Typography.body
        if font != nameWidthCacheFont {
            nameWidthCache.removeAll()
            nameWidthCacheFont = font
        }
        if let cached = nameWidthCache[name] { return cached }

        measuringNameField.font = font
        measuringNameField.stringValue = name
        let width = measuringNameField.fittingSize.width
        nameWidthCache[name] = width
        return width
    }

    // MARK: - Agent visibility

    /// The agent status to surface as a sidebar indicator, or `nil` to hide.
    ///
    /// Hidden for Linux guests, during macOS install, when `.current`, when
    /// `.waiting` was dismissed for this VM or turned off app-wide by
    /// `installPromptDisabled`, and — the outermost gate — whenever the VM has
    /// no live session: every state the badge renders is a statement about *this*
    /// session's control channel. On a stopped or cold-paused VM `agentStatus`
    /// degrades to `.waiting`, and the badge would report "guest agent not
    /// installed" for a VM whose agent state is unknown.
    static func visibleAgentStatus(
        for instance: VMInstance, installPromptDisabled: Bool
    ) -> AgentStatus? {
        guard instance.configuration.guestOS == .macOS else { return nil }
        guard instance.setupState == nil else { return nil }
        // Live-paused counts: the VM is still in memory and resumable, so the
        // badge shouldn't blink out and back when the user pauses. Cold-paused
        // (paused to disk, nothing in memory) does not.
        guard instance.status == .running || instance.isLivePaused else { return nil }
        let status = instance.agentStatus
        if case .current = status { return nil }
        if case .waiting = status,
            installPromptDisabled || instance.configuration.agentInstallNudgeDismissed
        {
            return nil
        }
        return status
    }
}
