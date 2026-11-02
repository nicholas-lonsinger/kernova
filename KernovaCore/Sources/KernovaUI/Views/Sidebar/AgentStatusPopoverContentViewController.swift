import AppKit
import KernovaCore
import KernovaKit

/// Popover content shown when the user clicks the sidebar agent-status
/// button (the small SF Symbol or spinner next to each VM row).
///
/// The macOS agent's status reads as a title and a paragraph; the agent hub's
/// agents add a line per agent and a row per capability.
///
/// State is mutable in place via
/// ``update(presentation:isInstallerMounted:diskControl:vmName:hasDismissAction:)``
/// so the host can refresh the popover when any input flips while it is open,
/// without dismiss/re-present flicker.
@MainActor
final class AgentStatusPopoverContentViewController: NSViewController {
    /// What the trailing button does.
    enum ActionButton: Equatable {
        /// Presents the guest-agent disk control under its title.
        case diskControl(title: String)
        /// Only closes the popover: the disk control is disabled, and a popover
        /// still needs a way out.
        case done

        init(_ control: GuestAgentDiskControl.Model) {
            self = control.isEnabled ? .diskControl(title: control.title) : .done
        }

        var title: String {
            switch self {
            case .diskControl(let title): title
            case .done: "Done"
            }
        }
    }

    /// Fires when the user clicks the trailing button while it presents the
    /// guest-agent disk control.
    var onDiskControl: (() -> Void)?
    /// Fires when the user clicks the trailing button while it reads "Done".
    var onDone: (() -> Void)?
    /// Fires when the user clicks the "Don't show again" link, which only
    /// `hasDismissAction` surfaces.
    var onDismiss: (() -> Void)?

    /// Current presentation driving the popover's title, body and rows.
    private(set) var presentation = GuestAgentPresentation(macOSAgent: .waiting)
    /// The presentation's status.
    var status: AgentStatus { presentation.status }
    /// Whether the bundled installer disk is attached to the VM.
    private(set) var isInstallerMounted = false
    /// The trailing button, resolved from the guest-agent disk control.
    private(set) var actionButtonRole = ActionButton.done
    /// The command the attached disk installs from, shown with a Copy button;
    /// `nil` hides the row.
    private(set) var installCommand: String?
    /// VM name interpolated into the body text.
    private(set) var vmName: String = ""
    /// When `true`, surfaces the "Don't show again" link in the action row.
    private(set) var hasDismissAction: Bool = false

    // MARK: - Layout constants

    /// Popover content width — wider than `CalloutStyle.width` so the action
    /// row's buttons (e.g. "Reinstall Guest Agent…") fit on a single line.
    private static let contentWidth: CGFloat = 360
    private static let padding: CGFloat = 16
    private static let verticalSpacing: CGFloat = 10
    private static var bodyWidth: CGFloat { contentWidth - padding * 2 }

    // MARK: - Subviews (held for in-place updates)

    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    /// The hub's agent lines and capability rows; hidden for the macOS agent.
    private let rowsStack = NSStackView()
    /// ``installCommand`` under what it needs, and its Copy button.
    private let commandRow = NSStackView()
    private let commandCaption = NSTextField(wrappingLabelWithString: LinuxAgentDisk.installCommandPrecondition)
    private let commandLabel = NSTextField(wrappingLabelWithString: "")
    private let copyCommandButton = CopyValueButton(name: "Copy Install Command")
    private let actionButton = NSButton()
    private let dismissButton = NSButton()
    private let dismissSpacer = NSView()

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AgentStatusPopoverContentViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()

        configureTitleLabel()
        configureBodyLabel()
        configureActionButton()
        configureDismissButton()
        configureCommandRow()

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = Spacing.standard
        actionRow.alignment = .centerY
        dismissSpacer.translatesAutoresizingMaskIntoConstraints = false
        dismissSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionRow.setViews([dismissButton, dismissSpacer, actionButton], in: .leading)
        NSLayoutConstraint.activate([
            actionRow.widthAnchor.constraint(equalToConstant: Self.bodyWidth)
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.verticalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = Spacing.small
        stack.setViews([titleLabel, bodyLabel, rowsStack, commandRow, actionRow], in: .leading)

        container.addSubview(stack)
        let padding = Self.padding
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
            container.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])

        view = container
        applyContent()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let fittingSize = view.fittingSize
        if preferredContentSize != fittingSize {
            preferredContentSize = fittingSize
        }
    }

    /// Replaces the popover's presentation, installer state, disk control, VM
    /// name, and dismiss-action flag and refreshes every label and button in
    /// place.
    func update(
        presentation: GuestAgentPresentation, isInstallerMounted: Bool, diskControl: GuestAgentDiskControl.Model,
        vmName: String, hasDismissAction: Bool
    ) {
        self.presentation = presentation
        self.isInstallerMounted = isInstallerMounted
        actionButtonRole = ActionButton(diskControl)
        installCommand = diskControl.installCommand
        self.vmName = vmName
        self.hasDismissAction = hasDismissAction
        if isViewLoaded {
            applyContent()
        }
    }

    // MARK: - Subview configuration

    private func configureTitleLabel() {
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 0
        titleLabel.preferredMaxLayoutWidth = Self.bodyWidth
        titleLabel.isSelectable = false
    }

    private func configureBodyLabel() {
        bodyLabel.font = .preferredFont(forTextStyle: .callout)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.maximumNumberOfLines = 0
        bodyLabel.preferredMaxLayoutWidth = Self.bodyWidth
        // Non-selectable: only `.code`-style snippets are selectable.
        bodyLabel.isSelectable = false
    }

    private func configureActionButton() {
        actionButton.bezelStyle = .push
        actionButton.keyEquivalent = "\r"
        actionButton.target = self
        actionButton.action = #selector(actionTapped(_:))
    }

    private func configureCommandRow() {
        commandLabel.font = .monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        commandLabel.isSelectable = true
        commandLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        commandCaption.font = .preferredFont(forTextStyle: .callout)
        commandCaption.textColor = .secondaryLabelColor
        commandCaption.isSelectable = false
        commandCaption.preferredMaxLayoutWidth = Self.bodyWidth
        let command = NSStackView(views: [commandLabel, copyCommandButton])
        command.orientation = .horizontal
        command.alignment = .firstBaseline
        command.spacing = Spacing.small
        commandRow.orientation = .vertical
        commandRow.alignment = .leading
        commandRow.spacing = Spacing.small
        commandRow.setViews([commandCaption, command], in: .leading)
        commandRow.widthAnchor.constraint(equalToConstant: Self.bodyWidth).isActive = true
    }

    private func configureDismissButton() {
        // AppKit ships no borderless link bezel, so this is a bordered button
        // given a borderless look.
        dismissButton.bezelStyle = .accessoryBarAction
        dismissButton.isBordered = false
        dismissButton.target = self
        dismissButton.action = #selector(dismissTapped(_:))
        dismissButton.title = "Don't show again"
        dismissButton.contentTintColor = .linkColor
        dismissButton.setAccessibilityLabel("Don't show again")
    }

    private func applyContent() {
        titleLabel.stringValue = Self.title(for: status)
        if let hub = presentation.hub {
            bodyLabel.isHidden = true
            rowsStack.isHidden = false
            rowsStack.setViews(Self.rows(hub).map(makeRow), in: .leading)
        } else {
            bodyLabel.isHidden = false
            bodyLabel.stringValue = Self.bodyText(
                for: status, isInstallerMounted: isInstallerMounted, vmName: vmName)
            rowsStack.isHidden = true
            rowsStack.setViews([], in: .leading)
        }
        commandRow.isHidden = installCommand == nil
        commandLabel.stringValue = installCommand ?? ""
        copyCommandButton.value = installCommand
        actionButton.title = actionButtonRole.title
        dismissButton.isHidden = !hasDismissAction
    }

    /// The hub's agent lines, then its capability rows, each as a title and the
    /// value beside it.
    static func rows(_ hub: GuestAgentPresentation.Hub) -> [(title: String, value: String)] {
        hub.peers.map { ($0.title, $0.state) } + hub.capabilities.map { ($0.title, $0.detail) }
    }

    private func makeRow(_ row: (title: String, value: String)) -> NSView {
        let title = NSTextField(labelWithString: row.title)
        title.font = .preferredFont(forTextStyle: .callout)
        title.isSelectable = false
        let value = NSTextField(wrappingLabelWithString: row.value)
        value.font = .preferredFont(forTextStyle: .callout)
        value.textColor = .secondaryLabelColor
        value.isSelectable = false
        value.alignment = .right
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let line = NSStackView(views: [title, value])
        line.orientation = .horizontal
        line.distribution = .fill
        line.spacing = Spacing.standard
        line.widthAnchor.constraint(equalToConstant: Self.bodyWidth).isActive = true
        return line
    }

    // MARK: - Actions

    @objc private func actionTapped(_: NSButton) {
        switch actionButtonRole {
        case .diskControl: onDiskControl?()
        case .done: onDone?()
        }
    }

    @objc private func dismissTapped(_: NSButton) {
        onDismiss?()
    }

    // MARK: - Per-status strings

    static func title(for status: AgentStatus) -> String {
        switch status {
        case .waiting: "Set up the Kernova guest agent"
        case .outdated: "Update available"
        case .updating: "Updating guest agent"
        case .connecting: "Connecting to guest agent"
        case .current, .connected: "Guest agent connected"
        case .unresponsive: "Guest agent unresponsive"
        case .expectedMissing: "Guest agent didn't reconnect"
        }
    }

    /// The popover's body; where it tells the user how to install, it says the
    /// installer is already attached when it is, since the button then ejects.
    static func bodyText(
        for status: AgentStatus, isInstallerMounted: Bool, vmName: String
    ) -> String {
        let attachedStep =
            "The installer disk is attached to \(vmName) — inside the VM, open it in Finder and run install.command."
        let mountStep =
            "Mounting the installer presents it as a disk inside the VM — open it in Finder and run install.command."
        switch status {
        case .waiting:
            return
                "The Kernova guest agent enables clipboard sync with \(vmName). \(isInstallerMounted ? attachedStep : mountStep)"
        case .outdated(let installed, let bundled):
            return
                "\(vmName) is running guest agent \(installed). Kernova bundles \(bundled). \(isInstallerMounted ? attachedStep : mountStep)"
        case .updating(let installed, let bundled):
            return "\(vmName) is updating guest agent \(installed) to \(bundled)."
        case .connecting(let expected):
            return
                "Waiting for guest agent \(expected) on \(vmName) to connect."
        case .current(let version), .connected(let version):
            return "\(vmName) is connected with guest agent \(version)."
        case .unresponsive(let version):
            return
                "\(vmName) (guest agent \(version)) stopped responding to heartbeats. The control connection will reset automatically; if it persists, restart the agent inside the VM."
        case .expectedMissing(let expected):
            let reinstallStep =
                isInstallerMounted
                ? attachedStep
                : "Reinstalling presents the installer as a disk — open it in Finder and run install.command."
            return
                "\(vmName) had guest agent \(expected) installed, but it isn't connected now. \(reinstallStep)"
        }
    }
}
