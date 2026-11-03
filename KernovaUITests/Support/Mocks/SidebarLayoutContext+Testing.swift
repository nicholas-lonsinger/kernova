import Foundation
import KernovaCommandModel

@testable import KernovaCore
@testable import KernovaCoreTestSupport

extension SidebarLayout.Context {
    /// A context naming networks by the app's own titling, over `networks`
    /// and no host interfaces.
    static func testing(
        bundledAgents: BundledGuestAgents = .testing, networks: [VMNamedNetwork] = [], tags: [VMTag] = []
    ) -> SidebarLayout.Context {
        SidebarLayout.Context(
            bundledAgents: bundledAgents, networks: .listed(networks), tags: tags,
            networkTitle: {
                NetworkModeChoice.label(
                    of: $0, entitlements: .entitled, interfaces: { [] }, networks: .listed(networks)
                ).text
            })
    }
}
