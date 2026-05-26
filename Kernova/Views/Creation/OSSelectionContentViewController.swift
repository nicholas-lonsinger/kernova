import AppKit

/// Step 1 of the creation wizard: choose the guest operating system.
///
/// Presents one selectable card per ``VMGuestOS``. Clicking a card writes
/// ``VMCreationViewModel/selectedOS`` directly (the shared model is the single
/// source of truth) and restyles the cards. No delegate — selection state lives
/// in the model, which the wizard shell observes to drive navigation.
@MainActor
final class OSSelectionContentViewController: NSViewController {
    private let creationVM: VMCreationViewModel
    private var cards: [VMGuestOS: WizardSelectableCardView] = [:]
    private var cardIcons: [VMGuestOS: NSImageView] = [:]

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

        let title = makeWizardTitle("Choose Operating System")
        let subtitle = makeWizardSubtitle(
            "Select the type of operating system you want to run in your virtual machine.")

        let macCard = makeOSCard(for: .macOS)
        let linuxCard = makeOSCard(for: .linux)

        let cardRow = NSStackView(views: [macCard, linuxCard])
        cardRow.orientation = .horizontal
        cardRow.alignment = .top
        cardRow.distribution = .fillEqually
        cardRow.spacing = 16

        let stack = NSStackView(views: [title, subtitle, cardRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(WizardStyle.sectionSpacing, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            // Top-anchored (not centered) so the chooser sits below the step
            // indicator with predictable spacing instead of floating in the
            // middle of the fixed-height sheet.
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            // Inset to match the scrolling steps' content margin (the shell only
            // applies a small edge inset so scroll bars sit near the window edge).
            stack.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: WizardStyle.contentSideInset),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -WizardStyle.contentSideInset),
            // The wrapping subtitle and the equally-split card row both need to
            // lay out at the full step width (centerX alignment otherwise sizes
            // them to their intrinsic width and the subtitle won't wrap).
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cardRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            macCard.heightAnchor.constraint(equalTo: linuxCard.heightAnchor),
        ])

        view = container
        updateSelection()
    }

    private func makeOSCard(for os: VMGuestOS) -> WizardSelectableCardView {
        let icon = NSImageView(image: .systemSymbol(os.iconName, accessibilityDescription: ""))
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 36, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        let name = NSTextField(labelWithString: os.displayName)
        name.font = .preferredFont(forTextStyle: .headline)
        name.alignment = .center
        name.isSelectable = false

        let description = NSTextField(wrappingLabelWithString: Self.description(for: os))
        description.font = .preferredFont(forTextStyle: .caption1)
        description.textColor = .secondaryLabelColor
        description.alignment = .center
        description.maximumNumberOfLines = 0
        description.isSelectable = false
        // Wrap within the card instead of forcing an unbounded single-line width
        // (a card is roughly half the step width minus padding).
        description.preferredMaxLayoutWidth = 200
        description.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [icon, name, description])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 12

        let card = WizardSelectableCardView(content: content)
        card.onClick = { [weak self] in
            self?.select(os)
        }
        cards[os] = card
        cardIcons[os] = icon
        return card
    }

    private func select(_ os: VMGuestOS) {
        creationVM.selectedOS = os
        updateSelection()
    }

    private func updateSelection() {
        for (os, card) in cards {
            let isSelected = os == creationVM.selectedOS
            card.isSelected = isSelected
            cardIcons[os]?.contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        }
    }
}
