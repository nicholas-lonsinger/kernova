import AppKit
import KernovaKit

/// The menus a sidebar section's header opens — from its button or a
/// right-click: the library section's filter, group and sort menu, a smart
/// group's own filter menu, and a folder's menu — the folder and tag items of
/// a VM row's menu, and the View menu's sidebar items, built from the same
/// rows as the header menus.
///
/// Each item carries the ``Command`` picking it runs, so a menu is a pure
/// function of what it is built over, and a pick only hands its command to
/// ``perform``.
@MainActor
final class SidebarViewMenu: NSObject, NSMenuItemValidation {
    /// One library entry as the menu counts it.
    struct Value {
        let subject: VMLibraryFilter.Subject
        /// What the entry's network reads as, which titles its Network
        /// submenu row.
        let networkTitle: String
    }

    /// What picking an item does.
    enum Command: Equatable {
        /// Sets one of the library section's options, leaving the others as
        /// they stand when the pick lands.
        case editOptions(SidebarViewOptions.Edit)
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
        /// Puts the tag `tag` on the VM `entry`, or takes it off.
        case setTag(entry: UUID, tag: UUID, isAssigned: Bool)
        /// Opens the Settings pane that creates, renames, recolors and
        /// deletes the library's tags.
        case editTags
        /// Expands every sidebar section, or collapses every one.
        case setSectionsExpanded(Bool)
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
    /// How a filter names a tag it holds that the library no longer defines.
    nonisolated static let heldUndefinedTagTitle = "Tag No Longer in This Library"

    /// The orders Sort By lists above its separator; Manual is below it.
    nonisolated static let sortChoices = VMLibrarySort.allCases.filter { $0 != .manual }
    /// The modifiers every Sort By key equivalent is typed with, as Finder's
    /// View ▸ Sort By.
    nonisolated static let sortModifiers: NSEvent.ModifierFlags = [.control, .option, .command]

    /// `sort`'s key equivalent, typed with ``sortModifiers``: 0 for Manual,
    /// as Finder's None, and each other order its place in Sort By from 1 —
    /// none past the ninth.
    nonisolated static func sortKeyEquivalent(_ sort: VMLibrarySort) -> String {
        guard sort != .manual else { return "0" }
        guard let index = sortChoices.firstIndex(of: sort), index < 9 else { return "" }
        return String(index + 1)
    }

    /// What the View menu's route to the selected row's section is called
    /// for a section of `kind`.
    nonisolated static func groupKindTitle(_ kind: VMGroupKind) -> String {
        switch kind {
        case .smartGroup: "Smart Group"
        case .folder: "Folder"
        }
    }

    private let perform: (Command) -> Void
    /// What a network the filter names reads as once no VM is on it.
    private let networkTitle: (VMLibraryFilter.Network) -> String
    /// The library's tags, in their order.
    private let tags: () -> [VMTag]

    init(
        networkTitle: @escaping (VMLibraryFilter.Network) -> String,
        tags: @escaping () -> [VMTag],
        perform: @escaping (Command) -> Void
    ) {
        self.networkTitle = networkTitle
        self.tags = tags
        self.perform = perform
    }

    /// A menu over `viewModel`'s library and networks whose picks run
    /// `perform`.
    convenience init(viewModel: VMLibraryViewModel, perform: @escaping (Command) -> Void) {
        self.init(
            networkTitle: { [weak viewModel] network in
                SidebarLayout.heldNetworkTitle(network, networks: viewModel?.networks.state ?? .listed([]))
            },
            tags: { [weak viewModel] in viewModel?.library.tags ?? [] },
            perform: perform)
    }

    /// `viewModel`'s library as the menus count it: a bundle Kernova can't
    /// read holds none of the values they count.
    static func values(of viewModel: VMLibraryViewModel) -> [Value] {
        let context = viewModel.sidebarContext
        return viewModel.entries.compactMap { entry in
            guard let subject = context.subject(of: entry), let configuration = entry.configuration else {
                return nil
            }
            return Value(
                subject: subject,
                networkTitle: SidebarLayout.networkTitle(subject.network, of: configuration, context: context))
        }
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? Pick else { return }
        perform(pick.command)
    }

    /// An item's enablement is decided where it is built; a menu that
    /// autoenables its items — the View menu — keeps it.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.isEnabled
    }

    // MARK: - Menus

    /// The library section's menu for `options` over a library of `values`,
    /// whose counts are over every one of them whatever the filter admits.
    func menu(options: SidebarViewOptions, values: [Value]) -> NSMenu {
        let menu = NSMenu(title: Self.accessibilityLabel)
        menu.autoenablesItems = false
        for row in filterRows(filter: options.filter, values: values, picking: { .editOptions(.filter($0)) }) {
            menu.addItem(row)
        }
        menu.addItem(.separator())
        menu.addItem(groupByItem(options))
        menu.addItem(sortByItem(options))
        menu.addItem(.separator())
        menu.addItem(showDetailsItem(options))
        menu.addItem(.separator())
        let save = pickItem("Save as Smart Group\u{2026}", state: .off, command: .saveAsSmartGroup)
        save.isEnabled = options.filter.isActive
        menu.addItem(save)
        menu.addItem(pickItem("New Folder\u{2026}", state: .off, command: .newFolder(adding: nil)))
        menu.addItem(clearFiltersItem(options))
        return menu
    }

    /// The View menu's sidebar items for `options` over a library of
    /// `values`, built from the library section menu's own rows: Sort By,
    /// Group By, a Filter submenu of the filter rows, Clear Filters and Show
    /// Details; Expand All and Collapse All Sections, each enabled while a
    /// section it would change is listed; then a Smart Group and a Folder
    /// item, each opening `selectedGroup`'s menu while the selected row's
    /// section is of its kind and disabled otherwise.
    ///
    /// A Sort By item sets only the sort, whenever it was built, so its
    /// shortcut acts the same before the menu is next opened.
    func menuBarItems(
        options: SidebarViewOptions, values: [Value],
        hasCollapsedSection: Bool, hasExpandedSection: Bool,
        selectedGroup: (kind: VMGroupKind, menu: NSMenu)?
    ) -> [NSMenuItem] {
        let filter = NSMenuItem(title: "Filter", action: nil, keyEquivalent: "")
        let filterMenu = NSMenu(title: "Filter")
        filterMenu.autoenablesItems = false
        for row in filterRows(filter: options.filter, values: values, picking: { .editOptions(.filter($0)) }) {
            filterMenu.addItem(row)
        }
        filter.submenu = filterMenu

        let expand = pickItem("Expand All Sections", state: .off, command: .setSectionsExpanded(true))
        expand.isEnabled = hasCollapsedSection
        let collapse = pickItem("Collapse All Sections", state: .off, command: .setSectionsExpanded(false))
        collapse.isEnabled = hasExpandedSection

        let routes = VMGroupKind.allCases.map { kind in
            let item = NSMenuItem(title: Self.groupKindTitle(kind), action: nil, keyEquivalent: "")
            // An item with neither an action nor a submenu is disabled.
            if let selectedGroup, selectedGroup.kind == kind { item.submenu = selectedGroup.menu }
            return item
        }

        return [
            sortByItem(options), groupByItem(options), filter, clearFiltersItem(options), .separator(),
            showDetailsItem(options), .separator(), expand, collapse, .separator(),
        ] + routes
    }

    private func groupByItem(_ options: SidebarViewOptions) -> NSMenuItem {
        choiceMenu(
            "Group By", current: options.grouping,
            // Tag only while the library has tags, as the Tags filter row.
            cases: [.guestOS, .state, .network] + (tags().isEmpty ? [] : [.tag]), trailing: .none,
            title: \.title
        ) { .editOptions(.grouping($0)) }
    }

    private func sortByItem(_ options: SidebarViewOptions) -> NSMenuItem {
        choiceMenu(
            "Sort By", current: options.sort, cases: Self.sortChoices, trailing: .manual, title: \.title,
            keyEquivalent: { (Self.sortKeyEquivalent($0), Self.sortModifiers) }
        ) { .editOptions(.sort($0)) }
    }

    private func showDetailsItem(_ options: SidebarViewOptions) -> NSMenuItem {
        pickItem(
            "Show Details", state: options.showsDetails ? .on : .off,
            command: .editOptions(.showsDetails(!options.showsDetails)))
    }

    private func clearFiltersItem(_ options: SidebarViewOptions) -> NSMenuItem {
        let clear = pickItem("Clear Filters", state: .off, command: .editOptions(.filter(VMLibraryFilter())))
        clear.isEnabled = options.filter.isActive
        return clear
    }

    /// `group`'s menu over a library of `values`: its filter's rows, the
    /// group actions with `actionCounts` VMs each acts on, then Rename and
    /// Delete.
    func menu(smartGroup group: VMSmartGroup, values: [Value], actionCounts: [VMGroupAction: Int]?) -> NSMenu {
        let menu = NSMenu(title: Self.smartGroupAccessibilityLabel)
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Show VMs in \u{201C}\(group.name)\u{201D} where"))
        for row in filterRows(filter: group.filter, values: values, picking: { .setSmartGroupFilter(group.id, $0) }) {
            menu.addItem(row)
        }
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
    /// toggling that, then New Folder…; disabled, pointing to the config
    /// check, while the folders can't be read (`nil`).
    func addToFolderItem(entry: UUID, folders: [VMFolder]?) -> NSMenuItem {
        let item = NSMenuItem(title: "Add to Folder", action: nil, keyEquivalent: "")
        guard let folders else {
            item.isEnabled = false
            item.toolTip = VMOrganizationDirectory.unreadableMessage
            return item
        }
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

    /// A VM row's Tags item for the VM `entry`, which carries the tags
    /// `assigned` identifies: a submenu listing each of the library's tags
    /// with its color, checked where the VM carries it and each pick toggling
    /// that — offered only while `isEnabled` — then Edit Tags….
    func tagsItem(entry: UUID, assigned: Set<UUID>, isEnabled: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Tags")
        submenu.autoenablesItems = false
        let tags = tags()
        for tag in tags {
            let isAssigned = assigned.contains(tag.id)
            let tagItem = self.tagItem(
                tag, state: isAssigned ? .on : .off,
                command: .setTag(entry: entry, tag: tag.id, isAssigned: !isAssigned))
            tagItem.isEnabled = isEnabled
            submenu.addItem(tagItem)
        }
        if !tags.isEmpty { submenu.addItem(.separator()) }
        submenu.addItem(pickItem("Edit Tags\u{2026}", state: .off, command: .editTags))
        item.submenu = submenu
        return item
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
            return ["\(attribute.conditionTitle ?? attribute.title) is \(either)"]
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

    /// One row per filter attribute, each opening a submenu of its choices.
    private func filterRows(
        filter: VMLibraryFilter, values: [Value], picking: (VMLibraryFilter) -> Command
    ) -> [NSMenuItem] {
        attributes(of: filter, values: values).map { attribute in
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
                let state: NSControl.StateValue = choice.isOn ? .on : .off
                let command = picking(choice.picked)
                let choiceItem =
                    choice.tag.map { tagItem($0, state: state, command: command) }
                    ?? pickItem(choice.title, state: state, command: command)
                choiceItem.badge = NSMenuItemBadge(count: choice.count)
                submenu.addItem(choiceItem)
            }
            item.submenu = submenu
            return item
        }
    }

    /// An item naming `tag` after its color swatch — how every menu lists a
    /// tag, so the VM menu's Tags and the filter's Tags rows read alike.
    ///
    /// The swatch opts in to showing: from macOS 27 AppKit hides a menu item's
    /// image unless `preferredImageVisibility` is `.visible` (`NSMenuItem.h`),
    /// and the color is part of what names the tag.
    private func tagItem(_ tag: VMTag, state: NSControl.StateValue, command: Command) -> NSMenuItem {
        let item = pickItem(tag.name, state: state, command: command)
        item.image = tag.color.dotImage()
        if #available(macOS 27, *) {
            item.preferredImageVisibility = .visible
        }
        return item
    }

    private func pickItem(_ title: String, state: NSControl.StateValue, command: Command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
        item.target = self
        item.state = state
        item.representedObject = Pick(command)
        return item
    }

    /// A row whose submenu picks one of `cases`, then `trailing` below a
    /// separator, each with the shortcut `keyEquivalent` gives it.
    private func choiceMenu<Choice: Equatable>(
        _ title: String, current: Choice, cases: [Choice], trailing: Choice,
        title choiceTitle: (Choice) -> String,
        keyEquivalent: (Choice) -> (key: String, modifiers: NSEvent.ModifierFlags)? = { _ in nil },
        picking: (Choice) -> Command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.badge = NSMenuItemBadge(string: choiceTitle(current))
        let submenu = NSMenu(title: title)
        submenu.autoenablesItems = false
        func choiceItem(_ choice: Choice) -> NSMenuItem {
            let item = pickItem(choiceTitle(choice), state: choice == current ? .on : .off, command: picking(choice))
            if let shortcut = keyEquivalent(choice), !shortcut.key.isEmpty {
                item.keyEquivalent = shortcut.key
                item.keyEquivalentModifierMask = shortcut.modifiers
            }
            return item
        }
        for choice in cases { submenu.addItem(choiceItem(choice)) }
        submenu.addItem(.separator())
        submenu.addItem(choiceItem(trailing))
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
            /// The tag the choice is, which lists it by ``tagItem(_:state:command:)``.
            var tag: VMTag? = nil
        }

        let title: String
        let allTitle: String
        let isActive: Bool
        /// Whether its choices are values the attribute takes ("Guest OS is
        /// macOS") rather than flags of their own (Other).
        var isPredicate = true
        /// What a condition calls the attribute, when not its ``title``.
        var conditionTitle: String? = nil
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
        // Any picked tag admits a VM, so picks widen the set.
        let defined = tags()
        // A tag the filter names but the library no longer defines stays
        // listed, checked, so its condition — which no VM passes — shows and
        // can be turned off.
        let deleted = filter.tags.subtracting(defined.map(\.id)).sorted { $0.uuidString < $1.uuidString }
        let tagged = Attribute(
            title: "Tags", allTitle: "All Tags", isActive: !filter.tags.isEmpty, conditionTitle: "Tag",
            cleared: with { $0.tags = [] },
            choices: defined.map { tag in
                Attribute.Choice(
                    title: tag.name, count: values.count { $0.subject.tags.contains(tag.id) },
                    isOn: filter.tags.contains(tag.id),
                    picked: with { $0.tags = toggled($0.tags, tag.id) },
                    tag: tag)
            }
                + deleted.map { id in
                    Attribute.Choice(
                        title: Self.heldUndefinedTagTitle, count: 0, isOn: true,
                        picked: with { $0.tags.remove(id) })
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
        // A library with no tags lists no Tags row, unless the filter still
        // names one to clear.
        let offersTags = !tagged.choices.isEmpty || tagged.isActive
        return [guestOS, state, network] + (offersTags ? [tagged] : []) + [guestAgent, other]
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
