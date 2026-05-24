import AppKit

/// Leaf-row cell for a single virtual machine in the sidebar.
///
/// Mirrors the former SwiftUI `VMRowView`: a guest-OS icon, the VM name over
/// its OS subtitle, an optional guest-agent accessory, and a trailing status
/// dot that swaps to a spinner while the VM is preparing or transitioning.
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
    private let subtitleField = NSTextField(labelWithString: "")
    private let agentButton = SidebarAgentStatusButtonView()
    private let statusDot = NSView()
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
        iconView.contentTintColor = .secondaryLabelColor
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.font = .preferredFont(forTextStyle: .body)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.cell?.usesSingleLineMode = true
        nameField.delegate = self
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        subtitleField.font = .preferredFont(forTextStyle: .caption1)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.isSelectable = false
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.maximumNumberOfLines = 1
        subtitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        statusDot.setContentHuggingPriority(.required, for: .horizontal)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true

        let textStack = NSStackView(views: [nameField, subtitleField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [iconView, textStack, agentButton, statusDot, spinner])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        // Auto-adjust the primary label + icon for selection highlighting.
        textField = nameField
        imageView = iconView

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 2),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -2),

            iconView.widthAnchor.constraint(equalToConstant: 20),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
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
        self.instance = instance
        self.onCommitRename = onCommitRename
        self.onCancelRename = onCancelRename

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

        let guestOS = instance.configuration.guestOS
        iconView.image = .systemSymbol(guestOS.iconName, accessibilityDescription: guestOS.displayName)
        subtitleField.stringValue = guestOS.displayName

        // Don't overwrite the field while the user is mid-rename.
        if !isRenaming {
            nameField.stringValue = instance.name
        }

        let busy = instance.isPreparing || instance.status.isTransitioning
        if busy {
            statusDot.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            statusDot.isHidden = false
            statusDot.layer?.backgroundColor = instance.statusDisplayNSColor.cgColor
            statusDot.toolTip = instance.statusToolTip
        }

        if let agentStatus = Self.visibleAgentStatus(for: instance) {
            agentButton.isHidden = false
            let dismissible = agentStatus == .waiting
            agentButton.configure(
                status: agentStatus, vmName: instance.name, hasDismissAction: dismissible
            )
        } else {
            agentButton.isHidden = true
        }
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
        agentButton.isHidden = true
    }

    // MARK: - Selection appearance

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            subtitleField.cell?.backgroundStyle = backgroundStyle
            iconView.contentTintColor =
                emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        }
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
