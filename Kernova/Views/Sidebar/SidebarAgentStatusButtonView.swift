import AppKit

/// Trailing accessory shown in the sidebar row when the guest agent needs
/// the user's attention.
///
/// Pure AppKit: an `NSButton` (for the static SF Symbol states) and an
/// `NSProgressIndicator` (for the `.connecting` spinner) stacked at fixed
/// size, with one visible at a time based on `status.isConnecting`. Click
/// opens an `NSPopover` (via ``PopoverPresenter``) hosting an
/// ``AgentStatusPopoverContentViewController``.
///
/// ## Why the spinner is an `NSProgressIndicator`
/// An earlier SwiftUI version used `.symbolEffect(.rotate, options:
/// .repeat(.continuous))` on the SF Symbol while `.connecting`. On macOS
/// Tahoe that modifier re-ran the SwiftUI view graph every animation tick,
/// generating enough CA commits to backlog the render server and freeze
/// the main thread for the entire post-start grace window. AppKit's
/// `NSProgressIndicator` animates in Core Animation without invalidating
/// the surrounding view tree.
@MainActor
final class SidebarAgentStatusButtonView: NSView,
    AgentStatusPopoverContentViewControllerDelegate
{
    /// Invoked when the user activates the popover's action button for a
    /// status that requires mounting the installer
    /// (`.waiting`, `.outdated`, `.expectedMissing`).
    var onMount: (() -> Void)?

    /// Invoked when the user activates the popover's "Don't show again"
    /// link (only surfaced when ``hasDismissAction`` is true).
    var onDismiss: (() -> Void)?

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
            widthAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 16),
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
    /// Updates the button image and tint, toggles the spinner, refreshes
    /// the help tooltip, and (if the popover is currently shown) updates
    /// the popover content in place so an in-flight status change
    /// (e.g. `.waiting → .current`) doesn't dismiss the popover.
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
    /// Called by the hosting sidebar cell when the cell is recycled, rebound to
    /// a different VM, or the indicator is hidden — so a stale popover can't
    /// fire its action against the wrong VM and the spinner can't keep
    /// animating on a hidden/off-screen view.
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
        // NSProgressIndicator does not expose a direct tint API; it adopts
        // the system control accent. The default rendering is gray-ish,
        // which matches the "secondary" semantic of the .connecting state.
        addSubview(spinner)
    }

    /// Reflects `status` into the icon image + tint, and into the spinner's
    /// running state.
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

    @objc private func iconTapped(_ sender: NSButton) {
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
