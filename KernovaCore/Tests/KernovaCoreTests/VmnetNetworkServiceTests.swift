import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VmnetNetworkService Tests", .caseScoped)
struct VmnetNetworkServiceTests {
    private let vmA = UUID()
    private let vmB = UUID()

    @Test("A VM's own network is one no other VM's session joins")
    func anOwnNetworkIsSharedWithNoOtherVM() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let a = service.sessionNetworks(ownedBy: vmA)
        let b = service.sessionNetworks(ownedBy: vmB)

        let aOwn = try a.joinedNetwork(for: .own(.nat)).network
        let bOwn = try b.joinedNetwork(for: .own(.nat)).network
        let common = try b.joinedNetwork(for: .common(.nat)).network

        #expect(Set([aOwn, bOwn, common].map { UInt(bitPattern: $0) }).count == 3)
        // Neither session sees the other's own network as one it can join.
        #expect(b.selection(ofNetwork: aOwn) == nil)
        #expect(a.selection(ofNetwork: aOwn) == .own(.nat))
        #expect(a.selection(ofNetwork: common) == .common(.nat))
    }

    @Test("A named network is one network its members' sessions share, released with its last member's last view")
    func aNamedNetworkLivesWhileAnyMemberHoldsIt() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let lab = UUID()
        let id = VmnetNetworkID(kind: .hostOnly, scope: .named(lab))
        var a: VmnetSessionNetworks? = service.sessionNetworks(ownedBy: vmA)
        var b: VmnetSessionNetworks? = service.sessionNetworks(ownedBy: vmB)
        let outsider = service.sessionNetworks(ownedBy: UUID())

        let network = try #require(try a?.joinedNetwork(for: .named(lab, .hostOnly))).network
        #expect(try b?.joinedNetwork(for: .named(lab, .hostOnly)).network == network)
        #expect(operations.createdKinds == [.hostOnly])
        #expect(b?.selection(ofNetwork: network) == .named(lab, .hostOnly))
        // Another kind under the same identifier is another network.
        #expect(try a?.joinedNetwork(for: .named(lab, .nat)).network != network)

        a = nil
        #expect(!operations.releasedNetworks.contains(network))
        #expect(service.ipv4Subnet(for: id) != nil)

        b = nil
        #expect(operations.releasedNetworks.contains(network))
        #expect(service.ipv4Subnet(for: id) == nil)
        // A session that never joined it held nothing.
        #expect(outsider.joinedNetworkIfMaterialized(for: .named(lab, .hostOnly)) == nil)
    }
}
