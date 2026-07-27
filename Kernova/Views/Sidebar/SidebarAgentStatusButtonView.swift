import AppKit

/// Trailing accessory shown in the sidebar row when the guest agent needs
/// the user's attention.
///
/// An `NSButton` (the static SF Symbol states) and an `NSProgressIndicator`
/// (the `.connecting` spinner) stacked at fixed size, one visible at a time.
/// Click opens an `NSPopover` hosting an
/// ``AgentStatusPopoverContentViewController``.
@MainActor
final class SidebarAgentStatusButtonView: NSView,
    AgentStatusPopoverContentViewControllerDelegate
{
    /// Invoked when the user activates the popover's action button for a status
    /// that requires mounting the installer.
    var onMount: (() -> Void)?

    /// Invoked when the user activates the popover's "Don't show again" link.
    var onDismiss: (() -> Void)?

    /// The accessory's fixed square dimension — also read by the sidebar
    /// snap-to-fit measurement, so it reserves the right trailing width.
    static let width: CGFloat = 16

    private let iconButton = NSButton()
    private let spinner = NSProgressIndicator()
    private let popoverPresenter = PopoverPresenter()
    private let contentVC = AgentStatusPopoverContentViewController()

    private(set) var status: AgentStatus = .waiting
    private(set) var vmName: String = ""
    private(set) var hasDismissAction: Bool = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        configureIconButton()
        configureSpinner()
        contentVC.delegate = self

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: Self.width),
            iconButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            iconButton.topAnchor.constraint(equalTo: topAnchor),
            iconButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarAgentStatusButtonView does not support NSCoder")
    }

    /// Applies a new status / VM name / dismiss-availability snapshot.
    ///
    /// An open popover is updated in place, so an in-flight status change
    /// doesn't dismiss it.
    func configure(status: AgentStatus, vmName: String, hasDismissAction: Bool) {
        self.status = status
        self.vmName = vmName
        self.hasDismissAction = hasDismissAction

        toolTip = Self.helpText(for: status)
        applyVisualState()

        contentVC.update(status: status, vmName: vmName, hasDismissAction: hasDismissAction)
    }

    /// Closes any open popover and stops the spinner.
    ///
    /// Called when the cell is recycled, rebound, or hidden, so a stale popover
    /// can't fire its action against the wrong VM and the spinner can't keep
    /// animating off-screen.
    func reset() {
        popoverPresenter.close()
        spinner.stopAnimation(nil)
    }

    // MARK: - Subview configuration

    private func configureIconButton() {
        iconButton.translatesAutoresizingMaskIntoConstraints = false
        iconButton.bezelStyle = .accessoryBarAction
        iconButton.isBordered = false
        iconButton.imageScaling = .scaleProportionallyDown
        iconButton.target = self
        iconButton.action = #selector(iconTapped(_:))
        addSubview(iconButton)
    }

    private func configureSpinner() {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        // NSProgressIndicator exposes no tint API; it adopts the system control
        // accent, whose gray-ish default matches the `.connecting` semantic.
        addSubview(spinner)
    }

    private func applyVisualState() {
        if status.isConnecting {
            iconButton.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            iconButton.isHidden = false
            let symbol = Self.symbolName(for: status)
            iconButton.image = .systemSymbol(
                symbol, accessibilityDescription: Self.helpText(for: status)
            )
            iconButton.contentTintColor = Self.symbolColor(for: status)
        }
    }

    // MARK: - Actions

    @objc private func iconTapped(_: NSButton) {
        if popoverPresenter.isShown {
            popoverPresenter.close()
        } else {
            popoverPresenter.show(content: contentVC, from: self, preferredEdge: .maxX)
        }
    }

    // MARK: - AgentStatusPopoverContentViewControllerDelegate

    func agentStatusPopoverDidTapAction(_ vc: AgentStatusPopoverContentViewController) {
        if AgentStatusPopoverContentViewController.requiresMountAction(for: status) {
            onMount?()
        }
        popoverPresenter.close()
    }

    func agentStatusPopoverDidTapDismiss(_ vc: AgentStatusPopoverContentViewController) {
        onDismiss?()
        popoverPresenter.close()
    }

    // MARK: - Per-status visual mapping

    static func symbolName(for status: AgentStatus) -> String {
        switch status {
        case .waiting: "exclamationmark.circle.fill"
        case .outdated: "arrow.triangle.2.circlepath.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath.circle.fill"
        case .current: "checkmark.circle.fill"
        case .unresponsive: "wifi.exclamationmark"
        case .expectedMissing: "exclamationmark.triangle.fill"
        }
    }

    static func symbolColor(for status: AgentStatus) -> NSColor {
        switch status {
        case .waiting: StatusColor.inactive
        case .outdated: StatusColor.warning
        case .connecting: StatusColor.inactive
        case .current: StatusColor.running
        case .unresponsive: StatusColor.warning
        case .expectedMissing: StatusColor.warning
        }
    }

    static func helpText(for status: AgentStatus) -> String {
        switch status {
        case .waiting: "Guest agent not installed"
        case .outdated(let installed, let bundled):
            "Guest agent update available (\(installed) → \(bundled))"
        case .connecting(let expected): "Connecting to guest agent (was \(expected))"
        case .current(let version): "Guest agent connected (\(version))"
        case .unresponsive(let version): "Guest agent unresponsive (\(version))"
        case .expectedMissing(let expected): "Guest agent didn't reconnect (was \(expected))"
        }
    }
}
