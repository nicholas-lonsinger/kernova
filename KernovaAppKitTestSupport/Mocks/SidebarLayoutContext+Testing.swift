import Foundation
import KernovaKit

@testable import KernovaCore
@testable import KernovaUI

// KernovaTests compiles the test-support folders into its own module;
// KernovaUITests links them as products.
#if !TEST_SUPPORT_COMPILED_IN
import KernovaTestSupport
@testable import KernovaCoreTestSupport
#endif

extension SidebarLayout.Context {
    /// A context naming networks by the app's own titling, over `networks`
    /// and no host interfaces.
    static func testing(
        bundledAgentVersion: String? = "2.0", networks: [VMNamedNetwork] = [], tags: [VMTag] = []
    ) -> SidebarLayout.Context {
        SidebarLayout.Context(
            bundledAgentVersion: bundledAgentVersion, networks: .listed(networks), tags: tags,
            networkTitle: {
                NetworkModeChoice.label(
                    of: $0, entitlements: .entitled, interfaces: { [] }, networks: .listed(networks)
                ).text
            })
    }
}
