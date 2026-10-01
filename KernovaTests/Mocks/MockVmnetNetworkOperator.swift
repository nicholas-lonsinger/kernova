import Foundation
import Virtualization
import vmnet

@testable import Kernova

/// Scripted stand-in for `VmnetNetworkOperating`, so service tests run without
/// the real vmnet call — an XPC round-trip to the NetworkSharing daemon that
/// fails in a build without `com.apple.vm.networking`.
///
/// Every handle wraps a fabricated pointer, distinct per call so a test can
/// tell a cached handle from a freshly materialized one.
final class MockVmnetNetworkOperator: VmnetNetworkOperating, @unchecked Sendable {
    /// The subnet every create reports.
    var subnet = IPv4Subnet.scripted("192.168.213.0")

    /// Thrown by every create when set.
    var createNetworkError: (any Error)?

    private(set) var createdKinds: [VmnetNetworkKind] = []
    /// The network each attachment was built to join, in call order.
    private(set) var attachedNetworks: [OpaquePointer] = []
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

    /// A NAT attachment standing in for the vmnet one, which would retain the
    /// fabricated pointer as a real network.
    func attachment(joining handle: VmnetNetworkHandle) -> VZNetworkDeviceAttachment {
        attachedNetworks.append(handle.network)
        return VZNATNetworkDeviceAttachment()
    }

    /// Records the release; the fabricated pointer is freed with the mock.
    func releaseNetwork(_ handle: VmnetNetworkHandle) {
        releasedNetworks.append(handle.network)
    }
}

/// Scripted stand-in for both vmnet provider seams, so attachment-building and
/// recovery tests name a vmnet attachment without materializing a network.
/// Every session view it opens is itself.
///
/// `scriptedAttachment` is a NAT attachment purely as a stand-in object —
/// callers only compare its identity.
final class MockVmnetNetworkProvider: VmnetNetworkProviding, VmnetSessionNetworking, @unchecked Sendable {
    var scriptedAttachment: VZNetworkDeviceAttachment = VZNATNetworkDeviceAttachment()
    /// The networks counting as materialized. `attachmentIfMaterialized` and
    /// `ipv4Subnet` answer `nil` for one not in it, and `materializeNetwork`
    /// inserts.
    var materializedNetworks: Set<VmnetNetworkSelection> = Set(
        VmnetNetworkKind.allCases.flatMap { [.common($0), .own($0)] })
    /// When `true`, `materializeNetwork` fails and leaves `materializedNetworks` as is.
    var materializeFails = false
    /// The subnet each network hands its guests, which `ipv4Subnet(for:)`
    /// serves only while it is materialized, as the service does.
    var scriptedSubnets: [VmnetNetworkID: IPv4Subnet] = [
        .common(.shared): .scripted("192.168.64.0"), .common(.hostOnly): .scripted("192.168.128.0"),
    ]

    var attachmentError: (any Error)?

    /// The VM each session view was opened for, in call order.
    private(set) var openedOwners: [UUID] = []
    private(set) var requestedNetworks: [VmnetNetworkSelection] = []
    private(set) var materializeCount = 0
    /// Every `materializeNetwork` call, in order — failures included.
    private(set) var materializeRequestedNetworks: [VmnetNetworkSelection] = []

    func sessionNetworks(ownedBy owner: UUID) -> any VmnetSessionNetworking {
        openedOwners.append(owner)
        return self
    }

    func ipv4Subnet(for network: VmnetNetworkID) -> IPv4Subnet? {
        let selection = VmnetNetworkSelection(kind: network.kind, isOwn: network.owner != nil)
        guard materializedNetworks.contains(selection) else { return nil }
        return scriptedSubnets[network]
    }

    func attachment(for network: VmnetNetworkSelection) throws -> VZNetworkDeviceAttachment {
        requestedNetworks.append(network)
        if let attachmentError { throw attachmentError }
        return scriptedAttachment
    }

    func attachmentIfMaterialized(for network: VmnetNetworkSelection) -> VZNetworkDeviceAttachment? {
        requestedNetworks.append(network)
        guard materializedNetworks.contains(network), attachmentError == nil else { return nil }
        return scriptedAttachment
    }

    func materializeNetwork(for network: VmnetNetworkSelection) async -> Bool {
        materializeCount += 1
        materializeRequestedNetworks.append(network)
        guard !materializeFails else { return false }
        materializedNetworks.insert(network)
        return true
    }

    func selection(ofNetwork network: vmnet_network_ref) -> VmnetNetworkSelection? {
        nil
    }
}

extension VmnetNetworkSelection {
    static func common(_ kind: VmnetNetworkKind) -> Self { Self(kind: kind, isOwn: false) }
    static func own(_ kind: VmnetNetworkKind) -> Self { Self(kind: kind, isOwn: true) }
}
