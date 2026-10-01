import AppKit

/// Step 1 of the creation wizard: choose the guest operating system.
///
/// Selecting a radio writes ``VMCreationViewModel/selectedOS`` directly. Each
/// radio lives in its own option view beside its icon, so they aren't siblings
/// and AppKit's automatic radio grouping doesn't apply — exclusivity is enforced
/// explicitly from the model in ``updateSelection()``.
@MainActor
final class OSSelectionContentViewController: NSViewController {
    private let creationVM: VMCreationViewModel
    private var radios: [VMGuestOS: NSButton] = [:]

    init(creationVM: VMCreationViewModel) {
        self.creationVM = creationVM
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("OSSelectionContentViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()

        let heading = makeWizardTitle("Choose Operating System")

        let options = NSStackView(views: VMGuestOS.allCases.map(makeOSOption))
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = Spacing.large

        let stack = NSStackView(views: [heading, options])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.standard
        stack.setCustomSpacing(20, after: heading)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        let inset = WizardStyle.contentSideInset
        NSLayoutConstraint.activate([
            // Top-leading anchored (native form layout), not centered.
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            options.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = container
        updateSelection()
    }

    private func makeOSOption(_ os: VMGuestOS) -> NSView {
        let radio = NSButton(
            radioButtonWithTitle: os.displayName, target: self, action: #selector(osChanged(_:)))
        radios[os] = radio
        return makeWizardRadioOption(radio: radio, iconSymbol: os.iconName)
    }

    @objc private func osChanged(_ sender: NSButton) {
        guard let os = radios.first(where: { $0.value === sender })?.key else { return }
        creationVM.selectedOS = os
        updateSelection()
    }

    private func updateSelection() {
        for (os, radio) in radios {
            radio.state = os == creationVM.selectedOS ? .on : .off
        }
    }
}
