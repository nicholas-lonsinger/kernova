import Foundation
import KernovaKit
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
}

/// Scripted stand-in for `VmnetNetworkProviding`, so attachment-building tests
/// name a Host Only attachment without materializing a vmnet network.
///
/// `scriptedAttachment` is a NAT attachment purely as a stand-in object —
/// callers only compare its identity.
final class MockVmnetNetworkProvider: VmnetNetworkProviding, @unchecked Sendable {
    var scriptedAttachment: VZNetworkDeviceAttachment = VZNATNetworkDeviceAttachment()
    /// The kinds counting as materialized. `attachmentIfMaterialized` and
    /// `ipv4Subnet` answer `nil` for a kind not in it, and `materializeNetwork`
    /// inserts.
    var materializedKinds: Set<VmnetNetworkKind> = Set(VmnetNetworkKind.allCases)
    /// When `true`, `materializeNetwork` fails and leaves `materializedKinds` as is.
    var materializeFails = false
    /// The subnet each kind's network hands its guests, which
    /// `ipv4Subnet(for:)` serves only while the kind is materialized, as the
    /// service does — one for every kind, since every materialized network
    /// has one.
    var scriptedSubnets: [VmnetNetworkKind: IPv4Subnet] = [
        .shared: .scripted("192.168.64.0"), .hostOnly: .scripted("192.168.128.0"),
    ]

    var attachmentError: (any Error)?

    private(set) var requestedKinds: [VmnetNetworkKind] = []
    private(set) var materializeCount = 0
    /// Every `materializeNetwork` call, in order — failures included.
    private(set) var materializeRequestedKinds: [VmnetNetworkKind] = []

    func attachment(for kind: VmnetNetworkKind) throws -> VZNetworkDeviceAttachment {
        requestedKinds.append(kind)
        if let attachmentError { throw attachmentError }
        return scriptedAttachment
    }

    func attachmentIfMaterialized(for kind: VmnetNetworkKind) -> VZNetworkDeviceAttachment? {
        requestedKinds.append(kind)
        guard materializedKinds.contains(kind), attachmentError == nil else { return nil }
        return scriptedAttachment
    }

    func materializeNetwork(for kind: VmnetNetworkKind) async -> Bool {
        materializeCount += 1
        materializeRequestedKinds.append(kind)
        guard !materializeFails else { return false }
        materializedKinds.insert(kind)
        return true
    }

    func kind(ofNetwork network: vmnet_network_ref) -> VmnetNetworkKind? {
        nil
    }

    func ipv4Subnet(for kind: VmnetNetworkKind) -> IPv4Subnet? {
        guard materializedKinds.contains(kind) else { return nil }
        return scriptedSubnets[kind]
    }
}
