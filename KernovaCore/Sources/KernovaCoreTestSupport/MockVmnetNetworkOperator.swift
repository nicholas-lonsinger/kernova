import Foundation
import KernovaKit
import Synchronization
import Testing

@testable import KernovaCore

/// Scripted stand-in for `VmnetNetworkOperating`, so service tests run
/// without the real vmnet call — an XPC round-trip to the
/// NetworkSharing daemon that fails in a build without
/// `com.apple.vm.networking`.
///
/// Every handle wraps a fabricated pointer, distinct per call so a test can
/// tell a cached handle from a freshly materialized one.
final class MockVmnetNetworkOperator: VmnetNetworkOperating {
    private struct State {
        var subnet = IPv4Subnet.scripted("192.168.213.0")
        var createNetworkError: (any Error)?
        var createdKinds: [VmnetNetworkKind] = []
        var released: [VmnetNetworkHandle] = []
        var fabricated: [VmnetNetworkHandle] = []
    }

    private let state = Mutex(State())

    deinit {
        state.withLock { $0.fabricated }.forEach { UnsafeMutableRawPointer($0.network).deallocate() }
    }

    /// Sets the subnet every later create reports.
    func setSubnet(_ subnet: IPv4Subnet) {
        state.withLock { $0.subnet = subnet }
    }

    /// Sets the error every later create throws; `nil` clears it.
    func setCreateNetworkError(_ error: (any Error)?) {
        state.withLock { $0.createNetworkError = error }
    }

    /// Every kind a create was asked for, in call order.
    var createdKinds: [VmnetNetworkKind] { state.withLock { $0.createdKinds } }

    /// Every network given back, in call order.
    var releasedNetworks: [OpaquePointer] { state.withLock { $0.released }.map(\.network) }

    func createNetwork(_ kind: VmnetNetworkKind) throws -> (
        handle: VmnetNetworkHandle, subnet: IPv4Subnet
    ) {
        try state.withLock { state in
            state.createdKinds.append(kind)
            if let error = state.createNetworkError { throw error }
            let handle = VmnetNetworkHandle(
                network: OpaquePointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)))
            state.fabricated.append(handle)
            return (handle, state.subnet)
        }
    }

    /// Records the release; the fabricated pointer is freed with the mock.
    func releaseNetwork(_ handle: VmnetNetworkHandle) {
        state.withLock { $0.released.append(handle) }
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
    /// The views `materialize(_:on:owner:)` opened. A network other than a
    /// common one exists only while a view of one of its members lives.
    private var heldViews: [VmnetSessionNetworks] = []

    init() {
        service = VmnetNetworkService(operations: operations)
    }

    /// Materializes `network` on the /24 at `subnet`, joined by `owner`
    /// through a view this fixture keeps open.
    func materialize(_ network: VmnetNetworkSelection, on subnet: String, owner: UUID = UUID()) {
        let view = service.sessionNetworks(ownedBy: owner)
        materialize(network, on: subnet, through: view)
        heldViews.append(view)
    }

    /// Materializes `network` through `view`, on the /24 at `subnet` when
    /// given. A VM is on one network at a time, so this takes `view`'s VM off
    /// the network it joined before — releasing it when the VM was its last
    /// member.
    func materialize(
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
