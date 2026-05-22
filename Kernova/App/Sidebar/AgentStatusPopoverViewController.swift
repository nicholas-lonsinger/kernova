import AppKit

/// Popover content for the sidebar's agent-status badge.
///
/// The popover itself is owned by ``PopoverPresenter`` on the parent
/// ``SidebarAgentStatusButton``.
///
/// Layout: a vertical NSStackView (16 pt edge insets, 10 pt spacing)
/// containing a headline title, a wrapping body (`NSTextField`
/// `wrappingLabelWithString`), and a footer NSStackView with an optional
/// "Don't show again" link button on the leading edge and the action
/// button on the trailing edge (default-action / Return).
///
/// Sizing: after layout, the view publishes `view.fittingSize` as
/// `preferredContentSize` so `NSPopover` sizes correctly via
/// `NSTextField`'s `preferredMaxLayoutWidth`-driven wrapping.
@MainActor
final class AgentStatusPopoverViewController: NSViewController {
    private static let bodyWidth: CGFloat = 328

    private let status: AgentStatus
    private let vmName: String
    private let onAction: () -> Void
    private let onDismiss: (() -> Void)?

    init(
        status: AgentStatus,
        vmName: String,
        onAction: @escaping () -> Void,
        onDismiss: (() -> Void)?
    ) {
        self.status = status
        self.vmName = vmName
        self.onAction = onAction
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AgentStatusPopoverViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()

        let title = NSTextField(labelWithString: AgentStatusPopoverMetrics.title(for: status))
        title.font = .preferredFont(forTextStyle: .headline)

        let body = NSTextField(
            wrappingLabelWithString: AgentStatusPopoverMetrics.bodyText(for: status, vmName: vmName)
        )
        body.font = .preferredFont(forTextStyle: .callout)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = Self.bodyWidth
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        body.isSelectable = true

        let actionButton = NSButton(
            title: AgentStatusPopoverMetrics.actionButtonTitle(for: status),
            target: self,
            action: #selector(actionTapped(_:))
        )
        actionButton.keyEquivalent = "\r"
        actionButton.bezelStyle = .rounded

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footerViews: [NSView]
        if onDismiss != nil {
            let dismissButton = NSButton(
                title: "Don't show again", target: self, action: #selector(dismissTapped(_:)))
            dismissButton.isBordered = false
            dismissButton.bezelStyle = .accessoryBarAction
            dismissButton.contentTintColor = .linkColor
            // Identifier so unit tests can locate the optional button.
            dismissButton.identifier = NSUserInterfaceItemIdentifier("AgentPopover.Dismiss")
            footerViews = [dismissButton, footerSpacer, actionButton]
        } else {
            footerViews = [footerSpacer, actionButton]
        }

        let footer = NSStackView(views: footerViews)
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let stack = NSStackView(views: [title, body, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            body.widthAnchor.constraint(equalToConstant: Self.bodyWidth),
        ])

        // Identifiers for unit-test introspection.
        title.identifier = NSUserInterfaceItemIdentifier("AgentPopover.Title")
        body.identifier = NSUserInterfaceItemIdentifier("AgentPopover.Body")
        actionButton.identifier = NSUserInterfaceItemIdentifier("AgentPopover.Action")

        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    @objc private func actionTapped(_ sender: Any?) {
        onAction()
    }

    @objc private func dismissTapped(_ sender: Any?) {
        onDismiss?()
    }
}
