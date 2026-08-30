import AppIntents
import Foundation
import KernovaKit

/// One virtual machine, as Siri, Shortcuts, and Spotlight name it.
///
/// Built from a ``VMSummary`` and nothing else, so what this surface shows can
/// never drift from what the command core reads.
struct VMEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Virtual Machine")

    static let defaultQuery = VMEntityQuery()

    /// The VM's stable identifier — what every verb this surface runs addresses
    /// it by, so a name shared by two VMs can never resolve ambiguously here.
    let id: UUID
    /// The VM's display name, which is not unique.
    let name: String
    /// The VM's runtime status, as its stable wire name — the same string every
    /// other front door reports.
    let status: String

    init(_ summary: VMSummary) {
        self.id = summary.id
        self.name = summary.name
        self.status = summary.status
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(Self.statusDisplayName(status))")
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

/// How Shortcuts and Siri find the VM an intent acts on.
///
/// Every method forwards to ``VMIntentGateway``, which owns the matching as
/// well as the readiness await: the library is small and fully enumerable, so
/// `allEntities()` gives Shortcuts a picker rather than a search field, and a
/// spoken name resolves through a case-insensitive contains match.
struct VMEntityQuery: EntityQuery, EntityStringQuery, EnumerableEntityQuery {
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
}
