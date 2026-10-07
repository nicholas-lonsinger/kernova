import AppKit
import KernovaKit

/// The menus a sidebar section's header opens — from its button or a
/// right-click: the library section's filter, group and sort menu, a smart
/// group's own filter menu, and a folder's menu — and the folder items of a
/// VM row's menu.
///
/// Each item carries the ``Command`` picking it runs, so a menu is a pure
/// function of what it is built over, and a pick only hands its command to
/// ``perform``.
@MainActor
final class SidebarViewMenu: NSObject {
    /// One library entry as the menu counts it.
    struct Value {
        let subject: VMLibraryFilter.Subject
        /// What the entry's network reads as, which titles its Network
        /// submenu row.
        let networkTitle: String
    }

    /// What picking an item does.
    enum Command: Equatable {
        /// Sets the library section's options.
        case setOptions(SidebarViewOptions)
        /// Asks for a name to save the library section's filter under as a
        /// smart group.
        case saveAsSmartGroup
        /// Sets the filter of the smart group the identifier names.
        case setSmartGroupFilter(UUID, VMLibraryFilter)
        /// Asks for a new name for the smart group the identifier names.
        case renameSmartGroup(UUID)
        /// Deletes the smart group the identifier names.
        case deleteSmartGroup(UUID)
        /// Asks for a name for a new folder, which then holds the entry
        /// `adding` names, if any.
        case newFolder(adding: UUID?)
        /// Asks for a new name for the folder the identifier names.
        case renameFolder(UUID)
        /// Asks before deleting the folder the identifier names, which keeps
        /// its VMs.
        case deleteFolder(UUID)
        /// Puts the entry `entry` in the folder `folder`, or takes it out.
        case setMembership(entry: UUID, folder: UUID, isMember: Bool)
        /// Takes `action` on every VM in `group`.
        case groupAction(VMGroupAction, VMGroupReference)
    }

    /// An item's command, as its represented object.
    final class Pick: NSObject {
        let command: Command

        init(_ command: Command) {
            self.command = command
        }
    }

    nonisolated static let accessibilityLabel = "Filter and Sort"
    nonisolated static let smartGroupAccessibilityLabel = "Smart Group Options"
    nonisolated static let folderAccessibilityLabel = "Folder Options"

    private let perform: (Command) -> Void
    /// What a network the filter names reads as once no VM is on it.
    private let networkTitle: (VMLibraryFilter.Network) -> String

    init(
        networkTitle: @escaping (VMLibraryFilter.Network) -> String,
        perform: @escaping (Command) -> Void
    ) {
        self.networkTitle = networkTitle
        self.perform = perform
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick else { return }
        perform(pick.command)
    }

    // MARK: - Menus

    /// The library section's menu for `options` over a library of `values`,
    /// whose counts are over every one of them whatever the filter admits.
    func menu(options: SidebarViewOptions, values: [Value]) -> NSMenu {
        let menu = NSMenu(title: Self.accessibilityLabel)
        menu.autoenablesItems = false
        let filter = options.filter
        addFilterRows(
            to: menu, filter: filter, values: values,
            picking: { picked in
                var changed = options
                changed.filter = picked
                return .setOptions(changed)
            })

        menu.addItem(.separator())
        menu.addItem(
            choiceMenu(
                "Group By", current: options.grouping, cases: [.guestOS, .state, .network], trailing: .none,
                title: \.title
            ) { grouping in
                var picked = options
                picked.grouping = grouping
                return .setOptions(picked)
            })
        menu.addItem(
            choiceMenu(
                "Sort By", current: options.sort, cases: [.name, .dateCreated], trailing: .manual,
                title: \.title
            ) { sort in
                var picked = options
                picked.sort = sort
                return .setOptions(picked)
            })

        menu.addItem(.separator())
        var toggledDetails = options
        toggledDetails.showsDetails.toggle()
        menu.addItem(
            pickItem("Show Details", state: options.showsDetails ? .on : .off, command: .setOptions(toggledDetails)))

        menu.addItem(.separator())
        let save = pickItem("Save as Smart Group\u{2026}", state: .off, command: .saveAsSmartGroup)
        save.isEnabled = filter.isActive
        menu.addItem(save)
        menu.addItem(pickItem("New Folder\u{2026}", state: .off, command: .newFolder(adding: nil)))
        var cleared = options
        cleared.filter = VMLibraryFilter()
        let clear = pickItem("Clear Filters", state: .off, command: .setOptions(cleared))
        clear.isEnabled = filter.isActive
        menu.addItem(clear)
        return menu
    }

    /// `group`'s menu over a library of `values`: its filter's rows, the
    /// group actions with `actionCounts` VMs each acts on, then Rename and
    /// Delete.
    func menu(smartGroup group: VMSmartGroup, values: [Value], actionCounts: [VMGroupAction: Int]?) -> NSMenu {
        let menu = NSMenu(title: Self.smartGroupAccessibilityLabel)
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Show VMs in \u{201C}\(group.name)\u{201D} where"))
        addFilterRows(
            to: menu, filter: group.filter, values: values,
            picking: { .setSmartGroupFilter(group.id, $0) })
        menu.addItem(.separator())
        addGroupActions(
            to: menu, group: VMGroupReference(.smartGroup, named: group.id.uuidString), counts: actionCounts)
        menu.addItem(.separator())
        menu.addItem(pickItem("Rename Smart Group\u{2026}", state: .off, command: .renameSmartGroup(group.id)))
        menu.addItem(pickItem("Delete Smart Group", state: .off, command: .deleteSmartGroup(group.id)))
        return menu
    }

    /// `folder`'s menu: what its section takes, the group actions with
    /// `actionCounts` VMs each acts on, then Rename and Delete.
    func menu(folder: VMFolder, actionCounts: [VMGroupAction: Int]?) -> NSMenu {
        let menu = NSMenu(title: Self.folderAccessibilityLabel)
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "\u{201C}\(folder.name)\u{201D} \u{2014} drag VMs here to add them"))
        addGroupActions(to: menu, group: VMGroupReference(.folder, named: folder.id.uuidString), counts: actionCounts)
        menu.addItem(.separator())
        menu.addItem(pickItem("Rename Folder\u{2026}", state: .off, command: .renameFolder(folder.id)))
        menu.addItem(pickItem("Delete Folder", state: .off, command: .deleteFolder(folder.id)))
        return menu
    }

    /// Start All, Suspend All and Stop All for `group`, each counting the VMs
    /// it acts on in `counts` and enabled while that is not zero — every one
    /// disabled when the counts could not be read.
    private func addGroupActions(to menu: NSMenu, group: VMGroupReference, counts: [VMGroupAction: Int]?) {
        for action in VMGroupAction.allCases {
            let count = counts?[action] ?? 0
            let item = pickItem(Self.groupActionTitle(action), state: .off, command: .groupAction(action, group))
            item.isEnabled = count > 0
            if count > 0 { item.badge = NSMenuItemBadge(count: count) }
            menu.addItem(item)
        }
    }

    /// What a group action's menu item is called.
    static func groupActionTitle(_ action: VMGroupAction) -> String {
        switch action {
        case .start: "Start All"
        case .suspend: "Suspend All"
        case .stop: "Stop All"
        }
    }

    // MARK: - VM row items

    /// A VM row's Add to Folder item for the entry `entry`: a submenu listing
    /// each of `folders`, checked where it holds the entry and each pick
    /// toggling that, then New Folder….
    func addToFolderItem(entry: UUID, folders: [VMFolder]) -> NSMenuItem {
        let item = NSMenuItem(title: "Add to Folder", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Add to Folder")
        submenu.autoenablesItems = false
        for folder in folders {
            let isMember = folder.members.contains(entry)
            submenu.addItem(
                pickItem(
                    folder.name, state: isMember ? .on : .off,
                    command: .setMembership(entry: entry, folder: folder.id, isMember: !isMember)))
        }
        if !folders.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(pickItem("New Folder\u{2026}", state: .off, command: .newFolder(adding: entry)))
        item.submenu = submenu
        return item
    }

    /// A row's Remove from Folder item, taking the entry `entry` out of the
    /// folder `folder` its section lists.
    func removeFromFolderItem(entry: UUID, folder: UUID) -> NSMenuItem {
        pickItem(
            "Remove from Folder", state: .off, command: .setMembership(entry: entry, folder: folder, isMember: false))
    }

    // MARK: - Descriptions

    /// `filter`'s active attributes, as a header button's accessibility value
    /// names them — `nil` when none is.
    func activeFilterDescription(filter: VMLibraryFilter, values: [Value]) -> String? {
        let active = attributes(of: filter, values: values).filter(\.isActive)
        guard !active.isEmpty else { return nil }
        return active.map { "\($0.title): \($0.summary)" }.joined(separator: ", ")
    }

    /// One sentence per attribute `filter` constrains — "Guest OS is macOS",
    /// "State is Running or Suspended" — and one per flag it sets.
    func conditions(of filter: VMLibraryFilter, values: [Value]) -> [String] {
        attributes(of: filter, values: values).filter(\.isActive).flatMap { attribute in
            let on = attribute.choices.filter(\.isOn).map(\.title)
            guard attribute.isPredicate else { return on }
            let either =
                on.count <= 2
                ? on.joined(separator: " or ")
                : on.dropLast().joined(separator: ", ") + ", or " + (on.last ?? "")
            return ["\(attribute.title) is \(either)"]
        }
    }

    /// What a smart group of `filter` is named until the user names it: each
    /// attribute that picks one value, in menu order, joined by "·" — or
    /// "Smart Group" when none does. Flags (Other) name nothing.
    func suggestedName(for filter: VMLibraryFilter, values: [Value]) -> String {
        let picked = attributes(of: filter, values: values).compactMap { attribute -> String? in
            let on = attribute.choices.filter(\.isOn)
            return attribute.isPredicate && attribute.isActive && on.count == 1 ? on[0].title : nil
        }
        return picked.isEmpty ? "Smart Group" : picked.joined(separator: " \u{00B7} ")
    }

    private func addFilterRows(
        to menu: NSMenu, filter: VMLibraryFilter, values: [Value],
        picking: (VMLibraryFilter) -> Command
    ) {
        for attribute in attributes(of: filter, values: values) {
            let item = NSMenuItem(title: attribute.title, action: nil, keyEquivalent: "")
            item.badge = NSMenuItemBadge(string: attribute.summary)
            let submenu = NSMenu(title: attribute.title)
            submenu.autoenablesItems = false
            submenu.addItem(
                pickItem(
                    attribute.allTitle, state: attribute.isActive ? .off : .on,
                    command: picking(attribute.cleared)))
            submenu.addItem(.separator())
            for choice in attribute.choices {
                let choiceItem = pickItem(
                    choice.title, state: choice.isOn ? .on : .off, command: picking(choice.picked))
                choiceItem.badge = NSMenuItemBadge(count: choice.count)
                submenu.addItem(choiceItem)
            }
            item.submenu = submenu
            menu.addItem(item)
        }
    }

    private func pickItem(_ title: String, state: NSControl.StateValue, command: Command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
        item.target = self
        item.state = state
        item.representedObject = Pick(command)
        return item
    }

    /// A row whose submenu picks one of `cases`, then `trailing` below a
    /// separator.
    private func choiceMenu<Choice: Equatable>(
        _ title: String, current: Choice, cases: [Choice], trailing: Choice,
        title choiceTitle: (Choice) -> String, picking: (Choice) -> Command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.badge = NSMenuItemBadge(string: choiceTitle(current))
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        for choice in cases {
            submenu.addItem(
                pickItem(choiceTitle(choice), state: choice == current ? .on : .off, command: picking(choice)))
        }
        submenu.addItem(.separator())
        submenu.addItem(
            pickItem(choiceTitle(trailing), state: trailing == current ? .on : .off, command: picking(trailing)))
        item.submenu = submenu
        return item
    }

    // MARK: - Attributes

    /// One filter attribute's row: its title, the value it shows trailing, and
    /// the choices its submenu lists, each with the filter picking it makes.
    private struct Attribute {
        struct Choice {
            let title: String
            let count: Int
            let isOn: Bool
            let picked: VMLibraryFilter
        }

        let title: String
        let allTitle: String
        let isActive: Bool
        /// Whether its choices are values the attribute takes ("Guest OS is
        /// macOS") rather than flags of their own (Other).
        var isPredicate = true
        let cleared: VMLibraryFilter
        let choices: [Choice]

        /// "All", the one choice that is on, or how many are.
        var summary: String {
            let on = choices.filter(\.isOn)
            guard isActive else { return "All" }
            return on.count == 1 ? on[0].title : "\(on.count) Selected"
        }
    }

    private func attributes(of filter: VMLibraryFilter, values: [Value]) -> [Attribute] {
        func with(_ change: (inout VMLibraryFilter) -> Void) -> VMLibraryFilter {
            var picked = filter
            change(&picked)
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
            isPredicate: false,
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
