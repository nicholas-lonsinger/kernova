import AppKit

/// Step 1 of the creation wizard: choose the guest operating system.
///
/// A native macOS form: a left-aligned heading and a radio-button group (one
/// radio per ``VMGuestOS``, each with a secondary description). Selecting a radio
/// writes ``VMCreationViewModel/selectedOS`` directly — the shared model is the
/// single source of truth, which the wizard shell observes to drive navigation.
/// Each radio lives in its own option view (so its description can sit beneath
/// it), so they aren't siblings and AppKit's automatic radio grouping doesn't
/// apply — exclusivity is enforced explicitly from the model in ``updateSelection()``.
@MainActor
final class OSSelectionContentViewController: NSViewController {
    private let creationVM: VMCreationViewModel
    private var radios: [VMGuestOS: NSButton] = [:]

    /// Indent (radio circle + gap) so a description aligns under its radio title.
    private static let descriptionIndent: CGFloat = 20

    /// User-facing description shown beneath each OS name.
    private static func description(for os: VMGuestOS) -> String {
        switch os {
        case .macOS: "Run macOS in a virtual machine on Apple Silicon."
        case .linux: "Run Linux distributions using EFI or direct kernel boot."
        }
    }

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

        let heading = NSTextField(labelWithString: "Choose Operating System")
        heading.font = WizardStyle.titleFont
        heading.isSelectable = false

        let subtitle = NSTextField(
            wrappingLabelWithString:
                "Select the operating system you want to run in your virtual machine.")
        subtitle.font = WizardStyle.subtitleFont
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 0
        subtitle.isSelectable = false

        let options = NSStackView(views: VMGuestOS.allCases.map(makeOSOption))
        options.orientation = .vertical
        options.alignment = .leading
        options.spacing = 16

        let stack = NSStackView(views: [heading, subtitle, options])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(20, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        let inset = WizardStyle.contentSideInset
        NSLayoutConstraint.activate([
            // Top-leading anchored (native form layout), not centered.
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            // Full-width subtitle/options so the wrapping text lays out at the
            // step width and the option rows fill it.
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            options.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        view = container
        updateSelection()
    }

    private func makeOSOption(_ os: VMGuestOS) -> NSView {
        let icon = NSImageView(image: .systemSymbol(os.iconName, accessibilityDescription: ""))
        icon.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .title3)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let radio = NSButton(
            radioButtonWithTitle: os.displayName, target: self, action: #selector(osChanged(_:)))
        radio.font = .preferredFont(forTextStyle: .body)
        radio.translatesAutoresizingMaskIntoConstraints = false
        radios[os] = radio

        let description = NSTextField(wrappingLabelWithString: Self.description(for: os))
        description.font = .preferredFont(forTextStyle: .subheadline)
        description.textColor = .secondaryLabelColor
        description.maximumNumberOfLines = 0
        description.isSelectable = false
        description.translatesAutoresizingMaskIntoConstraints = false

        let option = NSView()
        option.addSubview(icon)
        option.addSubview(radio)
        option.addSubview(description)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: option.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: radio.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),

            radio.topAnchor.constraint(equalTo: option.topAnchor),
            radio.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            radio.trailingAnchor.constraint(lessThanOrEqualTo: option.trailingAnchor),

            // Align the description under the radio title (past the radio circle).
            description.topAnchor.constraint(equalTo: radio.bottomAnchor, constant: 2),
            description.leadingAnchor.constraint(
                equalTo: radio.leadingAnchor, constant: Self.descriptionIndent),
            description.trailingAnchor.constraint(equalTo: option.trailingAnchor),
            description.bottomAnchor.constraint(equalTo: option.bottomAnchor),
        ])
        return option
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
