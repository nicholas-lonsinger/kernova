import Foundation
import KernovaCommandModel
import Synchronization
import Testing

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

@testable import KernovaCore

/// Scripted stand-in for `VmnetNetworkOperating`, so service tests run
/// without the real vmnet call — an XPC round-trip to the
/// NetworkSharing daemon that fails in a build without
/// `com.apple.vm.networking`.
///
/// Every handle owns a stand-in object in place of a network, which the
/// handle's own release frees and reports here. The stand-ins of networks
/// alive at once are distinct, so a test can tell a cached handle from a
/// freshly materialized one; a released stand-in's address can recur.
final class MockVmnetNetworkOperator: VmnetNetworkOperating {
    private struct State {
        var subnet = IPv4Subnet.scripted("192.168.213.0")
        var createNetworkError: (any Error)?
        var createHold: DispatchSemaphore?
        var createdKinds: [VmnetNetworkKind] = []
        var released: [UInt] = []
    }

    /// Reports its own address to `operations` when the last reference goes.
    /// Its `deinit` takes the mock's lock, so no handle is dropped under it.
    private final class StandInNetwork {
        let operations: MockVmnetNetworkOperator

        init(operations: MockVmnetNetworkOperator) {
            self.operations = operations
        }

        deinit {
            let address = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
            operations.state.withLock { $0.released.append(address) }
        }
    }

    private let state = Mutex(State())

    /// Sets the subnet every later create reports.
    func setSubnet(_ subnet: IPv4Subnet) {
        state.withLock { $0.subnet = subnet }
    }

    /// Sets the error every later create throws; `nil` clears it.
    func setCreateNetworkError(_ error: (any Error)?) {
        state.withLock { $0.createNetworkError = error }
    }

    /// Holds every later create on its own thread, after it records its kind,
    /// until `hold` is signalled; ``createEntered`` fires as the hold begins.
    /// An error set while held is the one the create throws.
    func setCreateHold(_ hold: DispatchSemaphore?) {
        state.withLock { $0.createHold = hold }
    }

    let createEntered = AsyncGate()

    /// Every kind a create was asked for, in call order.
    var createdKinds: [VmnetNetworkKind] { state.withLock { $0.createdKinds } }

    /// Every network released, in the order its last holder let go.
    var releasedNetworks: [OpaquePointer] {
        state.withLock { $0.released }.compactMap { OpaquePointer(bitPattern: $0) }
    }

    func createNetwork(_ kind: VmnetNetworkKind) throws -> (
        handle: VmnetNetworkHandle, subnet: IPv4Subnet
    ) {
        let createHold = state.withLock { state in
            state.createdKinds.append(kind)
            return state.createHold
        }
        if let createHold {
            createEntered.notify()
            createHold.wait()
        }
        let subnet = try state.withLock { state in
            if let error = state.createNetworkError { throw error }
            return state.subnet
        }
        let standIn = StandInNetwork(operations: self)
        let handle = VmnetNetworkHandle(adopting: OpaquePointer(Unmanaged.passRetained(standIn).toOpaque()))
        return (handle, subnet)
    }
}

extension VmnetNetworkService {
    /// The real service over a fresh `MockVmnetNetworkOperator`, for a test
    /// that never reads what vmnet was asked.
    static func scripted() -> VmnetNetworkService {
        VmnetNetworkService(operations: MockVmnetNetworkOperator())
    }
}

/// The real `VmnetNetworkService` over a `MockVmnetNetworkOperator`, with the
/// networks a test needs stood up on known subnets before the code under test
/// runs.
final class ScriptedVmnetNetworks {
    let operations = MockVmnetNetworkOperator()
    let service: VmnetNetworkService
    /// The views `join(_:on:owner:)` opened, which keep the networks they
    /// joined.
    private var heldViews: [VmnetSessionNetworks] = []

    init() {
        service = VmnetNetworkService(operations: operations)
    }

    /// Joins `owner` to `network`, materialized on the /24 at `subnet`,
    /// through a view this fixture keeps open.
    func join(_ network: VmnetNetworkSelection, on subnet: String, owner: UUID = UUID()) {
        let view = service.sessionNetworks(ownedBy: owner)
        join(network, on: subnet, through: view)
        heldViews.append(view)
    }

    /// Joins `view`'s VM to `network`, materialized on the /24 at `subnet`
    /// when given and not yet materialized. A VM is on one network at a time,
    /// so this takes `view`'s VM off the network it joined before — releasing
    /// it when that was its last claim.
    func join(
        _ network: VmnetNetworkSelection, on subnet: String? = nil, through view: VmnetSessionNetworks
    ) {
        if let subnet { operations.setSubnet(.scripted(subnet)) }
        do {
            _ = try view.joinedNetwork(for: network)
        } catch {
            Issue.record(error, "The scripted operator refused \(network.logDescription)")
        }
    }
}

extension VmnetNetworkSelection {
    static func common(_ kind: VmnetNetworkKind) -> Self { Self(kind: kind, membership: .common) }
    static func own(_ kind: VmnetNetworkKind) -> Self { Self(kind: kind, membership: .isolated) }
    static func named(_ id: UUID, _ kind: VmnetNetworkKind) -> Self {
        Self(kind: kind, membership: .network(id))
    }
}
