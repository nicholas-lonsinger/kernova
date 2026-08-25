import AppKit

/// The titlebar marker a VM carries while it is running a session its baseline
/// will discard: a tinted capsule holding a small revert glyph and the word
/// "Ephemeral". Click opens the mode's info popover.
///
/// A titlebar accessory rather than an `NSToolbarItem`: the marker comes and
/// goes with the session, and a toolbar item that appears and disappears has to
/// be removed and re-inserted around the autosaved configuration
/// (docs/TOOLBAR.md) — where an accessory is neither customizable nor
/// autosaved, so it can simply be added and removed.
@MainActor
final class EphemeralSessionChipView: NSView {
    private static let tint = NSColor.systemOrange
    private static let horizontalPadding: CGFloat = 8
    private static let height: CGFloat = 20

    private let button = NSButton()
    private let popoverPresenter = PopoverPresenter()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        let capsule = NSView()
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.wantsLayer = true
        capsule.layer?.cornerRadius = Self.height / 2
        capsule.layer?.backgroundColor = Self.tint.withAlphaComponent(0.18).cgColor
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

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            capsule.leadingAnchor.constraint(equalTo: leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: trailingAnchor),
            capsule.topAnchor.constraint(equalTo: topAnchor),
            capsule.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: Self.horizontalPadding),
            content.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Self.horizontalPadding),
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
/// sidebar region, where it takes a toolbar item's slot and pushes that item
/// into the overflow menu. A toolbar item placed at the head of the content
/// region lands beside the title instead, because that is where a unified
/// toolbar draws it.
///
/// The item is never added or removed — `docs/TOOLBAR.md` documents what that
/// costs — so the chip collapses to zero width instead, leaving no slot behind.
@MainActor
final class EphemeralChipToolbarHost: NSView {
    private let chip = EphemeralSessionChipView()
    private lazy var widthConstraint = widthAnchor.constraint(equalToConstant: 0)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(chip)
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: leadingAnchor),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 28),
            widthConstraint,
        ])
        setChipVisible(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EphemeralChipToolbarHost does not support NSCoder")
    }

    /// Shows or collapses the chip.
    ///
    /// The chip is pinned by its leading edge alone, so its own intrinsic width
    /// governs it and this container's width is free to go to zero without
    /// fighting it.
    func setChipVisible(_ isVisible: Bool) {
        if !isVisible { chip.reset() }
        chip.isHidden = !isVisible
        widthConstraint.constant = isVisible ? chip.fittingSize.width : 0
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
