import AppKit

/// What an overview card asks the settings pane to do.
@MainActor
protocol VMSettingsOverviewDelegate: AnyObject {
    func overview(_ vc: VMSettingsOverviewViewController, didSelect category: VMSettingsCategory)
    func overview(_ vc: VMSettingsOverviewViewController, didSet toggle: VMOverviewToggle, to isOn: Bool)
    func overview(_ vc: VMSettingsOverviewViewController, didInvoke action: VMOverviewAction)
}

/// The detail pane's overview: one card per ``VMSettingsCategory``, stacked down
/// the pane's column in category order, each stating the category's current
/// facts and offering the drill-in to its panel.
///
/// Holds no VM state — ``configure(instance:isReadOnly:resolved:)`` paints every
/// card from the model on the settings pane's own refresh pass.
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

    /// (Re)builds the cards for `instance`, whose guest OS decides the switches
    /// they hold — the one thing about a VM that changes a card's structure.
    func rebuild(instance: VMInstance) {
        loadViewIfNeeded()
        let guestOS = instance.configuration.guestOS
        guard builtGuestOS != guestOS else { return }
        builtGuestOS = guestOS
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        cards.removeAll()
        for category in VMSettingsCategory.allCases {
            let card = makeCard(for: category, instance: instance)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func makeCard(for category: VMSettingsCategory, instance: VMInstance)
        -> VMOverviewCardView
    {
        let toggles = VMOverviewSummary.toggles(for: category, instance: instance).map(\.toggle)
        let card = VMOverviewCardView(category: category, toggles: toggles)
        card.onShow = { [weak self] in
            guard let self else { return }
            self.delegate?.overview(self, didSelect: category)
        }
        card.onToggle = { [weak self] toggle, isOn in
            guard let self else { return }
            self.delegate?.overview(self, didSet: toggle, to: isOn)
        }
        card.onAction = { [weak self] action in
            guard let self else { return }
            self.delegate?.overview(self, didInvoke: action)
        }
        cards[category] = card
        return card
    }

    /// Paints every card from the model.
    func configure(instance: VMInstance, isReadOnly: Bool, resolved: VMOverviewResolved) {
        rebuild(instance: instance)
        for category in cards.keys {
            configureCard(category, instance: instance, isReadOnly: isReadOnly, resolved: resolved)
        }
    }

    /// Paints one card, for an async read that moved only that category's value.
    func configureCard(
        _ category: VMSettingsCategory, instance: VMInstance, isReadOnly: Bool,
        resolved: VMOverviewResolved
    ) {
        guard let card = cards[category] else { return }
        card.configure(
            rows: VMOverviewSummary.rows(for: category, instance: instance, resolved: resolved),
            toggles: VMOverviewSummary.toggles(for: category, instance: instance),
            note: VMOverviewSummary.note(for: category, instance: instance),
            action: VMOverviewSummary.action(for: category, resolved: resolved),
            headerSummary: VMOverviewSummary.headerSummary(
                for: category, instance: instance, resolved: resolved),
            // The claim is scoped to the rows that actually lock, so it stands
            // beside the live controls on the same card.
            showsLockHint: isReadOnly && category.lockHint != nil,
            warning: resolved.warnings[category])
    }

    #if DEBUG
    /// The card for `category`, so tests can reach its controls.
    func cardForTesting(_ category: VMSettingsCategory) -> VMOverviewCardView? { cards[category] }
    #endif
}
