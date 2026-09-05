import AppIntents
import CoreSpotlight
import Foundation
import KernovaKit

/// One virtual machine, as Shortcuts and Spotlight name it.
///
/// Built from a ``VMInfo`` and nothing else, so what this surface shows can
/// never drift from what the command core reads. Every field but the
/// identifier is an entity property, which is what lets a Shortcut read a VM's
/// configuration as variables and filter the library on it.
struct VMEntity: IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Virtual Machine")

    static let defaultQuery = VMEntityQuery()

    /// The VM's stable identifier — what every verb this surface runs addresses
    /// it by, so a name shared by two VMs can never resolve ambiguously here.
    let id: UUID

    /// The VM's display name, which is not unique, and what the Spotlight
    /// record is matched on.
    @Property(title: "Name", indexingKey: \.displayName)
    var name: String

    /// The VM's runtime status, as its stable wire name — the same string every
    /// other front door reports.
    @Property(title: "State")
    var status: String

    @Property(title: "Guest Operating System")
    var guestOS: String

    @Property(title: "CPU Count")
    var cpuCount: Int

    /// Guest memory in bytes. Narrowed from the core's `UInt64` because that is
    /// not a value Shortcuts carries; every configurable memory size is orders
    /// of magnitude below `Int.max`.
    @Property(title: "Memory in Bytes")
    var memoryBytes: Int

    @Property(title: "Disk Size in Gigabytes")
    var diskSizeInGB: Int

    @Property(title: "Network Mode")
    var networkMode: String?

    @Property(title: "MAC Address")
    var macAddress: String?

    @Property(title: "IP Address")
    var ipAddress: String?

    @Property(title: "Guest Agent Status")
    var agentStatus: String

    @Property(title: "Has Saved State")
    var hasSavedState: Bool

    @Property(title: "Ephemeral Mode")
    var isEphemeral: Bool

    @Property(title: "Snapshot Count")
    var snapshotCount: Int

    @Property(title: "Bundle Path")
    var bundlePath: String

    init(_ info: VMInfo) {
        self.id = info.id
        self.name = info.name
        self.status = info.status
        self.guestOS = info.guestOS
        self.cpuCount = info.cpuCount
        self.memoryBytes = Int(clamping: info.memoryBytes)
        self.diskSizeInGB = info.diskSizeInGB
        self.networkMode = info.networkMode
        self.macAddress = info.macAddress
        self.ipAddress = info.ipAddress
        self.agentStatus = info.agentStatus
        self.hasSavedState = info.hasSavedState
        self.isEphemeral = info.isEphemeral
        self.snapshotCount = info.snapshotCount
        self.bundlePath = info.bundlePath
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(Self.statusDisplayName(status))")
    }

    /// What Spotlight holds for this VM: the name it is found by, and the
    /// guest it runs.
    ///
    /// Carries nothing that moves while the VM is in the library — a status
    /// that changed would otherwise cost a re-index on every transition.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.displayName = name
        attributes.contentDescription = "\(Self.guestOSDisplayName(guestOS)) virtual machine"
        return attributes
    }

    /// A wire guest OS in the words a person reads.
    static func guestOSDisplayName(_ guestOS: String) -> String {
        VMGuestOS(rawValue: guestOS)?.displayName ?? guestOS
    }

    /// A wire status in the words a person reads.
    ///
    /// A VM still copying into place reports ``VMCommandCore/preparingWireStatus``,
    /// which is not a ``VMStatus`` value and so has no `displayName` of its own.
    static func statusDisplayName(_ status: String) -> String {
        if let known = VMStatus(rawValue: status) { return known.displayName }
        return status == VMCommandCore.preparingWireStatus ? "Preparing" : status
    }
}

/// How Shortcuts and Spotlight find the VM an intent acts on.
///
/// Every method forwards to ``VMIntentGateway``, which owns the matching as
/// well as the readiness await: the library is small and fully enumerable, so
/// `allEntities()` gives Shortcuts a picker rather than a search field, and a
/// typed name resolves through a case-insensitive contains match.
///
/// The property query filters and sorts in memory over that same enumeration,
/// because the core answers the whole library in one main-actor read — there is
/// no narrower query to push a predicate down into.
struct VMEntityQuery: EntityQuery, EntityStringQuery, EnumerableEntityQuery, EntityPropertyQuery {
    /// A comparator becomes the predicate that answers it, so `entities(matching:)`
    /// is the same filtering the enumeration already supports.
    typealias ComparatorMappingType = @Sendable (VMEntity) -> Bool

    /// Both query protocols this conforms to carry a default, which is
    /// ambiguous where a type takes them both. The Find action this surface
    /// offers is ``ListVMsIntent``, so there is none of its own to describe.
    static let findIntentDescription: IntentDescription? = nil

    @Dependency private var gateway: VMIntentGateway

    func entities(for identifiers: [UUID]) async throws -> [VMEntity] {
        await gateway.vms(withIDs: identifiers)
    }

    func entities(matching string: String) async throws -> [VMEntity] {
        await gateway.vms(matching: string)
    }

    func allEntities() async throws -> [VMEntity] {
        await gateway.vms()
    }

    func entities(
        matching comparators: [ComparatorMappingType],
        mode: ComparatorMode,
        sortedBy: [EntityQuerySort<VMEntity>],
        limit: Int?
    ) async throws -> [VMEntity] {
        Self.narrowed(
            await gateway.vms(), matching: comparators, mode: mode, sortedBy: sortedBy,
            limit: limit)
    }

    /// The filter, sort, and truncation a property query asks of an
    /// enumeration — the whole of what `entities(matching:mode:sortedBy:limit:)`
    /// does once the library has been read.
    ///
    /// An `or` over no comparators keeps everything: a Shortcut that names no
    /// filter is asking for the library, not for nothing.
    static func narrowed(
        _ entities: [VMEntity],
        matching comparators: [ComparatorMappingType],
        mode: ComparatorMode,
        sortedBy: [EntityQuerySort<VMEntity>],
        limit: Int?
    ) -> [VMEntity] {
        let matched = entities.filter { entity in
            switch mode {
            case .and: comparators.allSatisfy { $0(entity) }
            case .or: comparators.isEmpty || comparators.contains { $0(entity) }
            @unknown default: true
            }
        }
        let ordered =
            sortedBy.first.map {
                sorted(matched, by: $0.by, ascending: $0.order == .ascending)
            } ?? matched
        guard let limit else { return ordered }
        return Array(ordered.prefix(limit))
    }

    // Both tables are spelled as stored properties with an inline builder,
    // which is the only shape the App Intents metadata processor parses — a
    // computed property returning the same value exports no metadata at all,
    // and that leaves the filters and sorts silently absent from Shortcuts.
    // `nonisolated(unsafe)` because AppIntents' builder results are not marked
    // `Sendable`: each is built once from constant closures and never mutated.
    nonisolated(unsafe) static let properties = QueryProperties {
        Property(\VMEntity.$name) {
            EqualToComparator { value in { @Sendable in $0.name == value } }
            NotEqualToComparator { value in { @Sendable in $0.name != value } }
            ContainsComparator { value in
                { @Sendable in $0.name.localizedCaseInsensitiveContains(value) }
            }
        }
        Property(\VMEntity.$status) {
            EqualToComparator { value in { @Sendable in $0.status == value } }
            NotEqualToComparator { value in { @Sendable in $0.status != value } }
        }
        Property(\VMEntity.$guestOS) {
            EqualToComparator { value in { @Sendable in $0.guestOS == value } }
            NotEqualToComparator { value in { @Sendable in $0.guestOS != value } }
        }
        Property(\VMEntity.$agentStatus) {
            EqualToComparator { value in { @Sendable in $0.agentStatus == value } }
            NotEqualToComparator { value in { @Sendable in $0.agentStatus != value } }
        }
        Property(\VMEntity.$snapshotCount) {
            EqualToComparator { value in { @Sendable in $0.snapshotCount == value } }
            GreaterThanOrEqualToComparator { value in
                { @Sendable in $0.snapshotCount >= value }
            }
            LessThanOrEqualToComparator { value in
                { @Sendable in $0.snapshotCount <= value }
            }
        }
        Property(\VMEntity.$hasSavedState) {
            EqualToComparator { value in { @Sendable in $0.hasSavedState == value } }
        }
        Property(\VMEntity.$isEphemeral) {
            EqualToComparator { value in { @Sendable in $0.isEphemeral == value } }
        }
    }

    nonisolated(unsafe) static let sortingOptions = SortingOptions {
        SortableBy(\VMEntity.$name)
        SortableBy(\VMEntity.$status)
        SortableBy(\VMEntity.$snapshotCount)
    }

    // MARK: - Sorting

    /// `entities` ordered by the property `key` names; one naming a property
    /// this query does not offer to sort on leaves library order alone.
    static func sorted(
        _ entities: [VMEntity], by key: PartialKeyPath<VMEntity>, ascending: Bool
    ) -> [VMEntity] {
        let name: PartialKeyPath<VMEntity> = \VMEntity.$name
        let status: PartialKeyPath<VMEntity> = \VMEntity.$status
        let snapshotCount: PartialKeyPath<VMEntity> = \VMEntity.$snapshotCount
        let rising: [VMEntity]
        switch key {
        case name:
            rising = entities.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case status:
            rising = entities.sorted { $0.status < $1.status }
        case snapshotCount:
            rising = entities.sorted { $0.snapshotCount < $1.snapshotCount }
        default:
            return entities
        }
        return ascending ? rising : rising.reversed()
    }
}
