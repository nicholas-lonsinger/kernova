import AppKit

/// Leaf-row cell for a single virtual machine in the sidebar.
///
/// The cell owns a per-instance ``ObservationLoop`` so it repaints itself when
/// its bound VM's observable state changes; it is replaced on every `configure`
/// and torn down in ``prepareForReuse()``. Both closures capture `self` weakly
/// and read the instance through `self.instance`, so a deleted VM is never kept
/// alive.
///
/// Inline rename reuses the name label: the controller opens the box with
/// ``beginRename()`` and ends it with ``endRename()``, and the shared
/// ``InlineEditableLabel`` commits on Return/focus-loss and cancels on Escape.
@MainActor
final class SidebarVMRowCellView: NSTableCellView {
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
    /// Reads this row's busy state, live: the cell's own observation loop calls
    /// it, so every observable read inside it wakes the row — including the
    /// lifecycle operation no ``VMStatus`` case represents.
    private var isBusy: (() -> Bool)?

    /// `true` while the name label is in its editable rename state.
    var isRenaming: Bool { nameLabel.isEditing }

    // MARK: - Subviews

    private let iconView = NSImageView()
    /// The row's name, and the rename box it becomes.
    ///
    /// Clicks belong to the enclosing outline view: it arms the slow-second
    /// click itself and does its own selection and drag tracking.
    private let nameLabel = InlineEditableLabel(
        text: "", font: Typography.body, textColor: .labelColor, placeholder: "",
        controlsEnabled: true, clickHandling: .delegatedToEnclosingView)
    private let ephemeralBadge = SidebarEphemeralBadgeView()
    private let agentButton = SidebarAgentStatusButtonView()
    private let spinner = NSProgressIndicator()
    /// A flexible filler trailing the name so the name label can hug its text
    /// while renaming; inert in the display state.
    private let nameSpacer = NSView()

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

        // The label hugs its own text by default, which would shrink the display
        // name to a hit region narrower than the name area a slow second click
        // arms the rename from. Filling the row instead — with `nameSpacer`
        // hugging one step harder — is what `isPointOverName` measures against.
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.currentText = { [weak self] in self?.instance?.name }
        nameLabel.onEditCommitted = { [weak self] newName, endedByReturn in
            self?.onCommitRename?(newName, endedByReturn)
        }
        nameLabel.onEditCancelled = { [weak self] in self?.onCancelRename?() }

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

        // Keep the trailing accessories rigid so the name field is the sole
        // flexible element, truncating only when genuinely out of room.
        for accessory in [ephemeralBadge, agentButton] as [NSView] {
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        ephemeralBadge.isHidden = true

        // The icon and spinner share the leading slot: exactly one is visible at a
        // time, and both are pinned to the same width so the name field doesn't
        // shift when they swap. The agent badge stays outermost — it is the one
        // that asks for action, where the ephemeral badge only states a policy.
        let row = NSStackView(views: [
            iconView, spinner, nameLabel, nameSpacer, ephemeralBadge, agentButton,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Spacing.small
        // No gap between the name and its filler.
        row.setCustomSpacing(0, after: nameLabel)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        // The icon is deliberately not wired to `imageView`: its state color is
        // baked into a non-template symbol image, so the source list's selection
        // vibrancy leaves it alone instead of drawing it white.
        textField = nameLabel

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
        isBusy: @escaping () -> Bool,
        onCommitRename: @escaping (String, Bool) -> Void,
        onCancelRename: @escaping () -> Void,
        onMountAgent: @escaping () -> Void,
        onDismissAgentNudge: @escaping () -> Void
    ) {
        let isRebindToDifferentVM = self.instance !== instance
        self.instance = instance
        self.installPromptDisabled = installPromptDisabled
        self.isBusy = isBusy
        self.onCommitRename = onCommitRename
        self.onCancelRename = onCancelRename

        // A recycled cell may still show the previous VM's open popovers; close
        // them on rebind so an action can't fire against the new VM.
        if isRebindToDifferentVM {
            agentButton.reset()
            ephemeralBadge.reset()
        }
        agentButton.onMount = onMountAgent
        agentButton.onDismiss = onDismissAgentNudge

        applyLiveState()
        // Re-applied on reconfigure, so a reload mid-rename keeps the box open.
        // A recycled row's edit is abandoned rather than committed: its typed
        // text belongs to the VM the cell used to show.
        if isRenaming {
            nameLabel.beginEditing()
        } else {
            nameLabel.abandonEditing()
        }

        rowObservation?.cancel()
        rowObservation = observeRecurring(
            track: { [weak self] in
                guard let self, let instance = self.instance else { return }
                _ = instance.name
                _ = instance.configuration.guestOS
                _ = instance.status
                _ = instance.isPreparing
                // Keeps the two reads above as well: `isBusy` short-circuits, so
                // it registers the lifecycle term only while the others are
                // false, and the tooltip and icon color need `status` anyway.
                _ = self.isBusy?()
                _ = instance.hasLiveVirtualMachine
                _ = instance.statusToolTip
                _ = instance.statusDisplayNSColor
                _ = instance.agentStatus
                _ = instance.setupState
                _ = instance.configuration.agentInstallNudgeDismissed
                _ = instance.configuration.lastSeenAgentVersion
                _ = instance.configuration.ephemeralModeEnabled
            },
            apply: { [weak self] in
                self?.applyLiveState()
            }
        )
    }

    private func applyLiveState() {
        guard let instance else { return }

        // Self-guards mid-rename, leaving the open box's text alone.
        nameLabel.update(text: instance.name, controlsEnabled: true)

        let busy = isBusy?() ?? false
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

        let showsEphemeral = instance.configuration.ephemeralModeEnabled
        if !showsEphemeral { ephemeralBadge.reset() }
        ephemeralBadge.isHidden = !showsEphemeral

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
        // Convert into the name label's own space — its `frame` is relative to the
        // inset row stack, not the cell, so comparing directly never matches.
        guard !nameLabel.isHidden else { return false }
        return nameLabel.bounds.contains(nameLabel.convert(point, from: self))
    }

    /// Opens the rename box on this row.
    func beginRename() {
        nameLabel.beginEditing()
    }

    /// Ends a live rename through the commit path, so the in-flight text lands.
    func endRename() {
        nameLabel.endEditing()
    }

    // MARK: - Reuse

    override func prepareForReuse() {
        super.prepareForReuse()
        rowObservation?.cancel()
        rowObservation = nil
        // Silently: a recycled row's typed name belongs to the VM it used to
        // show, so committing it here would rename that VM behind the user.
        nameLabel.abandonEditing()
        instance = nil
        onCommitRename = nil
        onCancelRename = nil
        isBusy = nil
        spinner.stopAnimation(nil)
        // Close any popover, stop the agent spinner, and drop the closures —
        // they capture the bound VMInstance and would otherwise keep it alive.
        agentButton.reset()
        agentButton.onMount = nil
        agentButton.onDismiss = nil
        agentButton.isHidden = true
        ephemeralBadge.reset()
        ephemeralBadge.isHidden = true
    }

    // MARK: - Intrinsic width

    /// The cell content width — excluding the outline view's per-row indentation,
    /// which the caller adds — at which `name` stops truncating.
    static func contentWidth(
        forName name: String, showsAgentAccessory: Bool, showsEphemeralAccessory: Bool
    ) -> CGFloat {
        let nameWidth = ceil(measuredNameWidth(for: name))
        var width =
            Self.rowLeadingInset + Self.iconSlotWidth + Spacing.small + nameWidth
            + Self.rowTrailingInset
        if showsEphemeralAccessory {
            width += Spacing.small + SidebarEphemeralBadgeView.width
        }
        if showsAgentAccessory {
            width += Spacing.small + SidebarAgentStatusButtonView.width
        }
        return width
    }

    /// A borderless field configured like the row's `nameLabel`, reused to
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
