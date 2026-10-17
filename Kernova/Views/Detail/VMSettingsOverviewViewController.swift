import AppKit
import KernovaCore
import KernovaKit

/// The detail pane's overview: one card per ``VMSettingsCategory``, stacked down
/// the pane's column in category order, each stating the category's current
/// facts and offering the drill-in to its panel.
///
/// Holds no VM state — ``configure(instance:resolved:)`` paints every
/// card from the model on the settings pane's own refresh pass.
@MainActor
final class VMSettingsOverviewViewController: NSViewController {
    /// Fires when a card's header row or Edit button is activated.
    var onShow: ((VMSettingsCategory) -> Void)?
    /// Fires when one of a card's switches is flipped.
    var onToggle: ((VMOverviewToggle, Bool) -> Void)?
    /// Fires when a card's foot command is run.
    var onAction: ((VMOverviewAction) -> Void)?

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
        let toggles = VMOverviewSummary.toggleKinds(
            for: category, guestOS: instance.configuration.guestOS)
        let card = VMOverviewCardView(category: category, toggles: toggles)
        card.onShow = { [weak self] in self?.onShow?(category) }
        card.onToggle = { [weak self] toggle, isOn in self?.onToggle?(toggle, isOn) }
        card.onAction = { [weak self] action in self?.onAction?(action) }
        cards[category] = card
        return card
    }

    /// Paints every card from the model, each switch enabled as `capabilities`
    /// answers.
    func configure(
        instance: VMInstance, resolved: VMOverviewResolved, capabilities: VMCapabilityCatalog
    ) {
        rebuild(instance: instance)
        for category in cards.keys {
            configureCard(
                category, instance: instance, resolved: resolved, capabilities: capabilities)
        }
    }

    /// Paints one card, for an async read that moved only that category's value.
    func configureCard(
        _ category: VMSettingsCategory, instance: VMInstance, resolved: VMOverviewResolved,
        capabilities: VMCapabilityCatalog
    ) {
        guard let card = cards[category] else { return }
        card.configure(
            rows: VMOverviewSummary.rows(for: category, instance: instance, resolved: resolved),
            toggles: VMOverviewSummary.toggles(
                for: category, instance: instance, capabilities: capabilities),
            note: VMOverviewSummary.note(for: category, instance: instance, resolved: resolved),
            action: VMOverviewSummary.action(for: category, resolved: resolved),
            headerSummary: VMOverviewSummary.headerSummary(for: category, instance: instance),
            warning: resolved.warnings[category])
    }

    #if DEBUG
    /// The card for `category`, so tests can reach its controls.
    func cardForTesting(_ category: VMSettingsCategory) -> VMOverviewCardView? { cards[category] }
    #endif
}
