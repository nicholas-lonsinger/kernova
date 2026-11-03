import AppKit
import KernovaAgentHost
import KernovaCore
import KernovaKit

/// One VM's guest-agent status: the popover the sidebar's agent-status badge
/// opens, and the content of the Guest Agent Status window
/// (``GuestAgentStatusWindowController``).
///
/// The status reads as a title, then a line per agent and a row per
/// capability.
///
/// State is mutable in place via
/// ``update(presentation:diskControl:hasDismissAction:)``
/// so the host can refresh the panel when any input flips while it is open,
/// without dismiss/re-present flicker.
@MainActor
final class GuestAgentStatusViewController: NSViewController {
    /// What the trailing button does.
    enum ActionButton: Equatable {
        /// Presents the guest-agent disk control under its title.
        case diskControl(title: String)
        /// Only closes the panel: the disk control is disabled, and a popover
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

    /// Current presentation driving the panel's title, body and rows.
    private(set) var presentation = GuestAgentPresentation(hub: .empty)
    /// The presentation's status.
    var status: AgentStatus { presentation.status }
    /// The trailing button, resolved from the guest-agent disk control.
    private(set) var actionButtonRole = ActionButton.done
    /// How the user installs from the attached disk: a step, or a command
    /// shown with a Copy button; `nil` hides the row.
    private(set) var installGuidance: GuestAgentDiskControl.InstallGuidance?
    /// When `true`, surfaces the "Don't show again" link in the action row.
    private(set) var hasDismissAction: Bool = false

    // MARK: - Layout constants

    /// Content width — wider than `CalloutStyle.width` so the action
    /// row's buttons (e.g. "Reinstall Guest Agent…") fit on a single line.
    private static let contentWidth: CGFloat = 360
    private static let padding: CGFloat = 16
    private static let verticalSpacing: CGFloat = 10
    private static var bodyWidth: CGFloat { contentWidth - padding * 2 }

    // MARK: - Subviews (held for in-place updates)

    private let titleLabel = NSTextField(labelWithString: "")
    /// The agent lines and capability rows.
    private let rowsStack = NSStackView()
    /// ``installGuidance``: a step alone, or a command under what it needs,
    /// with its Copy button.
    private let commandRow = NSStackView()
    private let commandCaption = NSTextField(wrappingLabelWithString: "")
    /// The command and its Copy button; hidden for a step.
    private let commandLine = NSStackView()
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
        fatalError("GuestAgentStatusViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()

        configureTitleLabel()
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
        stack.setViews([titleLabel, rowsStack, commandRow, actionRow], in: .leading)

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

    /// Replaces the panel's presentation, disk control, and dismiss-action flag
    /// and refreshes every label and button in place.
    func update(
        presentation: GuestAgentPresentation, diskControl: GuestAgentDiskControl.Model, hasDismissAction: Bool
    ) {
        self.presentation = presentation
        actionButtonRole = ActionButton(diskControl)
        installGuidance = diskControl.installGuidance
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
        commandLine.setViews([commandLabel, copyCommandButton], in: .leading)
        commandLine.orientation = .horizontal
        commandLine.alignment = .firstBaseline
        commandLine.spacing = Spacing.small
        commandRow.orientation = .vertical
        commandRow.alignment = .leading
        commandRow.spacing = Spacing.small
        commandRow.setViews([commandCaption, commandLine], in: .leading)
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
        rowsStack.setViews(Self.rows(presentation).map(makeRow), in: .leading)
        commandRow.isHidden = installGuidance == nil
        let command: String?
        switch installGuidance {
        case .step(let step):
            commandCaption.stringValue = step
            command = nil
        case .command(let line):
            commandCaption.stringValue = LinuxAgentDisk.installCommandPrecondition
            command = line
        case nil:
            command = nil
        }
        commandLine.isHidden = command == nil
        commandLabel.stringValue = command ?? ""
        copyCommandButton.value = command
        actionButton.title = actionButtonRole.title
        dismissButton.isHidden = !hasDismissAction
    }

    /// The agent lines, then the capability rows, each as a title and the
    /// value beside it.
    static func rows(_ presentation: GuestAgentPresentation) -> [(title: String, value: String)] {
        presentation.agents.map { ($0.title, $0.state) } + presentation.capabilities.map { ($0.title, $0.detail) }
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
}
