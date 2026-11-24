import AppIntents
import CoreSpotlight
import Foundation
import KernovaCommandModel

/// One virtual machine, as Shortcuts and Spotlight name it.
///
/// Built from a ``VMInfo`` alone, each field but the identifier in an entity
/// property, which is what lets a Shortcut read a VM's configuration as
/// variables and filter the library on it.
package struct VMEntity: IndexedEntity {
    package static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Virtual Machine")

    package static let defaultQuery = VMEntityQuery()

    /// The VM's stable identifier — what every verb this surface runs addresses
    /// it by, so a name shared by two VMs can never resolve ambiguously here.
    package let id: UUID

    /// The VM's display name, which is not unique, and what the Spotlight
    /// record is matched on.
    @Property(title: "Name", indexingKey: \.displayName)
    var name: String

    /// The VM's runtime status, as its stable wire name — the same string every
    /// other front door reports.
    @Property(title: "State")
    var status: String

    /// The VM's coarse state, the buckets the sidebar filters and groups by.
    @Property(title: "State Group")
    var stateGroup: VMStateGroup

    @Property(title: "Guest Operating System")
    var guestOS: VMGuestOperatingSystem

    @Property(title: "CPU Count")
    var cpuCount: Int

    /// Guest memory in bytes. Narrowed from the core's `UInt64` because that is
    /// not a value Shortcuts carries; every configurable memory size is orders
    /// of magnitude below `Int.max`.
    @Property(title: "Memory in Bytes")
    var memoryBytes: Int

    @Property(title: "Network Mode")
    var networkMode: VMNetworkModeOption?

    @Property(title: "Network Membership")
    var networkMembership: String?

    /// The name of the named network the VM joins — "Network List Can’t Be
    /// Read" while the library's list can't be read — `nil` where it joins
    /// none or one the library does not list.
    @Property(title: "Network")
    var networkName: String?

    @Property(title: "MAC Address")
    var macAddress: String?

    @Property(title: "IP Address")
    var ipAddress: String?

    /// The guest-agent status as its wire name, `nil` when the VM has no agent
    /// channel.
    @Property(title: "Guest Agent Status")
    var agentStatus: String?

    /// How the guest agents stand against the bundled ones, `nil` when an
    /// agent has connected and this build bundles none for the guest's OS.
    @Property(title: "Guest Agent Version")
    var guestAgentVersion: VMGuestAgentVersion?

    @Property(title: "Has Saved State")
    var hasSavedState: Bool

    /// ``VMInfo/savedStateKernovaVersion``.
    @Property(title: "Saved by Kernova Version")
    var savedStateKernovaVersion: String?

    @Property(title: "Ephemeral Mode")
    var isEphemeral: Bool

    @Property(title: "Snapshot Count")
    var snapshotCount: Int

    /// ``VMInfo/hasSnapshots``.
    @Property(title: "Has Snapshots")
    var hasSnapshots: Bool

    @Property(title: "Bundle Path")
    var bundlePath: String

    /// ``VMInfo/heldByAnotherCopy``, which the subtitle reads in place of
    /// ``status``.
    @Property(title: "In Use by Another Copy of Kernova")
    var heldByAnotherCopy: Bool

    @Property(title: "Guest Agents")
    var agents: [GuestAgentEntity]

    /// ``VMInfo/tags``.
    @Property(title: "Tags")
    var tags: [String]?

    /// ``VMInfo/createdAt``.
    @Property(title: "Date Created")
    var createdAt: Date

    /// ``VMInfo/lastRunAt``.
    @Property(title: "Last Run")
    var lastRunAt: Date?

    /// When the VM last ran, as ``VMLibrarySort/lastRun`` orders it.
    let lastRun: VMLibrarySort.LastRun

    /// The entity `info` describes, accounting for each ``VMInfo/Field``.
    init(_ info: VMInfo) {
        self.id = info.id
        self.lastRun = VMLibrarySort.LastRun(state: info.stateBucket, lastRunAt: info.lastRunAt)
        for field in VMInfo.Field.allCases {
            switch field {
            case .id: break  // The entity's identifier, set above.
            case .name: name = info.name
            case .status: status = info.status
            case .stateBucket: stateGroup = VMStateGroup(info.stateBucket)
            case .guestOS: guestOS = VMGuestOperatingSystem(info.guestOS)
            case .cpuCount: cpuCount = info.cpuCount
            case .memoryBytes: memoryBytes = Int(clamping: info.memoryBytes)
            case .networkMode: networkMode = info.networkMode.map(VMNetworkModeOption.init)
            case .networkMembership: networkMembership = info.networkMembership
            case .networkName: networkName = info.networkName?.title
            case .macAddress: macAddress = info.macAddress
            case .ipAddress: ipAddress = info.ipAddress.address
            case .agentStatus: agentStatus = info.agentStatus
            case .guestAgent: guestAgentVersion = info.guestAgent.map(VMGuestAgentVersion.init)
            case .hasSavedState: hasSavedState = info.hasSavedState
            case .savedStateKernovaVersion: savedStateKernovaVersion = info.savedStateKernovaVersion
            case .isEphemeral: isEphemeral = info.isEphemeral
            case .snapshotCount: snapshotCount = info.snapshotCount
            case .hasSnapshots: hasSnapshots = info.hasSnapshots
            case .bundlePath: bundlePath = info.bundlePath
            case .heldByAnotherCopy: heldByAnotherCopy = info.heldByAnotherCopy
            case .agents: agents = info.agents.map(GuestAgentEntity.init)
            case .tags: tags = info.tags
            case .createdAt: createdAt = info.createdAt
            case .lastRunAt: lastRunAt = info.lastRunAt
            }
        }
    }

    /// What a ``VMLibrarySort`` reads of this VM.
    var sortKeys: VMLibrarySort.Keys {
        VMLibrarySort.Keys(name: name, createdAt: createdAt, lastRun: lastRun)
    }

    package var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(VMStatus.displayName(forWireName: status, heldByAnotherCopy: heldByAnotherCopy))")
    }

    /// What Spotlight holds for this VM: the name it is found by, and the
    /// guest it runs.
    ///
    /// Carries nothing that moves while the VM is in the library — a status
    /// that changed would otherwise cost a re-index on every transition.
    package var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.displayName = name
        attributes.contentDescription = "\(guestOS.os.displayName) virtual machine"
        return attributes
    }
}

/// How Shortcuts and Spotlight find the VM an intent acts on.
///
/// Every method forwards to ``VMIntentGateway``, which owns the matching as
/// well as the readiness await: `suggestedEntities()` lists the whole library
/// for a picker, and a typed name matches as the sidebar's search does
/// (``SidebarNameSearch``).
///
/// Find Virtual Machines runs as this property query, which filters and sorts
/// the library in memory, in library order until a sort is chosen; a
/// condition `kernova list` also takes is its listing
/// (``Condition/listed(_:negated:)``). It is no `EnumerableEntityQuery`, whose
/// entities Shortcuts filters itself, as that protocol's documentation says.
/// On macOS 27.2, Shortcuts filtered a query adopting both protocols itself
/// too, and never called ``entities(matching:mode:sortedBy:limit:)``.
package struct VMEntityQuery: EntityStringQuery, EntityPropertyQuery {
    /// One condition a Find puts on the VMs it answers, as the comparator a
    /// Shortcut chose makes it.
    package enum Condition: Sendable {
        /// Holds for each VM the predicate admits.
        case admits(@Sendable (VMEntity) -> Bool)
        /// Holds for each VM `kernova list` lists for the query, refusing
        /// what it refuses — or, `negated`, for every other VM.
        case listed(VMListQuery, negated: Bool)
        /// Holds where `holds` does of the named network `text` names, by
        /// name, ignoring case, or by identifier — which the gateway resolves,
        /// refusing one the library does not list.
        case naming(network: String, holds: @Sendable (UUID) -> Condition)
        /// Holds where `holds` does of the membership `text` spells, as
        /// `network.membership` takes one — which the gateway resolves,
        /// refusing what that key refuses.
        case spelling(membership: String, holds: @Sendable (VMNetworkMembership) -> Condition)

        /// Holds for each VM `kernova list` lists under `filter`, or with
        /// `holding` false, for every other VM.
        static func admitted(by filter: VMLibraryFilter, holding: Bool = true) -> Self {
            .listed(
                VMListQuery(filter: filter, networks: [], tags: [], groups: [], sort: .manual), negated: !holding)
        }

        /// Holds for each VM listed on the named network `text` names; a `nil`
        /// text names none, and holds for each VM whose
        /// ``VMEntity/networkName`` reads `nil`.
        static func onNetwork(_ text: String?) -> Self {
            guard let text else { return .admits { $0.networkName == nil } }
            return .naming(network: text) { id in
                .listed(
                    VMListQuery(
                        filter: VMLibraryFilter(), networks: [id.uuidString], tags: [], groups: [], sort: .manual),
                    negated: false)
            }
        }

        /// Holds for each VM whose ``VMEntity/networkMembership`` is the one
        /// `text` spells; a `nil` text spells none, and holds for each VM
        /// whose membership reads `nil`.
        static func inMembership(_ text: String?) -> Self {
            guard let text else { return .admits { $0.networkMembership == nil } }
            return .spelling(membership: text) { membership in
                .admits { $0.networkMembership == membership.rawValue }
            }
        }

        /// Holds for each VM listed as carrying the tag `text` names
        /// (``VMListQuery/tags``).
        static func carrying(tag text: String) -> Self {
            .listed(
                VMListQuery(filter: VMLibraryFilter(), networks: [], tags: [text], groups: [], sort: .manual),
                negated: false)
        }

        /// Holds for each VM listed with its guest agents standing as
        /// `version` names; a `nil` version holds for each VM whose
        /// ``VMEntity/guestAgentVersion`` reads `nil`.
        static func agents(_ version: VMGuestAgentVersion?) -> Self {
            guard let version else { return .admits { $0.guestAgentVersion == nil } }
            return admitted(by: VMLibraryFilter(guestAgents: [version.bucket]))
        }

        /// Holds for each VM this does not.
        var negated: Self {
            switch self {
            case .admits(let admits): .admits { !admits($0) }
            case .listed(let query, let negated): .listed(query, negated: !negated)
            case .naming(let network, let holds): .naming(network: network) { holds($0).negated }
            case .spelling(let membership, let holds): .spelling(membership: membership) { holds($0).negated }
            }
        }
    }

    package typealias ComparatorMappingType = Condition

    /// Describes the Find action Shortcuts generates from this query.
    package static let findIntentDescription: IntentDescription? = IntentDescription(
        "Finds virtual machines in the library, filtered and sorted by their properties. With no sort, they come in the order the sidebar lists them under Sort By ▸ Manual.",
        categoryName: "Virtual Machines",
        resultValueName: "Virtual Machines")

    @Dependency private var gateway: VMIntentGateway

    package init() {}

    package func entities(for identifiers: [UUID]) async throws -> [VMEntity] {
        await gateway.vms(withIDs: identifiers)
    }

    package func entities(matching string: String) async throws -> [VMEntity] {
        await gateway.vms(matching: string)
    }

    package func suggestedEntities() async throws -> [VMEntity] {
        await gateway.vms()
    }

    package func entities(
        matching comparators: [Condition],
        mode: ComparatorMode,
        sortedBy: [EntityQuerySort<VMEntity>],
        limit: Int?
    ) async throws -> [VMEntity] {
        try Self.ordered(try await gateway.vms(meeting: comparators, mode: mode), by: sortedBy, limit: limit)
    }

    /// The sort and truncation a property query asks of `entities`, given in
    /// library order.
    ///
    /// - Throws: ``CommandError/invalidArgument(_:)`` for a negative `limit`,
    ///   which the framework types as any `Int` and `prefix` traps on.
    static func ordered(
        _ entities: [VMEntity], by sortedBy: [EntityQuerySort<VMEntity>], limit: Int?
    ) throws -> [VMEntity] {
        let ordered = sortedBy.first.map { sorted(entities, by: $0.by, ascending: $0.order == .ascending) } ?? entities
        guard let limit else { return ordered }
        guard limit >= 0 else {
            throw CommandError.invalidArgument("A Find\u{2019}s limit is a number of virtual machines, not \(limit).")
        }
        return Array(ordered.prefix(limit))
    }

    // Both tables are spelled as stored properties with an inline builder,
    // which is the only shape the App Intents metadata processor parses — a
    // computed property returning the same value exports no metadata at all,
    // and that leaves the filters and sorts silently absent from Shortcuts.
    // `nonisolated(unsafe)` because AppIntents' builder results are not marked
    // `Sendable`: each is built once from constant closures and never mutated.
    package nonisolated(unsafe) static let properties = QueryProperties {
        Property(\VMEntity.$name) {
            EqualToComparator { value in .admits { VMCommandCore.name($0.name, isNamedBy: value) } }
            NotEqualToComparator { value in .admits { !VMCommandCore.name($0.name, isNamedBy: value) } }
            ContainsComparator { value in .admits { SidebarNameSearch(text: value).admits($0.name) } }
        }
        Property(\VMEntity.$status) {
            EqualToComparator { value in .admits { $0.status == value } }
            NotEqualToComparator { value in .admits { $0.status != value } }
        }
        Property(\VMEntity.$stateGroup) {
            EqualToComparator { value in .admitted(by: VMLibraryFilter(states: [value.bucket])) }
            NotEqualToComparator { value in .admitted(by: VMLibraryFilter(states: [value.bucket]), holding: false) }
        }
        Property(\VMEntity.$guestOS) {
            EqualToComparator { value in .admitted(by: VMLibraryFilter(guestOSes: [value.os])) }
            NotEqualToComparator { value in .admitted(by: VMLibraryFilter(guestOSes: [value.os]), holding: false) }
        }
        Property(\VMEntity.$networkMode) {
            EqualToComparator { value in .admits { $0.networkMode == value } }
            NotEqualToComparator { value in .admits { $0.networkMode != value } }
        }
        Property(\VMEntity.$networkMembership) {
            EqualToComparator { value in .inMembership(value) }
            NotEqualToComparator { value in .inMembership(value).negated }
        }
        Property(\VMEntity.$networkName) {
            EqualToComparator { value in .onNetwork(value) }
            NotEqualToComparator { value in .onNetwork(value).negated }
        }
        Property(\VMEntity.$tags) {
            ContainsComparator { tag in .carrying(tag: tag) }
        }
        Property(\VMEntity.$agentStatus) {
            EqualToComparator { value in .admits { $0.agentStatus == value } }
            NotEqualToComparator { value in .admits { $0.agentStatus != value } }
        }
        Property(\VMEntity.$guestAgentVersion) {
            EqualToComparator { value in .agents(value) }
            NotEqualToComparator { value in .agents(value).negated }
        }
        Property(\VMEntity.$hasSnapshots) {
            EqualToComparator { value in .admitted(by: VMLibraryFilter(withSnapshotsOnly: true), holding: value) }
        }
        Property(\VMEntity.$snapshotCount) {
            EqualToComparator { value in .admits { $0.snapshotCount == value } }
            GreaterThanOrEqualToComparator { value in .admits { $0.snapshotCount >= value } }
            LessThanOrEqualToComparator { value in .admits { $0.snapshotCount <= value } }
        }
        Property(\VMEntity.$hasSavedState) {
            EqualToComparator { value in .admits { $0.hasSavedState == value } }
        }
        Property(\VMEntity.$isEphemeral) {
            EqualToComparator { value in .admitted(by: VMLibraryFilter(ephemeralOnly: true), holding: value) }
        }
    }

    package nonisolated(unsafe) static let sortingOptions = SortingOptions {
        SortableBy(\VMEntity.$name)
        SortableBy(\VMEntity.$createdAt)
        SortableBy(\VMEntity.$lastRunAt)
        SortableBy(\VMEntity.$status)
        SortableBy(\VMEntity.$snapshotCount)
    }

    // MARK: - Sorting

    /// `entities`, given in library order, ordered by the property `key`
    /// names; one naming a property this query does not offer to sort on
    /// leaves them as given.
    ///
    /// Name, Date Created and Last Run take ``VMLibrarySort``'s order — its
    /// one direction ascending by name and descending by either date — and
    /// that order reversed the other way.
    static func sorted(
        _ entities: [VMEntity], by key: PartialKeyPath<VMEntity>, ascending: Bool
    ) -> [VMEntity] {
        let name: PartialKeyPath<VMEntity> = \VMEntity.$name
        let createdAt: PartialKeyPath<VMEntity> = \VMEntity.$createdAt
        let lastRunAt: PartialKeyPath<VMEntity> = \VMEntity.$lastRunAt
        let status: PartialKeyPath<VMEntity> = \VMEntity.$status
        let snapshotCount: PartialKeyPath<VMEntity> = \VMEntity.$snapshotCount
        let (ordered, isAscending): ([VMEntity], Bool) =
            switch key {
            case name: (VMLibrarySort.name.ordered(entities, by: \.sortKeys), true)
            case createdAt: (VMLibrarySort.dateCreated.ordered(entities, by: \.sortKeys), false)
            case lastRunAt: (VMLibrarySort.lastRun.ordered(entities, by: \.sortKeys), false)
            case status: (entities.sorted { $0.status < $1.status }, true)
            case snapshotCount: (entities.sorted { $0.snapshotCount < $1.snapshotCount }, true)
            default: (entities, ascending)
            }
        return ascending == isAscending ? ordered : ordered.reversed()
    }
}
