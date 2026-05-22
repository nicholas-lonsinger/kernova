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
    /// Single field that renders as a plain label by default and switches
    /// to an editable bezeled field when ``enterRenameMode()`` is called.
    private let nameField = NSTextField(labelWithString: "")
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

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.font = .preferredFont(forTextStyle: .body)
        nameField.lineBreakMode = .byTruncatingTail
        nameField.maximumNumberOfLines = 1
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameField.delegate = self
        applyLabelAppearance()

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [nameField, subtitleLabel])
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

        let outerStack = NSStackView(
            views: [iconView, textStack, agentBadge, indicatorContainer])
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
            applyLabelAppearance()
        }
        self.instance = instance
        applyState()
        observation = observeRecurring(
            track: { [weak instance] in
                // Reading the snapshot transitively reads every underlying
                // @Observable property the row cares about — adding a new
                // dependency means editing `SidebarRowSnapshot`, not this
                // tracking list.
                _ = instance?.sidebarRowSnapshot
            },
            apply: { [weak self] in
                self?.applyState()
            }
        )
    }

    private func applyState() {
        guard let instance else { return }
        let snapshot = instance.sidebarRowSnapshot

        iconView.image = .systemSymbol(snapshot.iconName, accessibilityDescription: "")

        if !inRenameMode {
            nameField.stringValue = snapshot.name
        }
        subtitleLabel.stringValue = snapshot.subtitle

        if snapshot.isSpinning {
            statusCircle.isHidden = true
            statusSpinner.isHidden = false
            statusSpinner.startAnimation(nil)
        } else {
            statusSpinner.stopAnimation(nil)
            statusSpinner.isHidden = true
            statusCircle.isHidden = false
            statusCircle.contentTintColor = snapshot.statusColor
        }
        toolTip = snapshot.toolTip

        if let agentStatus = snapshot.agentStatus {
            agentBadge.isHidden = false
            agentBadge.configure(
                status: agentStatus,
                vmName: snapshot.name,
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
        nameField.stringValue = instance.name
        applyEditableAppearance()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.nameField)
            self.nameField.currentEditor()?.selectAll(nil)
        }
    }

    func exitRenameMode() {
        guard inRenameMode else { return }
        inRenameMode = false
        applyLabelAppearance()
        // Restore from the (possibly mutated) instance.
        if let instance {
            nameField.stringValue = instance.name
        }
    }

    /// Configure ``nameField`` to render as a plain label (default state).
    private func applyLabelAppearance() {
        nameField.isEditable = false
        nameField.isSelectable = false
        nameField.isBordered = false
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
    }

    /// Configure ``nameField`` to render as an editable bezeled field
    /// while the row is in rename mode.
    private func applyEditableAppearance() {
        nameField.isEditable = true
        nameField.isSelectable = true
        nameField.isBordered = true
        nameField.isBezeled = true
        nameField.bezelStyle = .roundedBezel
        nameField.drawsBackground = true
        nameField.focusRingType = .default
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        guard inRenameMode, let instance, let viewModel else { return }
        viewModel.commitRename(for: instance, newName: nameField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            viewModel?.cancelRename()
            return true
        }
        return false
    }
}
