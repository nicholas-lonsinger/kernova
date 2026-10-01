import Foundation
import KernovaTestSupport
import Testing
import vmnet

@testable import Kernova

@Suite("VmnetNetworkService Tests", .caseScoped)
struct VmnetNetworkServiceTests {
    private let vmA = UUID()
    private let vmB = UUID()

    /// The network the last attachment `operations` built joins.
    private func lastJoined(_ operations: MockVmnetNetworkOperator) throws -> OpaquePointer {
        try #require(operations.attachedNetworks.last)
    }

    @Test("A common network is created once and every VM's session joins it")
    func theCommonNetworkIsCreatedOnceAndShared() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let a = service.sessionNetworks(ownedBy: vmA)
        let b = service.sessionNetworks(ownedBy: vmB)

        _ = try a.attachment(for: .common(.hostOnly))
        let first = try lastJoined(operations)
        _ = try b.attachment(for: .common(.hostOnly))

        #expect(try lastJoined(operations) == first)
        #expect(operations.createdKinds == [.hostOnly])
    }

    @Test("Each kind is its own network")
    func eachKindIsItsOwnNetwork() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let view = service.sessionNetworks(ownedBy: vmA)

        _ = try view.attachment(for: .common(.shared))
        let shared = try lastJoined(operations)
        _ = try view.attachment(for: .common(.hostOnly))

        #expect(try lastJoined(operations) != shared)
        #expect(operations.createdKinds == [.shared, .hostOnly])
    }

    @Test("A VM's own network is one no other VM's session joins")
    func anOwnNetworkIsSharedWithNoOtherVM() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let a = service.sessionNetworks(ownedBy: vmA)
        let b = service.sessionNetworks(ownedBy: vmB)

        _ = try a.attachment(for: .own(.shared))
        let aOwn = try lastJoined(operations)
        _ = try b.attachment(for: .own(.shared))
        let bOwn = try lastJoined(operations)
        _ = try b.attachment(for: .common(.shared))
        let common = try lastJoined(operations)

        #expect(Set([aOwn, bOwn, common].map { UInt(bitPattern: $0) }).count == 3)
        // Neither session sees the other's own network as one it can join.
        #expect(b.selection(ofNetwork: aOwn) == nil)
        #expect(a.selection(ofNetwork: aOwn) == .own(.shared))
        #expect(a.selection(ofNetwork: common) == .common(.shared))
    }

    @Test("Two sessions of one VM share its own network")
    func sessionsOfOneVMShareItsOwnNetwork() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let first = service.sessionNetworks(ownedBy: vmA)
        let second = service.sessionNetworks(ownedBy: vmA)

        _ = try first.attachment(for: .own(.hostOnly))
        #expect(second.attachmentIfMaterialized(for: .own(.hostOnly)) != nil)
        #expect(operations.createdKinds == [.hostOnly])
    }

    @Test("A VM's own networks are released with its last session view, and only then")
    func ownNetworksLiveExactlyAsLongAsAView() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let own = VmnetNetworkID(kind: .shared, owner: vmA)
        var first: (any VmnetSessionNetworking)? = service.sessionNetworks(ownedBy: vmA)
        var second: (any VmnetSessionNetworking)? = service.sessionNetworks(ownedBy: vmA)
        _ = try first?.attachment(for: .own(.shared))
        _ = try first?.attachment(for: .common(.shared))
        let ownNetwork = try #require(operations.attachedNetworks.first)
        #expect(service.ipv4Subnet(for: own) != nil)

        first = nil
        #expect(operations.releasedNetworks.isEmpty)
        #expect(second?.attachmentIfMaterialized(for: .own(.shared)) != nil)

        second = nil
        #expect(operations.releasedNetworks == [ownNetwork])
        #expect(service.ipv4Subnet(for: own) == nil)
        // The common network is held for the life of the process.
        #expect(service.ipv4Subnet(for: .common(.shared)) != nil)
    }

    @Test("A creation failure reaches the caller, and the next request tries again")
    func aFailedCreateIsRetriedByTheNextRequest() throws {
        let operations = MockVmnetNetworkOperator()
        operations.createNetworkError = TestFailure("daemon unavailable")
        let service = VmnetNetworkService(operations: operations)
        let view = service.sessionNetworks(ownedBy: vmA)

        #expect(throws: TestFailure.self) { try view.attachment(for: .own(.shared)) }
        #expect(view.attachmentIfMaterialized(for: .own(.shared)) == nil)

        operations.createNetworkError = nil
        _ = try view.attachment(for: .own(.shared))
        #expect(operations.createdKinds == [.shared, .shared])
    }

    @Test("materializeNetwork reports whether the network exists afterwards")
    func materializeReportsTheOutcome() async {
        let operations = MockVmnetNetworkOperator()
        operations.createNetworkError = TestFailure("daemon unavailable")
        let service = VmnetNetworkService(operations: operations)
        let view = service.sessionNetworks(ownedBy: vmA)

        #expect(await view.materializeNetwork(for: .common(.hostOnly)) == false)
        operations.createNetworkError = nil
        #expect(await view.materializeNetwork(for: .common(.hostOnly)))
        #expect(await view.materializeNetwork(for: .common(.hostOnly)))
        #expect(operations.createdKinds == [.hostOnly, .hostOnly])
    }

    @Test("The non-blocking attachment is offered only once the network exists")
    func theNonBlockingAttachmentWaitsForTheNetwork() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let view = service.sessionNetworks(ownedBy: vmA)

        #expect(view.attachmentIfMaterialized(for: .common(.shared)) == nil)
        #expect(operations.createdKinds.isEmpty)

        _ = try view.attachment(for: .common(.shared))
        #expect(view.attachmentIfMaterialized(for: .common(.shared)) != nil)
        // Both attachments join the one network.
        #expect(operations.attachedNetworks.count == 2)
        #expect(Set(operations.attachedNetworks.map { UInt(bitPattern: $0) }).count == 1)
    }

    @Test("A network's subnet is known exactly while it is held")
    func theSubnetIsTheHeldNetworks() throws {
        let operations = MockVmnetNetworkOperator()
        operations.subnet = .scripted("192.168.65.0")
        let service = VmnetNetworkService(operations: operations)
        let view = service.sessionNetworks(ownedBy: vmA)

        #expect(service.ipv4Subnet(for: .common(.shared)) == nil)
        _ = try view.attachment(for: .common(.shared))

        #expect(service.ipv4Subnet(for: .common(.shared)) == .scripted("192.168.65.0"))
        #expect(service.ipv4Subnet(for: .common(.hostOnly)) == nil)
        #expect(service.ipv4Subnet(for: VmnetNetworkID(kind: .shared, owner: vmA)) == nil)
    }

    @Test("selection(ofNetwork:) answers for held networks only")
    func selectionOfNetworkAnswersForHeldNetworksOnly() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let view = service.sessionNetworks(ownedBy: vmA)
        _ = try view.attachment(for: .common(.hostOnly))
        let hostOnly = try lastJoined(operations)
        _ = try view.attachment(for: .common(.shared))
        let shared = try lastJoined(operations)

        #expect(view.selection(ofNetwork: hostOnly) == .common(.hostOnly))
        #expect(view.selection(ofNetwork: shared) == .common(.shared))

        let foreign = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer { foreign.deallocate() }
        #expect(view.selection(ofNetwork: OpaquePointer(foreign)) == nil)
    }
}
