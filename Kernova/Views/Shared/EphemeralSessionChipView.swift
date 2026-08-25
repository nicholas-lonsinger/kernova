import AppKit

/// The marker a VM carries while it is running a session its baseline will
/// discard: a small revert glyph and the word "Ephemeral", in the warning tint.
/// Click opens the mode's info popover.
///
/// `drawsCapsule` decides whether the chip supplies its own tinted capsule. A
/// titlebar accessory sits on bare titlebar and needs one; a toolbar item is
/// already drawn on a glass platter capsule (docs/TOOLBAR.md), and a second
/// capsule inside that one reads as a platter containing a pill — so the
/// toolbar host turns it off and lets the platter be the capsule, the way every
/// other toolbar item presents.
@MainActor
final class EphemeralSessionChipView: NSView {
    private static let tint = NSColor.systemOrange
    private static let horizontalPadding: CGFloat = 8
    private static let height: CGFloat = 20

    private let button = NSButton()
    private let popoverPresenter = PopoverPresenter()

    init(drawsCapsule: Bool = true) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let capsule = NSView()
        capsule.translatesAutoresizingMaskIntoConstraints = false
        if drawsCapsule {
            capsule.wantsLayer = true
            capsule.layer?.cornerRadius = Self.height / 2
            capsule.layer?.backgroundColor = Self.tint.withAlphaComponent(0.18).cgColor
        }
        // Decorative: the button above it takes every click.
        addSubview(capsule)

        let icon = NSImageView(
            image: .systemSymbol(
                EphemeralModeCopy.chipSymbolName,
                accessibilityDescription: EphemeralModeCopy.badgeHelpText))
        icon.symbolConfiguration = NSImage.SymbolConfiguration(scale: .small)
        icon.contentTintColor = Self.tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: EphemeralModeCopy.name)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = Self.tint
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)

        let content = NSStackView(views: [icon, label])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Spacing.hairline * 2
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        // A transparent button over the whole chip, so the click target is the
        // capsule rather than only the glyph.
        button.translatesAutoresizingMaskIntoConstraints = false
        button.title = ""
        button.isBordered = false
        button.isTransparent = true
        button.toolTip = EphemeralModeCopy.badgeHelpText
        button.setAccessibilityLabel(EphemeralModeCopy.badgeHelpText)
        button.target = self
        button.action = #selector(chipTapped(_:))
        addSubview(button)

        // Without a capsule of its own the chip is content, not a pill: the
        // platter behind it already supplies the margin.
        let padding = drawsCapsule ? Self.horizontalPadding : 0
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor),
            capsule.topAnchor.constraint(equalTo: topAnchor),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EphemeralSessionChipView does not support NSCoder")
    }

    /// Dismisses the popover — for a window losing the chip while it is open.
    func reset() {
        popoverPresenter.close()
    }

    @objc private func chipTapped(_: NSButton) {
        if popoverPresenter.isShown {
            popoverPresenter.close()
        } else {
            popoverPresenter.show(
                content: InfoPopoverContentViewController(
                    paragraphs: EphemeralModeCopy.popoverParagraphs),
                from: self, preferredEdge: .minY)
        }
    }
}

/// Hosts the running Ephemeral chip inside a toolbar item, for a window whose
/// titlebar has no slot beside the title.
///
/// A titlebar accessory cannot land next to the title on a window with a
/// sidebar: `NSTitlebarAccessoryViewController` offers no "beside the title"
/// attribute, and `.leading` resolves to the leading edge of the *window* — the
/// sidebar region. The sidebar section cannot hold it either: that section is
/// sized by the sidebar, so a chip wider than the current sidebar width is sent
/// to the overflow menu. The host is a toolbar item at the head of the *content*
/// region instead, which is where a unified toolbar draws the window title, with
/// a flexible space after it so the rest of the items keep packing trailing.
///
/// The chip draws no capsule of its own here — the item's glass platter is the
/// capsule (`docs/TOOLBAR.md`).
@MainActor
final class EphemeralChipToolbarHost: NSView {
    private let chip = EphemeralSessionChipView(drawsCapsule: false)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(chip)
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: leadingAnchor),
            chip.trailingAnchor.constraint(equalTo: trailingAnchor),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EphemeralChipToolbarHost does not support NSCoder")
    }

    /// Dismisses the popover, for the item being taken out of the toolbar.
    func reset() {
        chip.reset()
    }
}

/// Adds and removes the running Ephemeral chip in one window's titlebar.
///
/// For a window with no sidebar, where `.leading` puts the accessory between
/// the traffic lights and the title — the placement the design asks for. A
/// window with a sidebar uses ``EphemeralChipToolbarHost`` instead.
///
/// Owned by a window controller, which calls ``update(isVisible:)`` from the
/// same observation pass that refreshes its toolbar.
@MainActor
final class EphemeralChipTitlebarController {
    private weak var window: NSWindow?
    private let chip = EphemeralSessionChipView()
    private var accessory: NSTitlebarAccessoryViewController?

    init(window: NSWindow?) {
        self.window = window
    }

    /// Vertical room around the chip inside the titlebar row.
    private static let verticalInset: CGFloat = 4

    /// Shows or hides the chip, doing nothing when it is already in that state.
    func update(isVisible: Bool) {
        guard isVisible != (accessory != nil) else { return }
        if isVisible {
            let controller = NSTitlebarAccessoryViewController()
            // `.leading` puts the accessory at the head of the titlebar row,
            // beside the window title; `.right` lands it past the toolbar's
            // trailing items, away from the name it qualifies.
            controller.layoutAttribute = .leading
            controller.view = makeAccessoryView()
            window?.addTitlebarAccessoryViewController(controller)
            accessory = controller
            return
        }
        chip.reset()
        if let accessory, let window,
            let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory)
        {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        accessory = nil
    }

    /// The accessory's root view, sized to the chip it holds.
    ///
    /// The titlebar positions an accessory's root view itself rather than
    /// constraining it, so that view has to carry a real `frame` — one left on
    /// Auto Layout with no external constraints to satisfy resolves to zero and
    /// the chip never appears. The chip inside is still laid out by its own
    /// constraints against this container.
    private func makeAccessoryView() -> NSView {
        let container = NSView()
        // Measured on Auto Layout, then handed back to its frame: leaving the
        // generated size constraints in place while the frame is still zero
        // would fight the chip's own pins during the measurement.
        container.translatesAutoresizingMaskIntoConstraints = false
        chip.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chip)
        let inset = Self.verticalInset
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Spacing.small),
            chip.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Spacing.small),
            chip.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            chip.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
        let size = container.fittingSize
        container.translatesAutoresizingMaskIntoConstraints = true
        container.frame = NSRect(origin: .zero, size: size)
        return container
    }
}
