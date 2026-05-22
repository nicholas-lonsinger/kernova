import AppKit

/// Single VM row in the AppKit sidebar.
///
/// Layout (horizontal, leading → trailing):
///   1. Guest-OS icon (20×20, secondary tint).
///   2. Vertical stack of name + subtitle.
///   3. Spacer.
///   4. Agent-status badge slot (populated by phase 7d's
///      ``SidebarAgentStatusButton``; empty placeholder until then).
///   5. Status indicator: spinner during transitions / preparing,
///      otherwise an 8×8 circle tinted by ``VMInstance/statusDisplayColor``.
///
/// Owns a per-row ``ObservationLoop`` watching the bound `VMInstance`. The
/// outer ``SidebarViewController`` reuses the same row view across
/// instance bindings by calling ``configure(_:)``, which rebuilds the
/// observation loop in place.
@MainActor
final class SidebarRowView: NSView, NSTextFieldDelegate {
    private weak var viewModel: VMLibraryViewModel?
    private var instance: VMInstance?
    private var observation: ObservationLoop?
    private var inRenameMode = false

    // MARK: - Subviews

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let renameField = NSTextField()
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let agentBadge = SidebarAgentStatusButton()
    private let statusSpinner = NSProgressIndicator()
    private let statusCircle = NSImageView()

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        configureLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarRowView does not support NSCoder")
    }

    // MARK: - Layout

    private func configureLayout() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentTintColor = .secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
        ])

        // Name slot — overlapping label (display) and editable field (rename)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        renameField.translatesAutoresizingMaskIntoConstraints = false
        renameField.isEditable = true
        renameField.isSelectable = true
        renameField.isBordered = true
        renameField.bezelStyle = .roundedBezel
        renameField.font = .preferredFont(forTextStyle: .body)
        renameField.delegate = self
        renameField.isHidden = true

        let nameSlot = NSView()
        nameSlot.translatesAutoresizingMaskIntoConstraints = false
        nameSlot.addSubview(nameLabel)
        nameSlot.addSubview(renameField)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: nameSlot.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: nameSlot.trailingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: nameSlot.centerYAnchor),
            renameField.leadingAnchor.constraint(equalTo: nameSlot.leadingAnchor),
            renameField.trailingAnchor.constraint(equalTo: nameSlot.trailingAnchor),
            renameField.centerYAnchor.constraint(equalTo: nameSlot.centerYAnchor),
            nameSlot.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [nameSlot, subtitleLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        agentBadge.setContentHuggingPriority(.required, for: .horizontal)
        agentBadge.isHidden = true

        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.isDisplayedWhenStopped = false
        statusSpinner.isHidden = true

        statusCircle.translatesAutoresizingMaskIntoConstraints = false
        statusCircle.image = .systemSymbol("circle.fill", accessibilityDescription: "")
        statusCircle.imageScaling = .scaleProportionallyUpOrDown
        statusCircle.contentTintColor = .secondaryLabelColor

        let indicatorContainer = NSView()
        indicatorContainer.translatesAutoresizingMaskIntoConstraints = false
        indicatorContainer.addSubview(statusSpinner)
        indicatorContainer.addSubview(statusCircle)
        NSLayoutConstraint.activate([
            indicatorContainer.widthAnchor.constraint(equalToConstant: 14),
            indicatorContainer.heightAnchor.constraint(equalToConstant: 14),
            statusSpinner.centerXAnchor.constraint(equalTo: indicatorContainer.centerXAnchor),
            statusSpinner.centerYAnchor.constraint(equalTo: indicatorContainer.centerYAnchor),
            statusCircle.widthAnchor.constraint(equalToConstant: 8),
            statusCircle.heightAnchor.constraint(equalToConstant: 8),
            statusCircle.centerXAnchor.constraint(equalTo: indicatorContainer.centerXAnchor),
            statusCircle.centerYAnchor.constraint(equalTo: indicatorContainer.centerYAnchor),
        ])

        let outerStack = NSStackView(views: [iconView, textStack, agentBadge, indicatorContainer])
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.orientation = .horizontal
        outerStack.alignment = .centerY
        outerStack.spacing = 8
        outerStack.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
        addSubview(outerStack)
        NSLayoutConstraint.activate([
            outerStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            outerStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            outerStack.topAnchor.constraint(equalTo: topAnchor),
            outerStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Configure

    func configure(_ instance: VMInstance) {
        observation?.cancel()
        // Leaving rename mode if the row gets re-bound to a different
        // instance: stale local edits would otherwise commit to the new VM.
        if inRenameMode, self.instance !== instance {
            inRenameMode = false
            nameLabel.isHidden = false
            renameField.isHidden = true
        }
        self.instance = instance
        applyState()
        observation = observeRecurring(
            track: { [weak self, weak instance] in
                guard let instance else { return }
                _ = self?.viewModel
                _ = instance.name
                _ = instance.status
                _ = instance.isPreparing
                _ = instance.preparingState
                _ = instance.configuration.guestOS
                _ = instance.statusToolTip
                _ = instance.statusDisplayColor
                _ = instance.visibleSidebarAgentStatus
                _ = instance.installState
                _ = instance.virtualMachine
                _ = instance.configuration.agentInstallNudgeDismissed
                _ = instance.configuration.lastSeenAgentVersion
            },
            apply: { [weak self] in
                self?.applyState()
            }
        )
    }

    private func applyState() {
        guard let instance else { return }

        iconView.image = .systemSymbol(
            instance.configuration.guestOS.iconName, accessibilityDescription: "")

        if !inRenameMode {
            nameLabel.stringValue = instance.name
        }
        subtitleLabel.stringValue = instance.configuration.guestOS.displayName

        let isSpinning = instance.isPreparing || instance.status.isTransitioning
        if isSpinning {
            statusCircle.isHidden = true
            statusSpinner.isHidden = false
            statusSpinner.startAnimation(nil)
        } else {
            statusSpinner.stopAnimation(nil)
            statusSpinner.isHidden = true
            statusCircle.isHidden = false
            statusCircle.contentTintColor = instance.statusDisplayColor
        }
        toolTip = instance.statusToolTip

        if let agentStatus = instance.visibleSidebarAgentStatus {
            agentBadge.isHidden = false
            agentBadge.configure(
                status: agentStatus,
                vmName: instance.name,
                onMount: { [weak viewModel, weak instance] in
                    guard let viewModel, let instance else { return }
                    viewModel.mountGuestAgentInstaller(on: instance)
                },
                onDismiss: agentStatus == .waiting
                    ? { [weak viewModel, weak instance] in
                        guard let viewModel, let instance else { return }
                        viewModel.dismissAgentInstallNudge(for: instance)
                    } : nil
            )
        } else {
            agentBadge.isHidden = true
        }
    }

    // MARK: - Rename

    func enterRenameMode() {
        guard let instance else { return }
        inRenameMode = true
        renameField.stringValue = instance.name
        nameLabel.isHidden = true
        renameField.isHidden = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.renameField)
            self.renameField.currentEditor()?.selectAll(nil)
        }
    }

    func exitRenameMode() {
        guard inRenameMode else { return }
        inRenameMode = false
        nameLabel.isHidden = false
        renameField.isHidden = true
        // Restore the label text from the (possibly mutated) instance.
        if let instance {
            nameLabel.stringValue = instance.name
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        guard inRenameMode, let instance, let viewModel else { return }
        viewModel.commitRename(for: instance, newName: renameField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            viewModel?.cancelRename()
            return true
        }
        return false
    }
}
