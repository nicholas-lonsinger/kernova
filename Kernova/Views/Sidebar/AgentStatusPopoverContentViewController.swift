import AppKit

/// Delegate for ``AgentStatusPopoverContentViewController``.
///
/// The view controller is intentionally decoupled from
/// `VMLibraryViewModel`. The host (the AppKit wrapper button
/// ``SidebarAgentStatusButtonView``) implements these methods, decides which
/// view-model action to invoke based on `vc.status`, and closes the
/// popover.
@MainActor
protocol AgentStatusPopoverContentViewControllerDelegate: AnyObject {
    /// Invoked when the user clicks the trailing action button
    /// (Install / Update / Reinstall / Done).
    func agentStatusPopoverDidTapAction(_ vc: AgentStatusPopoverContentViewController)

    /// Invoked when the user clicks the "Don't show again" link.
    ///
    /// Only fires when the host has surfaced the link (i.e.
    /// `hasDismissAction == true`).
    func agentStatusPopoverDidTapDismiss(_ vc: AgentStatusPopoverContentViewController)
}

/// Popover content shown when the user clicks the sidebar agent-status
/// button (the small SF Symbol or spinner next to each VM row).
///
/// Renders a per-status title + body explanation + a trailing action button
/// (Install / Update / Reinstall / Done). When the host enables it, an
/// additional "Don't show again" link appears at the bottom-leading edge
/// (used only for the `.waiting` state — the other states are too urgent
/// to dismiss).
///
/// State is mutable in place via ``update(status:vmName:hasDismissAction:)``
/// so the host can refresh the popover when `status` flips while the
/// popover is open (e.g. the agent connects mid-popover, `.waiting` →
/// `.current`) without dismiss/re-present flicker.
@MainActor
final class AgentStatusPopoverContentViewController: NSViewController {
    weak var delegate: AgentStatusPopoverContentViewControllerDelegate?

    /// Current status driving the popover's content + action.
    private(set) var status: AgentStatus = .waiting
    /// VM name interpolated into the body text.
    private(set) var vmName: String = ""
    /// When `true`, surfaces the "Don't show again" link in the action row.
    private(set) var hasDismissAction: Bool = false

    // MARK: - Layout constants

    /// Popover content width.
    ///
    /// Slightly wider than `CalloutStyle.width` so the action row's
    /// buttons (e.g. "Reinstall Guest Agent…") fit on a single line.
    private static let contentWidth: CGFloat = 360
    private static let padding: CGFloat = 16
    private static let verticalSpacing: CGFloat = 10
    private static var bodyWidth: CGFloat { contentWidth - padding * 2 }

    // MARK: - Subviews (held for in-place updates)

    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
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

        let actionRow = NSStackView()
        actionRow.orientation = .horizontal
        actionRow.spacing = Spacing.standard
        actionRow.alignment = .centerY
        dismissSpacer.translatesAutoresizingMaskIntoConstraints = false
        dismissSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionRow.setViews([dismissButton, dismissSpacer, actionButton], in: .leading)
        // The dismiss button trails to the left edge; spacer fills middle;
        // action button trails to the right edge.
        NSLayoutConstraint.activate([
            actionRow.widthAnchor.constraint(equalToConstant: Self.bodyWidth)
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.verticalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setViews([titleLabel, bodyLabel, actionRow], in: .leading)

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

    /// Replaces the popover's status, VM name, and dismiss-action flag and
    /// refreshes every label and button in place.
    ///
    /// Call this when state changes while the popover is open so the
    /// existing `NSPopover` content updates without a dismiss/re-present
    /// flicker.
    func update(status: AgentStatus, vmName: String, hasDismissAction: Bool) {
        self.status = status
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
        // Non-selectable to match the convention established for the other
        // AppKit popovers (only `.code`-style snippets are selectable).
        bodyLabel.isSelectable = false
    }

    private func configureActionButton() {
        actionButton.bezelStyle = .rounded
        actionButton.keyEquivalent = "\r"
        actionButton.target = self
        actionButton.action = #selector(actionTapped(_:))
    }

    private func configureDismissButton() {
        // Link-style "Don't show again" button. AppKit doesn't ship a
        // borderless link bezel out of the box, so we use a bordered button
        // with a borderless look (no bezel, no background, label-colored
        // text).
        dismissButton.bezelStyle = .accessoryBarAction
        dismissButton.isBordered = false
        dismissButton.target = self
        dismissButton.action = #selector(dismissTapped(_:))
        dismissButton.title = "Don't show again"
        dismissButton.contentTintColor = .linkColor
        dismissButton.setAccessibilityLabel("Don't show again")
    }

    /// Refreshes labels, action-button title, and dismiss-button visibility
    /// from the current `status` / `vmName` / `hasDismissAction`.
    private func applyContent() {
        titleLabel.stringValue = Self.title(for: status)
        bodyLabel.stringValue = Self.bodyText(for: status, vmName: vmName)
        actionButton.title = Self.actionButtonTitle(for: status)
        dismissButton.isHidden = !hasDismissAction
    }

    // MARK: - Actions

    @objc private func actionTapped(_ sender: NSButton) {
        delegate?.agentStatusPopoverDidTapAction(self)
    }

    @objc private func dismissTapped(_ sender: NSButton) {
        delegate?.agentStatusPopoverDidTapDismiss(self)
    }

    // MARK: - Per-status strings

    /// `true` when the action button should fire `onMount` (otherwise the
    /// host should just close the popover).
    static func requiresMountAction(for status: AgentStatus) -> Bool {
        switch status {
        case .waiting, .outdated, .expectedMissing: true
        case .current, .unresponsive, .connecting: false
        }
    }

    static func title(for status: AgentStatus) -> String {
        switch status {
        case .waiting: "Set up the Kernova guest agent"
        case .outdated: "Update available"
        case .connecting: "Connecting to guest agent"
        case .current: "Guest agent connected"
        case .unresponsive: "Guest agent unresponsive"
        case .expectedMissing: "Guest agent didn't reconnect"
        }
    }

    static func bodyText(for status: AgentStatus, vmName: String) -> String {
        switch status {
        case .waiting:
            return
                "The Kernova guest agent enables clipboard sync with \(vmName). Mounting the installer presents it as a disk inside the VM — open it in Finder and run install.command."
        case .outdated(let installed, let bundled):
            return
                "\(vmName) is running guest agent \(installed). Kernova bundles \(bundled). Mounting the installer presents it as a disk inside the VM — open it in Finder and run install.command."
        case .connecting(let expected):
            return
                "Waiting for guest agent \(expected) on \(vmName) to reconnect after boot. If it doesn't connect within a couple of minutes, you'll see a 'didn't reconnect' indicator with reinstall steps."
        case .current(let version):
            return "\(vmName) is connected with guest agent \(version)."
        case .unresponsive(let version):
            return
                "\(vmName) (guest agent \(version)) stopped responding to heartbeats. The control connection will reset automatically; if it persists, restart the agent inside the VM."
        case .expectedMissing(let expected):
            return
                "\(vmName) had guest agent \(expected) installed previously, but it didn't connect after this boot. The agent's LaunchAgent may be unloaded, or it may have been uninstalled inside the VM. Reinstalling presents the installer as a disk — open it in Finder and run install.command."
        }
    }

    static func actionButtonTitle(for status: AgentStatus) -> String {
        switch status {
        case .waiting: "Install Guest Agent…"
        case .outdated: "Update Guest Agent…"
        case .current, .unresponsive, .connecting: "Done"
        case .expectedMissing: "Reinstall Guest Agent…"
        }
    }
}
