import Foundation
import KernovaKit
import KernovaTestSupport
import Testing
import vmnet

@testable import Kernova

@Suite("VmnetNetworkService Tests", .admissionGated)
struct VmnetNetworkServiceTests {
    @Test("The first request creates the network, and every later one returns it")
    func theNetworkIsCreatedOnceAndHeld() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)

        let first = try service.network(for: .hostOnly)
        let second = try service.network(for: .hostOnly)

        // Every concurrent VM in the mode shares the one network, and it is held
        // for the life of the process.
        #expect(first.network == second.network)
        #expect(operations.createdKinds == [.hostOnly])
    }

    @Test("Each kind is its own network")
    func eachKindIsItsOwnNetwork() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)

        let shared = try service.network(for: .shared)
        let hostOnly = try service.network(for: .hostOnly)

        #expect(shared.network != hostOnly.network)
        #expect(operations.createdKinds == [.shared, .hostOnly])
    }

    @Test("A creation failure reaches the caller, and the next request tries again")
    func aFailedCreateIsRetriedByTheNextRequest() throws {
        let operations = MockVmnetNetworkOperator()
        operations.createNetworkError = TestFailure("daemon unavailable")
        let service = VmnetNetworkService(operations: operations)

        #expect(throws: TestFailure.self) { try service.network(for: .shared) }
        #expect(service.attachmentIfMaterialized(for: .shared) == nil)

        operations.createNetworkError = nil
        _ = try service.network(for: .shared)
        #expect(operations.createdKinds == [.shared, .shared])
    }

    @Test("materializeNetwork reports whether the network exists afterwards")
    func materializeReportsTheOutcome() async {
        let operations = MockVmnetNetworkOperator()
        operations.createNetworkError = TestFailure("daemon unavailable")
        let service = VmnetNetworkService(operations: operations)

        #expect(await service.materializeNetwork(for: .hostOnly) == false)
        operations.createNetworkError = nil
        #expect(await service.materializeNetwork(for: .hostOnly))
        #expect(await service.materializeNetwork(for: .hostOnly))
        #expect(operations.createdKinds == [.hostOnly, .hostOnly])
    }

    @Test("The non-blocking attachment is offered only once the network exists")
    func theNonBlockingAttachmentWaitsForTheNetwork() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)

        #expect(service.attachmentIfMaterialized(for: .shared) == nil)
        #expect(operations.createdKinds.isEmpty)

        _ = try service.attachment(for: .shared)
        #expect(service.attachmentIfMaterialized(for: .shared) != nil)
        // Both attachments join the one network.
        #expect(operations.attachedNetworks.count == 2)
        #expect(Set(operations.attachedNetworks.map { UInt(bitPattern: $0) }).count == 1)
    }

    @Test("A network's subnet is known exactly while it is held")
    func theSubnetIsTheHeldNetworks() throws {
        let operations = MockVmnetNetworkOperator()
        operations.subnet = .scripted("192.168.65.0")
        let service = VmnetNetworkService(operations: operations)

        #expect(service.ipv4Subnet(for: .shared) == nil)
        _ = try service.network(for: .shared)

        #expect(service.ipv4Subnet(for: .shared) == .scripted("192.168.65.0"))
        #expect(service.ipv4Subnet(for: .hostOnly) == nil)
    }

    @Test("kind(ofNetwork:) answers for held networks only")
    func kindOfNetworkAnswersForHeldNetworksOnly() throws {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations)
        let hostOnly = try service.network(for: .hostOnly)
        let shared = try service.network(for: .shared)

        #expect(service.kind(ofNetwork: hostOnly.network) == .hostOnly)
        #expect(service.kind(ofNetwork: shared.network) == .shared)

        let foreign = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        defer { foreign.deallocate() }
        #expect(service.kind(ofNetwork: OpaquePointer(foreign)) == nil)
    }
}
