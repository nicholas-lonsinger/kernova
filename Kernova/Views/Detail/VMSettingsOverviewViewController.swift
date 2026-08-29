import AppKit

/// What an overview card asks the settings pane to do.
@MainActor
protocol VMSettingsOverviewDelegate: AnyObject {
    func overview(_ vc: VMSettingsOverviewViewController, didSelect category: VMSettingsCategory)
    func overview(_ vc: VMSettingsOverviewViewController, didSet toggle: VMOverviewToggle, to isOn: Bool)
    func overview(_ vc: VMSettingsOverviewViewController, didInvoke action: VMOverviewAction)
}

/// The detail pane's overview: one card per ``VMSettingsCategory``, each stating
/// the category's current facts and offering the drill-in to its panel.
///
/// The cards pair off two to a row in category order, so the whole set reads
/// without scrolling on the capped column the pane already lays out.
///
/// Holds no VM state — ``configure(instance:isReadOnly:resolved:)`` paints every
/// card from the model on the settings pane's own refresh pass.
@MainActor
final class VMSettingsOverviewViewController: NSViewController {
    /// Gap between the two cards on a row.
    private static let gutter = Spacing.large

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
        let built = VMSettingsCategory.allCases.map { makeCard(for: $0, instance: instance) }
        for pair in stride(from: 0, to: built.count, by: 2) {
            addRow(Array(built[pair..<min(pair + 2, built.count)]))
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

    /// Lays one pair of cards side by side: equal widths, tops aligned, heights
    /// left to each card's own content.
    private func addRow(_ rowCards: [VMOverviewCardView]) {
        let row = NSStackView(views: rowCards)
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fillEqually
        row.spacing = Self.gutter
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// Paints every card from the model.
    func configure(instance: VMInstance, isReadOnly: Bool, resolved: VMOverviewResolved) {
        rebuild(instance: instance)
        for (category, card) in cards {
            card.configure(
                rows: VMOverviewSummary.rows(
                    for: category, instance: instance, resolved: resolved),
                toggles: VMOverviewSummary.toggles(for: category, instance: instance),
                note: VMOverviewSummary.note(for: category, instance: instance),
                action: VMOverviewSummary.action(for: category, resolved: resolved),
                headerSummary: VMOverviewSummary.headerSummary(
                    for: category, instance: instance, resolved: resolved),
                // The claim is scoped to the rows that actually lock, so it
                // stands beside the live controls on the same card.
                showsLockHint: isReadOnly && category.lockHint != nil,
                warning: resolved.warnings[category])
        }
    }

    #if DEBUG
    /// The card for `category`, so tests can reach its controls.
    func cardForTesting(_ category: VMSettingsCategory) -> VMOverviewCardView? { cards[category] }
    #endif
}
