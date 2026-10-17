import AppIntents
import Foundation
import KernovaKit

/// One configuration key, as Shortcuts names it: the keyspace `kernova get`
/// and `kernova set` address, built from its ``ConfigurationKeyDescriptor``.
struct VMSettingKeyEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Virtual Machine Setting")

    static let defaultQuery = VMSettingKeyEntityQuery()

    /// The dotted key name, which a write addresses the value by.
    let id: String

    /// One line naming the unit or the accepted values.
    let summary: String

    init(_ descriptor: ConfigurationKeyDescriptor) {
        self.id = descriptor.name
        self.summary = descriptor.summary
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)", subtitle: "\(summary)")
    }
}

/// How Shortcuts finds the setting an intent writes.
///
/// Every method forwards to ``VMIntentGateway``, as ``NetworkEntityQuery``'s
/// do: the keyspace is fully enumerable, so `allEntities()` gives Shortcuts a
/// picker, and a typed name resolves through a case-insensitive contains match.
struct VMSettingKeyEntityQuery: EntityStringQuery, EnumerableEntityQuery {
    @Dependency private var gateway: VMIntentGateway

    func entities(for identifiers: [String]) async throws -> [VMSettingKeyEntity] {
        await gateway.configurationKeys(named: identifiers)
    }

    func entities(matching string: String) async throws -> [VMSettingKeyEntity] {
        await gateway.configurationKeys(matching: string)
    }

    func allEntities() async throws -> [VMSettingKeyEntity] {
        await gateway.configurationKeys()
    }
}
