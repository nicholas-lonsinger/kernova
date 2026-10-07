import AppKit
import KernovaKit

/// The library section's filter, group and sort menu — what its header's
/// filter button and a right-click on the header open.
///
/// Each pickable item carries the ``SidebarViewOptions`` picking it produces,
/// so the menu is a pure function of the options and the library it is built
/// over, and a pick only hands those options to ``apply``.
@MainActor
final class SidebarViewMenu: NSObject {
    /// One library entry as the menu counts it.
    struct Value {
        let subject: VMLibraryFilter.Subject
        /// What the entry's network reads as, which titles its Network
        /// submenu row.
        let networkTitle: String
    }

    /// What an item's pick sets the options to.
    final class Pick: NSObject {
        let options: SidebarViewOptions

        init(_ options: SidebarViewOptions) {
            self.options = options
        }
    }

    static let accessibilityLabel = "Filter and Sort"

    private let apply: (SidebarViewOptions) -> Void
    /// What a network the filter names reads as once no VM is on it.
    private let networkTitle: (VMLibraryFilter.Network) -> String

    init(
        networkTitle: @escaping (VMLibraryFilter.Network) -> String,
        apply: @escaping (SidebarViewOptions) -> Void
    ) {
        self.networkTitle = networkTitle
        self.apply = apply
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick else { return }
        apply(pick.options)
    }

    // MARK: - Menu

    /// The menu for `options` over a library of `values`, whose counts are
    /// over every one of them whatever the filter admits.
    func menu(options: SidebarViewOptions, values: [Value]) -> NSMenu {
        let menu = NSMenu(title: Self.accessibilityLabel)
        menu.autoenablesItems = false
        let filter = options.filter
        for attribute in attributes(of: options, values: values) {
            let item = NSMenuItem(title: attribute.title, action: nil, keyEquivalent: "")
            item.badge = NSMenuItemBadge(string: attribute.summary)
            let submenu = NSMenu(title: attribute.title)
            submenu.autoenablesItems = false
            submenu.addItem(
                pickItem(attribute.allTitle, state: attribute.isActive ? .off : .on, options: attribute.cleared))
            submenu.addItem(.separator())
            for choice in attribute.choices {
                let choiceItem = pickItem(choice.title, state: choice.isOn ? .on : .off, options: choice.picked)
                choiceItem.badge = NSMenuItemBadge(count: choice.count)
                submenu.addItem(choiceItem)
            }
            item.submenu = submenu
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(
            choiceMenu(
                "Group By", current: options.grouping, cases: [.guestOS, .state, .network], trailing: .none,
                title: \.title
            ) { grouping in
                var picked = options
                picked.grouping = grouping
                return picked
            })
        menu.addItem(
            choiceMenu(
                "Sort By", current: options.sort, cases: [.name, .dateCreated], trailing: .manual,
                title: \.title
            ) { sort in
                var picked = options
                picked.sort = sort
                return picked
            })

        menu.addItem(.separator())
        var toggledDetails = options
        toggledDetails.showsDetails.toggle()
        menu.addItem(
            pickItem("Show Details", state: options.showsDetails ? .on : .off, options: toggledDetails))

        menu.addItem(.separator())
        var cleared = options
        cleared.filter = VMLibraryFilter()
        let clear = pickItem("Clear Filters", state: .off, options: cleared)
        clear.isEnabled = filter.isActive
        menu.addItem(clear)
        return menu
    }

    /// The active filters, as the filter button's accessibility value names
    /// them — `nil` when none is.
    func activeFilterDescription(options: SidebarViewOptions, values: [Value]) -> String? {
        let active = attributes(of: options, values: values).filter(\.isActive)
        guard !active.isEmpty else { return nil }
        return active.map { "\($0.title): \($0.summary)" }.joined(separator: ", ")
    }

    private func pickItem(
        _ title: String, state: NSControl.StateValue, options: SidebarViewOptions
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
        item.target = self
        item.state = state
        item.representedObject = Pick(options)
        return item
    }

    /// A row whose submenu picks one of `cases`, then `trailing` below a
    /// separator.
    private func choiceMenu<Choice: Equatable>(
        _ title: String, current: Choice, cases: [Choice], trailing: Choice,
        title choiceTitle: (Choice) -> String, picking: (Choice) -> SidebarViewOptions
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.badge = NSMenuItemBadge(string: choiceTitle(current))
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        for choice in cases {
            submenu.addItem(
                pickItem(choiceTitle(choice), state: choice == current ? .on : .off, options: picking(choice)))
        }
        submenu.addItem(.separator())
        submenu.addItem(
            pickItem(choiceTitle(trailing), state: trailing == current ? .on : .off, options: picking(trailing)))
        item.submenu = submenu
        return item
    }

    // MARK: - Attributes

    /// One filter attribute's row: its title, the value it shows trailing, and
    /// the choices its submenu lists.
    private struct Attribute {
        struct Choice {
            let title: String
            let count: Int
            let isOn: Bool
            let picked: SidebarViewOptions
        }

        let title: String
        let allTitle: String
        let isActive: Bool
        let cleared: SidebarViewOptions
        let choices: [Choice]

        /// "All", the one choice that is on, or how many are.
        var summary: String {
            let on = choices.filter(\.isOn)
            guard isActive else { return "All" }
            return on.count == 1 ? on[0].title : "\(on.count) Selected"
        }
    }

    private func attributes(of options: SidebarViewOptions, values: [Value]) -> [Attribute] {
        let filter = options.filter
        func with(_ change: (inout VMLibraryFilter) -> Void) -> SidebarViewOptions {
            var picked = options
            change(&picked.filter)
            return picked
        }
        func toggled<Element>(_ set: Set<Element>, _ element: Element) -> Set<Element> {
            set.contains(element) ? set.subtracting([element]) : set.union([element])
        }

        let guestOS = Attribute(
            title: "Guest OS", allTitle: "All Guest OSes", isActive: !filter.guestOSes.isEmpty,
            cleared: with { $0.guestOSes = [] },
            choices: VMGuestOS.allCases.map { os in
                Attribute.Choice(
                    title: os.displayName, count: values.count { $0.subject.guestOS == os },
                    isOn: filter.guestOSes.contains(os),
                    picked: with { $0.guestOSes = toggled($0.guestOSes, os) })
            })
        // One state at a time: picking one replaces the last.
        let state = Attribute(
            title: "State", allTitle: "All States", isActive: !filter.states.isEmpty,
            cleared: with { $0.states = [] },
            choices: VMStateBucket.allCases.map { bucket in
                Attribute.Choice(
                    title: bucket.displayName, count: values.count { $0.subject.state == bucket },
                    isOn: filter.states.contains(bucket),
                    picked: with { $0.states = [bucket] })
            })
        let network = Attribute(
            title: "Network", allTitle: "All Networks", isActive: !filter.networks.isEmpty,
            cleared: with { $0.networks = [] },
            choices: networkChoices(filter: filter, values: values).map { choice in
                Attribute.Choice(
                    title: choice.title, count: choice.count, isOn: filter.networks.contains(choice.network),
                    picked: with { $0.networks = toggled($0.networks, choice.network) })
            })
        let guestAgent = Attribute(
            title: "Guest Agent", allTitle: "All", isActive: !filter.guestAgents.isEmpty,
            cleared: with { $0.guestAgents = [] },
            choices: VMGuestAgentBucket.allCases.map { bucket in
                Attribute.Choice(
                    title: bucket.displayName, count: values.count { $0.subject.guestAgent == bucket },
                    isOn: filter.guestAgents.contains(bucket),
                    picked: with { $0.guestAgents = toggled($0.guestAgents, bucket) })
            })
        let other = Attribute(
            title: "Other", allTitle: "All", isActive: filter.ephemeralOnly || filter.withSnapshotsOnly,
            cleared: with {
                $0.ephemeralOnly = false
                $0.withSnapshotsOnly = false
            },
            choices: [
                Attribute.Choice(
                    title: "Ephemeral Mode", count: values.count(where: \.subject.isEphemeral),
                    isOn: filter.ephemeralOnly, picked: with { $0.ephemeralOnly.toggle() }),
                Attribute.Choice(
                    title: "Has Snapshots", count: values.count(where: \.subject.hasSnapshots),
                    isOn: filter.withSnapshotsOnly, picked: with { $0.withSnapshotsOnly.toggle() }),
            ])
        return [guestOS, state, network, guestAgent, other]
    }

    /// The Network submenu's choices: one per network the library's VMs are
    /// on — every network the library does not list being one — in the Mode
    /// picker's order. A network the filter names but no VM is on any more
    /// stays listed, so it can be turned off.
    private func networkChoices(
        filter: VMLibraryFilter, values: [Value]
    ) -> [(network: VMLibraryFilter.Network, title: String, count: Int)] {
        var order: [VMLibraryFilter.Network] = []
        var byNetwork: [VMLibraryFilter.Network: (title: String, count: Int)] = [:]
        for value in values {
            let network = value.subject.network
            if byNetwork[network] == nil { order.append(network) }
            byNetwork[network, default: (value.networkTitle, 0)].count += 1
        }
        for orphan in filter.networks where byNetwork[orphan] == nil {
            order.append(orphan)
            byNetwork[orphan] = (networkTitle(orphan), 0)
        }
        return order.compactMap { network in byNetwork[network].map { (network, $0.title, $0.count) } }
            .sorted { lhs, rhs in
                let left = SidebarLayout.networkRank(lhs.network)
                let right = SidebarLayout.networkRank(rhs.network)
                return left != right
                    ? left < right : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }
}
