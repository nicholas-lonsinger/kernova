import AppKit

/// Step 1: Select the guest operating system type.
@MainActor
final class OSSelectionStepViewController: CreationStepViewController {
    private let macButton = NSButton()
    private let linuxButton = NSButton()
    private var observation: ObservationLoop?

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = makeStepHeader(
            title: "Choose Operating System",
            subtitle: "Select the type of operating system you want to run in your virtual machine."
        )

        configureOSButton(
            macButton,
            os: .macOS,
            description: "Run macOS in a virtual machine on Apple Silicon."
        )
        configureOSButton(
            linuxButton,
            os: .linux,
            description: "Run Linux distributions using EFI or direct kernel boot."
        )

        let buttonRow = NSStackView(views: [macButton, linuxButton])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 20
        buttonRow.alignment = .top
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView(views: [header, buttonRow])
        outer.orientation = .vertical
        outer.alignment = .centerX
        outer.spacing = 24
        outer.translatesAutoresizingMaskIntoConstraints = false

        // RATIONALE: Pin top + leading + trailing only (NOT bottom). The
        // wizard's `contentContainer` enforces a minimum height; without a
        // bottom pin, the outer stack sits at its intrinsic content height
        // at the top of the container, with empty space below — rather
        // than stretching to container height and letting NSStackView
        // center items in the extra space. IPSW step is the exception (it
        // uses addFullSizeSubview to fill with an NSScrollView).
        outer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: container.topAnchor),
            outer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            buttonRow.leadingAnchor.constraint(equalTo: outer.leadingAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: outer.trailingAnchor),
        ])

        view = container

        observation = observeRecurring(
            track: { [weak self] in _ = self?.creationVM.selectedOS },
            apply: { [weak self] in self?.updateSelectionState() }
        )
        updateSelectionState()
    }

    private func configureOSButton(_ button: NSButton, os: VMGuestOS, description: String) {
        button.title = "\(os.displayName)\n\n\(description)"
        button.target = self
        button.action = #selector(osPicked(_:))
        button.bezelStyle = .regularSquare
        button.translatesAutoresizingMaskIntoConstraints = false
        button.imagePosition = .imageAbove
        button.image = .systemSymbol(os.iconName, accessibilityDescription: os.displayName)
        button.imageScaling = .scaleProportionallyUpOrDown
        button.identifier = NSUserInterfaceItemIdentifier(rawValue: os.rawValue)
        button.heightAnchor.constraint(equalToConstant: 140).isActive = true
    }

    @objc private func osPicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue,
            let os = VMGuestOS(rawValue: id)
        else { return }
        creationVM.selectedOS = os
        creationVM.applyOSDefaults()
    }

    private func updateSelectionState() {
        let selected = creationVM.selectedOS
        macButton.state = (selected == .macOS) ? .on : .off
        linuxButton.state = (selected == .linux) ? .on : .off
    }
}
