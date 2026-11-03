import Foundation
import KernovaCommandModel

@testable import KernovaCore
@testable import KernovaCoreTestSupport

extension SidebarLayout.Context {
    /// A context naming networks by the app's own titling, over `networks`
    /// and no host interfaces.
    static func testing(
        bundledPayloadHashes: [VMGuestOS: Data] = [.macOS: .testingPayloadHash], networks: [VMNamedNetwork] = [],
        tags: [VMTag] = []
    ) -> SidebarLayout.Context {
        SidebarLayout.Context(
            bundledPayloadHashes: bundledPayloadHashes, networks: .listed(networks), tags: tags,
            networkTitle: {
                NetworkModeChoice.label(
                    of: $0, entitlements: .entitled, interfaces: { [] }, networks: .listed(networks)
                ).text
            })
    }
}

extension Data {
    /// The hash ``SidebarLayout/Context/testing(bundledPayloadHashes:networks:tags:)`` gives the macOS agent's
    /// bundled payload by default.
    static let testingPayloadHash = Data(repeating: 0xA1, count: 32)
}
