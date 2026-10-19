import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VmnetNetworkService Tests", .caseScoped)
struct VmnetNetworkServiceTests {
    private let vmA = UUID()
    private let vmB = UUID()

    @Test("A common network is created once and every VM's session joins it")
    func theCommonNetworkIsCreatedOnceAndShared() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let a = service.sessionNetworks(ownedBy: vmA)
        let b = service.sessionNetworks(ownedBy: vmB)

        let first = try a.joinedNetwork(for: .common(.hostOnly)).network
        let second = try b.joinedNetwork(for: .common(.hostOnly)).network

        #expect(second == first)
        #expect(operations.createdKinds == [.hostOnly])
    }

    @Test("Each kind is its own network")
    func eachKindIsItsOwnNetwork() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let view = service.sessionNetworks(ownedBy: vmA)

        let nat = try view.joinedNetwork(for: .common(.nat)).network
        let hostOnly = try view.joinedNetwork(for: .common(.hostOnly)).network

        #expect(hostOnly != nat)
        #expect(operations.createdKinds == [.nat, .hostOnly])
    }

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

    @Test("Two sessions of one VM share its own network")
    func sessionsOfOneVMShareItsOwnNetwork() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let first = service.sessionNetworks(ownedBy: vmA)
        let second = service.sessionNetworks(ownedBy: vmA)

        _ = try first.joinedNetwork(for: .own(.hostOnly))
        #expect(second.joinedNetworkIfMaterialized(for: .own(.hostOnly)) != nil)
        #expect(operations.createdKinds == [.hostOnly])
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

    @Test("A handle a caller still holds keeps its network after the service lets go")
    func aHeldHandleKeepsItsNetwork() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let view = service.sessionNetworks(ownedBy: vmA)
        var held: VmnetNetworkHandle? = try view.joinedNetwork(for: .own(.nat))
        let network = try #require(held?.network)

        _ = try view.joinedNetwork(for: .own(.hostOnly))
        #expect(service.ipv4Subnet(for: VmnetNetworkID(kind: .nat, scope: .vm(vmA))) == nil)
        #expect(operations.releasedNetworks.isEmpty)

        held = nil
        #expect(operations.releasedNetworks == [network])
    }

    @Test("A creation failure reaches the caller, and the next request tries again")
    func aFailedCreateIsRetriedByTheNextRequest() throws {
        let operations = MockVmnetNetworkOperator()
        operations.setCreateNetworkError(TestFailure("daemon unavailable"))
        let service = VmnetNetworkService(operations: operations)
        let view = service.sessionNetworks(ownedBy: vmA)

        #expect(throws: TestFailure.self) { try view.joinedNetwork(for: .own(.nat)) }
        #expect(view.joinedNetworkIfMaterialized(for: .own(.nat)) == nil)

        operations.setCreateNetworkError(nil)
        _ = try view.joinedNetwork(for: .own(.nat))
        #expect(operations.createdKinds == [.nat, .nat])
    }

    @Test("materializeNetwork reports whether the network exists afterwards")
    func materializeReportsTheOutcome() async {
        let operations = MockVmnetNetworkOperator()
        operations.setCreateNetworkError(TestFailure("daemon unavailable"))
        let service = VmnetNetworkService(operations: operations)
        let view = service.sessionNetworks(ownedBy: vmA)

        #expect(await view.materializeNetwork(for: .common(.hostOnly)) == false)
        operations.setCreateNetworkError(nil)
        #expect(await view.materializeNetwork(for: .common(.hostOnly)))
        #expect(await view.materializeNetwork(for: .common(.hostOnly)))
        #expect(operations.createdKinds == [.hostOnly, .hostOnly])
    }

    @Test("The non-blocking join answers only once the network exists")
    func theNonBlockingAttachmentWaitsForTheNetwork() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let view = service.sessionNetworks(ownedBy: vmA)

        #expect(view.joinedNetworkIfMaterialized(for: .common(.nat)) == nil)
        #expect(operations.createdKinds.isEmpty)

        let joined = try view.joinedNetwork(for: .common(.nat))
        // Both answers are the one network.
        #expect(view.joinedNetworkIfMaterialized(for: .common(.nat))?.network == joined.network)
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

    @Test("A VM that joins another network leaves the one it was on, which goes with its last member")
    func joiningAnotherNetworkLeavesTheLastOne() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let view = service.sessionNetworks(ownedBy: vmA)
        let other = service.sessionNetworks(ownedBy: vmB)
        let lab = UUID()
        let bench = UUID()

        let labNetwork = try view.joinedNetwork(for: .named(lab, .nat)).network
        let benchNetwork = try other.joinedNetwork(for: .named(bench, .nat)).network
        _ = try view.joinedNetwork(for: .named(bench, .nat))
        #expect(operations.releasedNetworks == [labNetwork])

        // Bench still has its other member.
        _ = try other.joinedNetwork(for: .common(.nat))
        #expect(!operations.releasedNetworks.contains(benchNetwork))
        _ = try view.joinedNetwork(for: .own(.nat))
        #expect(operations.releasedNetworks.contains(benchNetwork))
    }
}
