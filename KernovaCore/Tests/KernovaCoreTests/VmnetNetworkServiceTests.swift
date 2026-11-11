import Foundation
import KernovaCommandModel
import KernovaKit
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

    @Test("A VM's own networks are released with its last session view, and only then")
    func ownNetworksLiveExactlyAsLongAsAView() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let own = VmnetNetworkID(kind: .nat, scope: .vm(vmA))
        var first: VmnetSessionNetworks? = service.sessionNetworks(ownedBy: vmA)
        var second: VmnetSessionNetworks? = service.sessionNetworks(ownedBy: vmA)
        _ = try first?.joinedNetwork(for: .common(.nat))
        let ownNetwork = try #require(try first?.joinedNetwork(for: .own(.nat)).network)
        #expect(service.ipv4Subnet(for: own) != nil)

        first = nil
        #expect(operations.releasedNetworks.isEmpty)
        #expect(second?.joinedNetworkIfMaterialized(for: .own(.nat)) != nil)

        second = nil
        #expect(operations.releasedNetworks == [ownNetwork])
        #expect(service.ipv4Subnet(for: own) == nil)
        // The common network is held for the life of the process.
        #expect(service.ipv4Subnet(for: .common(.nat)) != nil)
    }

    @Test("A network's subnet is known exactly while it is held")
    func theSubnetIsTheHeldNetworks() throws {
        let operations = MockVmnetNetworkOperator()
        operations.setSubnet(.scripted("192.168.65.0"))
        let service = VmnetNetworkService(operations: operations)
        let view = service.sessionNetworks(ownedBy: vmA)

        #expect(service.ipv4Subnet(for: .common(.nat)) == nil)
        _ = try view.joinedNetwork(for: .common(.nat))

        #expect(service.ipv4Subnet(for: .common(.nat)) == .scripted("192.168.65.0"))
        #expect(service.ipv4Subnet(for: .common(.hostOnly)) == nil)
        #expect(service.ipv4Subnet(for: VmnetNetworkID(kind: .nat, scope: .vm(vmA))) == nil)
    }

    @Test("selection(ofNetwork:) answers for held networks only")
    func selectionOfNetworkAnswersForHeldNetworksOnly() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let view = service.sessionNetworks(ownedBy: vmA)
        let hostOnly = try view.joinedNetwork(for: .common(.hostOnly)).network
        let nat = try view.joinedNetwork(for: .common(.nat)).network

        #expect(view.selection(ofNetwork: hostOnly) == .common(.hostOnly))
        #expect(view.selection(ofNetwork: nat) == .common(.nat))

        let foreign = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer { foreign.deallocate() }
        #expect(view.selection(ofNetwork: OpaquePointer(foreign)) == nil)
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
