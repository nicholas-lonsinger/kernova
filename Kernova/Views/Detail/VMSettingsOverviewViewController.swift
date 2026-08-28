import AppKit

/// What an overview card asks the settings pane to do.
@MainActor
protocol VMSettingsOverviewDelegate: AnyObject {
    func overview(_ vc: VMSettingsOverviewViewController, didSelect category: VMSettingsCategory)
    func overview(_ vc: VMSettingsOverviewViewController, didSet toggle: VMOverviewToggle, to isOn: Bool)
}

/// The detail pane's overview: one card per ``VMSettingsCategory``, each stating
/// the category's current facts and offering the drill-in to its panel.
///
/// Holds no VM state — ``configure(instance:isReadOnly:networkIsLiveSwitchable:resolved:)``
/// paints every card from the model on the settings pane's own refresh pass.
@MainActor
final class VMSettingsOverviewViewController: NSViewController {
    weak var delegate: VMSettingsOverviewDelegate?

    private let stack = NSStackView()
    private var cards: [VMSettingsCategory: VMOverviewCardView] = [:]
    /// The guest OS the cards were built for; a different one changes which
    /// switches a card carries.
    private var builtGuestOS: VMGuestOS?

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.section
        stack.translatesAutoresizingMaskIntoConstraints = false
        view = stack
    }

    /// (Re)builds the cards for `guestOS`, which decides the switches they hold.
    func rebuild(guestOS: VMGuestOS) {
        loadViewIfNeeded()
        guard builtGuestOS != guestOS else { return }
        builtGuestOS = guestOS
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cards.removeAll()
        for category in VMSettingsCategory.allCases {
            let toggles = VMOverviewToggle.allCases.filter {
                $0.category == category && ($0 != .dropFiles || guestOS == .macOS)
            }
            let card = VMOverviewCardView(category: category, toggles: toggles)
            card.onShow = { [weak self] in
                guard let self else { return }
                self.delegate?.overview(self, didSelect: category)
            }
            card.onToggle = { [weak self] toggle, isOn in
                guard let self else { return }
                self.delegate?.overview(self, didSet: toggle, to: isOn)
            }
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            cards[category] = card
        }
    }

    /// Paints every card from the model.
    ///
    /// `networkIsLiveSwitchable` mirrors the Network panel's rule: a picker that
    /// hot-swaps while the VM runs makes the section's lock hint a false claim.
    func configure(
        instance: VMInstance, isReadOnly: Bool, networkIsLiveSwitchable: Bool,
        resolved: VMOverviewResolved
    ) {
        rebuild(guestOS: instance.configuration.guestOS)
        for (category, card) in cards {
            let locked =
                category.containsLockableRows && isReadOnly
                && !(category == .network && networkIsLiveSwitchable)
            card.configure(
                rows: VMOverviewSummary.rows(
                    for: category, instance: instance, resolved: resolved),
                toggles: VMOverviewSummary.toggles(for: category, instance: instance),
                showsLockHint: locked,
                warning: resolved.warnings[category])
        }
    }

    #if DEBUG
    /// The card for `category`, so tests can reach its controls.
    func cardForTesting(_ category: VMSettingsCategory) -> VMOverviewCardView? { cards[category] }
    #endif
}
