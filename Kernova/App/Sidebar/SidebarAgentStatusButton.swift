import AppKit

/// Trailing accessory shown in a sidebar row when the guest agent needs
/// attention.
///
/// Replaces SwiftUI's ``SidebarAgentStatusButton`` view. Click opens an
/// `NSPopover` (managed by ``PopoverPresenter``) with the install / update
/// affordance, mirroring the SwiftUI version's UX.
///
/// State mapping (per ``AgentStatus`` case):
///   - `.waiting`         → `exclamationmark.circle.fill`, secondary tint
///   - `.outdated`        → `arrow.triangle.2.circlepath.circle.fill`, orange
///   - `.connecting`      → spinning `NSProgressIndicator` (or static refresh
///     icon when reduce-motion is on), secondary tint
///   - `.current`         → `checkmark.circle.fill`, green
///   - `.unresponsive`    → `wifi.exclamationmark`, orange
///   - `.expectedMissing` → `exclamationmark.triangle.fill`, orange
///
/// The reduce-motion preference is read from `NSWorkspace.shared` and
/// re-evaluated when the user toggles the system setting via
/// `accessibilityDisplayOptionsDidChangeNotification`.
@MainActor
final class SidebarAgentStatusButton: NSView {
    private let button = NSButton()
    private let spinner = NSProgressIndicator()
    private let popoverPresenter = PopoverPresenter()

    private var status: AgentStatus = .waiting
    private var vmName: String = ""
    private var onMount: () -> Void = {}
    private var onDismiss: (() -> Void)?
    // RATIONALE: observed token is `Any?` (NSObjectProtocol opaque); Swift 6
    // can't prove it's Sendable across the nonisolated deinit. The token is
    // set once in init (MainActor) and only read for removal in deinit.
    nonisolated(unsafe) private var reduceMotionObserver: Any?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        configureLayout()
        observeReduceMotion()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarAgentStatusButton does not support NSCoder")
    }

    deinit {
        if let token = reduceMotionObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    // MARK: - Layout

    private func configureLayout() {
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 16),
            heightAnchor.constraint(equalToConstant: 16),
        ])

        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyUpOrDown
        button.target = self
        button.action = #selector(togglePopover(_:))
        addSubview(button)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        addSubview(spinner)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func observeReduceMotion() {
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyState()
            }
        }
    }

    // MARK: - Configure

    /// Bind this button to a particular agent status.
    func configure(
        status: AgentStatus,
        vmName: String,
        onMount: @escaping () -> Void,
        onDismiss: (() -> Void)?
    ) {
        self.status = status
        self.vmName = vmName
        self.onMount = onMount
        self.onDismiss = onDismiss
        applyState()
    }

    private func applyState() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let connectingLive = isConnecting(status) && !reduceMotion

        if connectingLive {
            button.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            button.isHidden = false
            button.image = .systemSymbol(symbolName(for: status), accessibilityDescription: helpText)
            button.contentTintColor = symbolColor(for: status)
        }
        toolTip = helpText
    }

    private func isConnecting(_ status: AgentStatus) -> Bool {
        if case .connecting = status { return true }
        return false
    }

    // MARK: - Actions

    @objc private func togglePopover(_ sender: Any?) {
        let content = AgentStatusPopoverViewController(
            status: status,
            vmName: vmName,
            onAction: { [weak self] in
                guard let self else { return }
                switch self.status {
                case .current, .unresponsive, .connecting:
                    break
                case .waiting, .outdated, .expectedMissing:
                    self.onMount()
                }
                self.popoverPresenter.close()
            },
            onDismiss: onDismiss.map { dismiss in
                { [weak self] in
                    dismiss()
                    self?.popoverPresenter.close()
                }
            }
        )
        popoverPresenter.show(content: content, from: button, preferredEdge: .maxX)
    }

    // MARK: - Status → visual mapping

    private func symbolName(for status: AgentStatus) -> String {
        switch status {
        case .waiting: "exclamationmark.circle.fill"
        case .outdated: "arrow.triangle.2.circlepath.circle.fill"
        case .connecting: "arrow.triangle.2.circlepath.circle.fill"
        case .current: "checkmark.circle.fill"
        case .unresponsive: "wifi.exclamationmark"
        case .expectedMissing: "exclamationmark.triangle.fill"
        }
    }

    private func symbolColor(for status: AgentStatus) -> NSColor {
        switch status {
        case .waiting: .secondaryLabelColor
        case .outdated: .systemOrange
        case .connecting: .secondaryLabelColor
        case .current: .systemGreen
        case .unresponsive: .systemOrange
        case .expectedMissing: .systemOrange
        }
    }

    private var helpText: String {
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
