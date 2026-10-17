import Foundation
import KernovaKit
import Testing

@testable import KernovaCore

/// Scripted stand-in for `VmnetNetworkOperating`, so service tests run
/// without the real vmnet call — an XPC round-trip to the
/// NetworkSharing daemon that fails in a build without
/// `com.apple.vm.networking`.
///
/// Every handle wraps a fabricated pointer, distinct per call so a test can
/// tell a cached handle from a freshly materialized one.
final class MockVmnetNetworkOperator: VmnetNetworkOperating, @unchecked Sendable {
    /// The subnet every create reports.
    var subnet = IPv4Subnet.scripted("192.168.213.0")

    /// Thrown by every create when set.
    var createNetworkError: (any Error)?

    private(set) var createdKinds: [VmnetNetworkKind] = []
    /// Every network given back, in call order.
    private(set) var releasedNetworks: [OpaquePointer] = []

    private var fabricatedNetworks: [UnsafeMutableRawPointer] = []

    deinit { fabricatedNetworks.forEach { $0.deallocate() } }

    func createNetwork(_ kind: VmnetNetworkKind) throws -> (
        handle: VmnetNetworkHandle, subnet: IPv4Subnet
    ) {
        createdKinds.append(kind)
        if let createNetworkError { throw createNetworkError }
        let network = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        fabricatedNetworks.append(network)
        return (VmnetNetworkHandle(network: OpaquePointer(network)), subnet)
    }

    /// Records the release; the fabricated pointer is freed with the mock.
    func releaseNetwork(_ handle: VmnetNetworkHandle) {
        releasedNetworks.append(handle.network)
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
final class ScriptedVmnetNetworks: @unchecked Sendable {
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
        if let subnet { operations.subnet = .scripted(subnet) }
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
