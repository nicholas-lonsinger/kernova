import Cocoa

/// Pure-AppKit content for the serial console window.
///
/// Kernova does not embed a terminal emulator — interactive serial access is
/// delegated to a real external terminal (Terminal.app, iTerm, Ghostty, …) that
/// attaches to a host-side AF_UNIX socket (see `SerialSocketRelay`). This panel
/// surfaces the connection state and the command to connect, or an affordance
/// to enable the socket when it is off for this VM.
///
/// Observes `VMInstance` via `withObservationTracking`.
@MainActor
final class SerialConsoleContentViewController: NSViewController {
    private let instance: VMInstance

    private let statusCircle = NSView()
    private let statusLabel = NSTextField(labelWithString: "")

    /// Shown when the relay is live: path + connect commands.
    private let connectedStack = NSStackView()
    private let pathField = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")

    /// Shown when the relay is off for this VM.
    private let disabledStack = NSStackView()
    private let enableButton = NSButton()

    private var observation: ObservationLoop?

    private static let socatTemplate = "socat -,raw,echo=0 UNIX-CONNECT:"
    private static let ncTemplate = "nc -U "

    init(instance: VMInstance) {
        self.instance = instance
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    override func loadView() {
        let container = NSView()

        // Status row
        statusCircle.wantsLayer = true
        statusCircle.layer?.cornerRadius = 4
        statusCircle.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusCircle.widthAnchor.constraint(equalToConstant: 8),
            statusCircle.heightAnchor.constraint(equalToConstant: 8),
        ])
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        let statusRow = NSStackView(views: [statusCircle, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = Spacing.small

        buildConnectedStack()
        buildDisabledStack()

        let root = NSStackView(views: [statusRow, connectedStack, disabledStack])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = Spacing.large
        root.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: Spacing.major),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Spacing.major),
            root.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor, constant: -Spacing.major),
            root.bottomAnchor.constraint(
                lessThanOrEqualTo: container.bottomAnchor, constant: -Spacing.major),
        ])

        self.view = container
    }

    private func buildConnectedStack() {
        let intro = NSTextField(
            wrappingLabelWithString:
                "Attach an external terminal to this VM's serial port via its UNIX socket:")
        intro.font = .systemFont(ofSize: NSFont.systemFontSize)
        intro.preferredMaxLayoutWidth = 560

        pathField.isSelectable = true
        pathField.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        pathField.textColor = .labelColor
        pathField.lineBreakMode = .byTruncatingMiddle

        let socatButton = NSButton(
            title: "Copy socat command", target: self, action: #selector(copySocatCommand))
        socatButton.bezelStyle = .rounded
        let ncButton = NSButton(
            title: "Copy nc command", target: self, action: #selector(copyNcCommand))
        ncButton.bezelStyle = .rounded
        let buttonRow = NSStackView(views: [socatButton, ncButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = Spacing.standard

        hintLabel.maximumNumberOfLines = 0
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.preferredMaxLayoutWidth = 560
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.stringValue =
            "socat gives the best experience for full-screen apps (install via Homebrew: brew install socat). "
            + "nc -U is built in but runs in line mode."

        connectedStack.orientation = .vertical
        connectedStack.alignment = .leading
        connectedStack.spacing = Spacing.standard
        for subview in [intro, pathField, buttonRow, hintLabel] as [NSView] {
            connectedStack.addArrangedSubview(subview)
        }
    }

    private func buildDisabledStack() {
        let label = NSTextField(wrappingLabelWithString: "The serial socket is off for this VM.")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)

        enableButton.title = "Enable Serial Socket"
        enableButton.bezelStyle = .rounded
        enableButton.target = self
        enableButton.action = #selector(enableRelay)

        let note = NSTextField(
            wrappingLabelWithString:
                "Turn it on here or in Settings to expose the serial port to an external terminal. "
                + "Output is captured to serial.log either way.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 560

        disabledStack.orientation = .vertical
        disabledStack.alignment = .leading
        disabledStack.spacing = Spacing.standard
        disabledStack.addArrangedSubview(label)
        disabledStack.addArrangedSubview(enableButton)
        disabledStack.addArrangedSubview(note)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateUI()
        observeInstanceChanges()
    }

    // MARK: - Observation

    private func observeInstanceChanges() {
        observation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.instance.serialSocketPath
                _ = self.instance.status
                _ = self.instance.configuration.serialSocketRelayEnabled
            },
            apply: { [weak self] in
                self?.updateUI()
            }
        )
    }

    private func updateUI() {
        let isActive = instance.status == .running || instance.status == .paused
        statusCircle.layer?.backgroundColor =
            isActive ? NSColor.systemGreen.cgColor : NSColor.secondaryLabelColor.cgColor

        if let path = instance.serialSocketPath {
            statusLabel.stringValue = "Serial socket ready"
            pathField.stringValue = path
            pathField.toolTip = path
            connectedStack.isHidden = false
            disabledStack.isHidden = true
        } else {
            statusLabel.stringValue = isActive ? "Serial socket off" : "Not running"
            connectedStack.isHidden = true
            disabledStack.isHidden = false
            enableButton.isEnabled = isActive
        }
    }

    // MARK: - Actions

    @objc private func copySocatCommand() {
        copyToPasteboard(Self.socatTemplate + quoted(instance.serialSocketPath))
    }

    @objc private func copyNcCommand() {
        copyToPasteboard(Self.ncTemplate + quoted(instance.serialSocketPath))
    }

    @objc private func enableRelay() {
        instance.performConfigurationMutation { $0.serialSocketRelayEnabled = true }
    }

    /// Shell-single-quotes the path so it pastes correctly even if it contains
    /// spaces.
    ///
    /// Returns an empty string when no socket is bound.
    private func quoted(_ path: String?) -> String {
        guard let path else { return "" }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
