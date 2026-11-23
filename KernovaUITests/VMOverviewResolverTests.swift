import AVFoundation
import KernovaCommandModel
import KernovaTestSupport
import Synchronization
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

@Suite("VM Overview Resolver Tests", .serialized, .caseScoped)
@MainActor
struct VMOverviewResolverTests {
    // MARK: - Mode titles

    @Test("NAT reads NAT on every display surface, and its raw values are nat")
    func natModeReadsNAT() {
        #expect(VMNetworkMode.nat.title == "NAT")
        #expect(VMNetworkMode.nat.rawValue == "nat")
        #expect(VmnetNetworkKind.nat.rawValue == "nat")
        #expect(NetworkKind.nat.rawValue == "nat")
        // Shortcuts reads a literal table; it names each kind as the app does.
        for kind in [VMNetworkKind.nat, .hostOnly] {
            #expect(
                String(localized: VMNetworkKind.caseDisplayRepresentations[kind]!.title)
                    == VmnetNetworkKind(kind.kind).mode.title)
        }
        #expect(VMNetworkKind.nat.rawValue == "nat")
        #expect(NetworksSettingsViewController.kindTitle(.nat) == "NAT")
    }
}
