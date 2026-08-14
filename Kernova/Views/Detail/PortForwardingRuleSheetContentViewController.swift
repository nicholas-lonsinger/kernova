import AppKit

/// Delegate for ``PortForwardingRuleSheetContentViewController``.
@MainActor
protocol PortForwardingRuleSheetContentViewControllerDelegate: AnyObject {
    /// The user accepted a rule the sheet already validated.
    func portForwardingRuleSheet(
        _ vc: PortForwardingRuleSheetContentViewController,
        didAdd rule: PortForwardingRule
    )

    /// The user dismissed without adding one.
    func portForwardingRuleSheetDidCancel(
        _ vc: PortForwardingRuleSheetContentViewController
    )
}

/// Sheet that composes one port-forwarding rule: protocol, host port, guest
/// port.
///
/// **Add** stays disabled until the fields describe a rule the network can
/// carry — both ports in range, and the host port not already claimed
/// (docs/NETWORKING.md: a rule that cannot take effect is refused when the user
/// enters it, never accepted and left to fail at VM start).
@MainActor
final class PortForwardingRuleSheetContentViewController: NSViewController {
    weak var delegate: PortForwardingRuleSheetContentViewControllerDelegate?

    /// The (transport, host port) pairs already forwarded on the network — every
    /// Shared Network VM's, since the host port is claimed network-wide.
    private let takenHostClaims: Set<PortForwardingHostClaim>

    private let transportPopUp = NSPopUpButton()
    private let hostPortField = NSTextField()
    private let guestPortField = NSTextField()
    private let addButton = NSButton()
    private let noteLabel = NSTextField(wrappingLabelWithString: "")

    /// `true` while the host port field is only mirroring the guest port, so
    /// further typing on the guest side keeps it in step; cleared the moment the
    /// user types a host port of their own.
    private var hostPortMirrorsGuestPort = true

    // MARK: - Layout constants

    private static let sheetWidth: CGFloat = 420
    private static let sheetHeight: CGFloat = 268
    private static let padding: CGFloat = 16
    private static let fieldWidth: CGFloat = 96
    private static let labelWidth: CGFloat = 92

    /// Identifiers on the two port fields, so tests (and this controller's own
    /// delegate callbacks) can tell them apart.
    nonisolated static let hostPortFieldIdentifier = NSUserInterfaceItemIdentifier(
        "portForwardingHostPort")
    nonisolated static let guestPortFieldIdentifier = NSUserInterfaceItemIdentifier(
        "portForwardingGuestPort")

    init(takenHostClaims: Set<PortForwardingHostClaim>) {
        self.takenHostClaims = takenHostClaims
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PortForwardingRuleSheetContentViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = makeHeader()
        let divider1 = makeHorizontalSeparator()
        let body = makeBody()
        let divider2 = makeHorizontalSeparator()
        let footer = makeFooter()

        for subview in [header, divider1, body, divider2, footer] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(subview)
        }

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: Self.sheetWidth),
            container.heightAnchor.constraint(equalToConstant: Self.sheetHeight),

            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            divider1.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider1.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider1.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            body.topAnchor.constraint(equalTo: divider1.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            divider2.topAnchor.constraint(equalTo: body.bottomAnchor),
            divider2.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            divider2.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            footer.topAnchor.constraint(equalTo: divider2.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        view = container
        updateControls()
    }

    // MARK: - Header

    private func makeHeader() -> NSView {
        let container = NSView()

        let title = NSTextField(labelWithString: "Add Port Forwarding Rule")
        title.font = .preferredFont(forTextStyle: .headline)
        title.isSelectable = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [title, spacer])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Spacing.small
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Self.padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.padding),
        ])
        return container
    }

    // MARK: - Body

    private func makeBody() -> NSView {
        let container = NSView()

        transportPopUp.controlSize = .small
        transportPopUp.target = self
        transportPopUp.action = #selector(transportChanged)
        for transport in PortForwardingTransport.allCases {
            let item = NSMenuItem(title: transport.displayName, action: nil, keyEquivalent: "")
            item.representedObject = transport.rawValue
            transportPopUp.menu?.addItem(item)
        }

        configure(hostPortField, identifier: Self.hostPortFieldIdentifier)
        configure(guestPortField, identifier: Self.guestPortFieldIdentifier)

        noteLabel.font = .preferredFont(forTextStyle: .caption1)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.maximumNumberOfLines = 2
        noteLabel.isSelectable = false

        let stack = NSStackView(views: [
            makeFieldRow("Protocol", control: transportPopUp),
            makeFieldRow("Host Port", control: hostPortField),
            makeFieldRow("Guest Port", control: guestPortField),
            noteLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.small
        stack.setCustomSpacing(Spacing.medium, after: stack.arrangedSubviews[2])
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Self.padding),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: container.bottomAnchor, constant: -Self.padding),
            noteLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        return container
    }

    /// Deliberately without a target/action of its own: Return then reaches the
    /// default button, which is the only thing that composes a rule — a field
    /// action would run alongside it and add the same rule twice.
    private func configure(_ field: NSTextField, identifier: NSUserInterfaceItemIdentifier) {
        field.identifier = identifier
        field.alignment = .right
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
    }

    private func makeFieldRow(_ title: String, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = Typography.body
        label.alignment = .right
        label.isSelectable = false
        label.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [label, control, spacer])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Spacing.standard
        return row
    }

    // MARK: - Footer

    private func makeFooter() -> NSView {
        let container = NSView()

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .push
        cancel.keyEquivalent = "\u{1b}"  // Escape

        addButton.title = "Add"
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.bezelStyle = .push
        addButton.keyEquivalent = "\r"  // Return = default action

        let stack = NSStackView(views: [spacer, cancel, addButton])
        stack.orientation = .horizontal
        stack.spacing = Spacing.standard
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Self.padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.padding),
        ])
        return container
    }

    // MARK: - Composition & validation

    /// The transport the popup currently selects.
    var selectedTransport: PortForwardingTransport {
        guard let raw = transportPopUp.selectedItem?.representedObject as? String,
            let transport = PortForwardingTransport(rawValue: raw)
        else { return .tcp }
        return transport
    }

    /// The rule the fields describe, `nil` while they describe none the network
    /// can carry: a port empty, non-numeric or outside 1–65535, or a
    /// (transport, host port) pair already forwarded.
    var composedRule: PortForwardingRule? {
        guard let hostPort = Self.port(from: hostPortField.stringValue),
            let guestPort = Self.port(from: guestPortField.stringValue)
        else { return nil }
        let rule = PortForwardingRule(
            transport: selectedTransport, hostPort: hostPort, guestPort: guestPort)
        guard !takenHostClaims.contains(rule.hostClaim) else { return nil }
        return rule
    }

    /// The port `text` names, `nil` when it names none.
    private static func port(from text: String) -> UInt16? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), PortForwardingRule.portRange.contains(value) else {
            return nil
        }
        return UInt16(value)
    }

    /// What the sheet says about the entered host port, `nil` when there is
    /// nothing to say.
    private var hostPortNote: String? {
        guard let hostPort = Self.port(from: hostPortField.stringValue) else { return nil }
        let claim = PortForwardingHostClaim(transport: selectedTransport, hostPort: hostPort)
        if takenHostClaims.contains(claim) {
            return
                "\(selectedTransport.displayName) host port \(hostPort) is already forwarded to a virtual machine on this network."
        }
        if hostPort < 1024 {
            return "Ports below 1024 are conventionally reserved for system services."
        }
        return nil
    }

    private func updateControls() {
        addButton.isEnabled = composedRule != nil
        noteLabel.stringValue = hostPortNote ?? ""
    }

    // MARK: - Actions

    @objc private func transportChanged() {
        updateControls()
    }

    @objc private func cancelTapped() {
        delegate?.portForwardingRuleSheetDidCancel(self)
    }

    @objc private func addTapped() {
        guard let rule = composedRule else { return }
        delegate?.portForwardingRuleSheet(self, didAdd: rule)
    }

    // MARK: - Helpers

    private func makeHorizontalSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}

// MARK: - NSTextFieldDelegate

extension PortForwardingRuleSheetContentViewController: NSTextFieldDelegate {
    /// Keeps the host port mirroring the guest port until the user gives it a
    /// value of its own — the symmetric default every comparable rules table
    /// offers — and re-validates on every keystroke.
    func controlTextDidChange(_ obj: Notification) {
        let edited = (obj.object as? NSTextField)?.identifier
        if edited == Self.hostPortFieldIdentifier {
            hostPortMirrorsGuestPort = hostPortField.stringValue.isEmpty
        } else if edited == Self.guestPortFieldIdentifier, hostPortMirrorsGuestPort {
            hostPortField.stringValue = guestPortField.stringValue
        }
        updateControls()
    }
}
