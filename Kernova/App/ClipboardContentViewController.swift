import Cocoa
import os

/// Pure AppKit view controller for the clipboard sharing window content.
///
/// Provides an editable `NSTextView` for the clipboard buffer and a status bar
/// showing the guest agent connection state. The status bar surfaces the
/// install/update affordance for macOS guests when the bundled Kernova agent is
/// missing or outdated. Linux guests use `spice-vdagent` from their package
/// manager — the affordance is hidden for them.
@MainActor
final class ClipboardContentViewController: NSViewController, NSTextViewDelegate {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "ClipboardContentViewController")

    private let instance: VMInstance
    private weak var viewModel: VMLibraryViewModel?
    private var textView: NSTextView!
    private var statusCircle: NSView!
    private var statusLabel: NSTextField!
    private var actionButton: NSButton!
    private var isUpdatingFromService = false
    private var serviceObservation: ObservationLoop?

    /// Tracks whether we previously observed a non-`.current` state so we only
    /// auto-eject after a real transition (avoiding redundant detach calls when
    /// the controller observes other clipboard service state changes).
    private var hasSeenNonCurrentStatus = false

    init(instance: VMInstance, viewModel: VMLibraryViewModel) {
        self.instance = instance
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    override func loadView() {
        let container = NSView()

        // Text editor
        let scrollView = makeScrollableTextView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        // Divider
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(divider)

        // Status bar
        let statusBar = makeStatusBar()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusBar)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            divider.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            statusBar.topAnchor.constraint(equalTo: divider.bottomAnchor),
            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Lower content hugging so the scroll view yields space to the status bar
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateUI()
        observeServiceChanges()
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        guard !isUpdatingFromService else { return }
        guard let service = instance.clipboardService else {
            Self.logger.warning("Clipboard edit ignored — clipboardService is nil for VM '\(self.instance.name, privacy: .public)'")
            return
        }
        service.clipboardText = textView.string
    }

    // MARK: - Observation

    private func observeServiceChanges() {
        serviceObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                // Read each property so observation re-fires when any of them
                // transitions: clipboardService (nil → non-nil on connect),
                // vsockControlService (drives agentStatus for macOS guests),
                // and the per-property fields the UI mirrors.
                let clipService = self.instance.clipboardService
                _ = clipService?.clipboardText
                _ = clipService?.isConnected
                _ = self.instance.vsockControlService?.agentStatus
                _ = self.instance.agentStatus
            },
            apply: { [weak self] in
                self?.updateUI()
            }
        )
    }

    private func updateUI() {
        let service = instance.clipboardService
        let status = instance.agentStatus
        let canInstallKernovaAgent = instance.configuration.guestOS == .macOS

        textView.isEditable = service != nil

        // Update text view only if the service's text differs from what's displayed
        // (avoids clobbering the user's in-progress edits)
        if let serviceText = service?.clipboardText, serviceText != textView.string {
            isUpdatingFromService = true
            textView.string = serviceText
            isUpdatingFromService = false
        }

        applyStatus(status, canInstallKernovaAgent: canInstallKernovaAgent)
        autoEjectIfJustBecameCurrent(status: status, canInstallKernovaAgent: canInstallKernovaAgent)
    }

    private func applyStatus(_ status: AgentStatus, canInstallKernovaAgent: Bool) {
        switch status {
        case .waiting:
            statusCircle.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
            statusLabel.stringValue = "Waiting for guest agent"
            actionButton.isHidden = !canInstallKernovaAgent
            actionButton.title = "Install Guest Agent…"
        case .outdated(let installed, let bundled):
            statusCircle.layer?.backgroundColor = NSColor.systemOrange.cgColor
            statusLabel.stringValue = "Update available (\(installed) → \(bundled))"
            actionButton.isHidden = !canInstallKernovaAgent
            actionButton.title = "Update Guest Agent…"
        case .connecting(let expected):
            // Live session for a previously-installed agent that hasn't
            // said Hello yet. No install/reinstall affordance — the agent
            // is expected to reconnect; the watchdog will surface
            // `.expectedMissing` if it doesn't.
            statusCircle.layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
            statusLabel.stringValue = "Connecting (was \(expected))"
            actionButton.isHidden = true
        case .current(let version):
            statusCircle.layer?.backgroundColor = NSColor.systemGreen.cgColor
            statusLabel.stringValue = "Connected (\(version))"
            actionButton.isHidden = true
        case .unresponsive(let version):
            statusCircle.layer?.backgroundColor = NSColor.systemOrange.cgColor
            statusLabel.stringValue = "Unresponsive (\(version))"
            actionButton.isHidden = true
        case .expectedMissing(let expected):
            statusCircle.layer?.backgroundColor = NSColor.systemOrange.cgColor
            statusLabel.stringValue = "Didn't reconnect (was \(expected))"
            actionButton.isHidden = !canInstallKernovaAgent
            actionButton.title = "Reinstall Guest Agent…"
        }
    }

    private func autoEjectIfJustBecameCurrent(status: AgentStatus, canInstallKernovaAgent: Bool) {
        if case .current = status {
            if hasSeenNonCurrentStatus, canInstallKernovaAgent {
                viewModel?.unmountGuestAgentInstaller(from: instance)
            }
            hasSeenNonCurrentStatus = false
        } else {
            hasSeenNonCurrentStatus = true
        }
    }

    @objc private func actionButtonClicked(_ sender: Any?) {
        viewModel?.mountGuestAgentInstaller(on: instance)
    }

    // MARK: - View Construction

    private func makeScrollableTextView() -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.delegate = self
        self.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        return scrollView
    }

    private func makeStatusBar() -> NSView {
        let circle = NSView()
        circle.wantsLayer = true
        circle.layer?.cornerRadius = 4
        circle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: 8),
            circle.heightAnchor.constraint(equalToConstant: 8),
        ])
        self.statusCircle = circle

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.statusLabel = label

        let button = NSButton(title: "", target: self, action: #selector(actionButtonClicked(_:)))
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.isHidden = true
        self.actionButton = button

        // Spacer needs an explicit low horizontal hugging priority to actually
        // expand inside the NSStackView. NSView's default hugging priority is
        // 250 — same as the label's — so without this, the stack view has no
        // signal to grow the spacer rather than the label, and the button
        // wouldn't reliably end up flush against the trailing edge.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [circle, label, spacer, button])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.alignment = .centerY

        return stack
    }
}
