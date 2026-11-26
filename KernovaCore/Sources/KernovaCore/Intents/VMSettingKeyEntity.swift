import AppIntents
import Foundation
import KernovaCommandModel

/// One configuration key, as Shortcuts names it: the keyspace `kernova get`
/// and `kernova set` address, built from its ``ConfigurationKeyDescriptor``.
struct VMSettingKeyEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Virtual Machine Setting")

    static let defaultQuery = VMSettingKeyEntityQuery()

    /// The dotted key name, which a read or a write addresses the value by.
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

/// How Shortcuts finds the setting an intent reads or writes.
///
/// Every method forwards to ``VMIntentGateway``: `allEntities()` lists the
/// whole keyspace for a picker, and a typed name matches as the sidebar's
/// search does (``SidebarNameSearch``).
///
/// Unlike the ``FindQuery`` conformers, it is an `EnumerableEntityQuery`,
/// whose entities Shortcuts filters itself: the entity has no properties, so
/// Shortcuts' Find has nothing to filter it by.
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
