import AppIntents
import Foundation
import KernovaKit

/// One of the library's smart groups or folders, as Shortcuts names it.
///
/// One entity for both kinds, as ``GroupSummary`` is one type for both: a
/// group action's one parameter then takes either.
struct VMGroupEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "VM Group")

    static let defaultQuery = VMGroupEntityQuery()

    /// The group's stable identifier, which every verb this surface runs
    /// addresses it by.
    let id: UUID

    @Property(title: "Name")
    var name: String

    @Property(title: "Kind")
    var kind: VMGroupKindChoice

    @Property(title: "Virtual Machines")
    var members: [VMEntity]

    init(_ group: GroupSummary, members: [VMEntity]) {
        self.id = group.id
        self.name = group.name
        self.kind = VMGroupKindChoice(group.kind)
        self.members = members
    }

    /// The group as a command names it.
    var reference: VMGroupReference {
        VMGroupReference(kind.kind, named: id.uuidString)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)", subtitle: VMGroupKindChoice.caseDisplayRepresentations[kind]?.title)
    }
}

/// How Shortcuts finds the group an intent acts on.
///
/// Forwards to ``VMIntentGateway`` as ``NetworkEntityQuery`` does: the groups
/// are few and fully enumerable, so `allEntities()` gives Shortcuts a picker
/// and a Find VM Groups action, and a typed name resolves as a typed VM name
/// does (``VMIntentGateway/groups(matching:)``).
struct VMGroupEntityQuery: EntityStringQuery, EnumerableEntityQuery {
    static let findIntentDescription: IntentDescription? = IntentDescription(
        "Finds the library's smart groups and folders, each with the virtual machines in it.",
        categoryName: "Groups",
        resultValueName: "VM Groups")

    @Dependency private var gateway: VMIntentGateway

    func entities(for identifiers: [UUID]) async throws -> [VMGroupEntity] {
        let wanted = Set(identifiers)
        return try await gateway.groups().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [VMGroupEntity] {
        try await gateway.groups(matching: string)
    }

    func allEntities() async throws -> [VMGroupEntity] {
        try await gateway.groups()
    }
}

/// What kind of group a ``VMGroupEntity`` is, in Shortcuts' words.
///
/// Mirrors ``VMGroupKind`` rather than conforming it, for the reason
/// ``VMStopMethod`` gives. ``init(_:)`` is exhaustive over the kinds, so a new
/// one fails to build here rather than reaching Shortcuts unnamed.
enum VMGroupKindChoice: String, AppEnum {
    case smartGroup
    case folder

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Group Kind")

    static let caseDisplayRepresentations: [VMGroupKindChoice: DisplayRepresentation] = [
        .smartGroup: "Smart Group",
        .folder: "Folder",
    ]

    /// The kind this case names.
    var kind: VMGroupKind {
        switch self {
        case .smartGroup: .smartGroup
        case .folder: .folder
        }
    }

    /// The case naming `kind`.
    init(_ kind: VMGroupKind) {
        self =
            switch kind {
            case .smartGroup: .smartGroup
            case .folder: .folder
            }
    }
}

/// Which lifecycle action a group intent takes, offered as a Shortcuts picker.
///
/// Mirrors ``VMGroupAction`` rather than conforming it, for the reason
/// ``VMStopMethod`` gives.
enum VMGroupActionChoice: String, AppEnum {
    case start
    case suspend
    case stop

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Group Action")

    static let caseDisplayRepresentations: [VMGroupActionChoice: DisplayRepresentation] = [
        .start: "Start",
        .suspend: "Suspend",
        .stop: "Stop",
    ]

    /// The action this case names.
    var action: VMGroupAction {
        switch self {
        case .start: .start
        case .suspend: .suspend
        case .stop: .stop
        }
    }

    /// The case naming `action`.
    init(_ action: VMGroupAction) {
        self =
            switch action {
            case .start: .start
            case .suspend: .suspend
            case .stop: .stop
            }
    }
}

/// Starts, suspends or stops every virtual machine in a smart group or folder.
struct RunVMGroupActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start, Suspend, or Stop a VM Group"
    static let description: IntentDescription? = IntentDescription(
        "Starts, suspends, or stops each virtual machine in a smart group or folder, one after another, asking nothing. One whose own action would ask something first is skipped, and the action fails naming each virtual machine it left undone.",
        categoryName: "Groups",
        resultValueName: "Virtual Machines")

    @Parameter(title: "Action", default: .start)
    var action: VMGroupActionChoice

    @Parameter(title: "Group")
    var group: VMGroupEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) every VM in \(\.$group)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[VMEntity]> {
        .result(value: try await gateway.groupAction(action.action, on: group.reference))
    }
}
