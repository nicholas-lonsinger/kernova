import Foundation
import Virtualization

@testable import Kernova

/// Scripted stand-in for `VmnetNetworkOperating`, so service tests run without
/// the real vmnet call — an XPC round-trip to the NetworkSharing daemon that
/// fails in a build without `com.apple.vm.networking`.
///
/// Every handle wraps a fabricated pointer, distinct per call so a test can
/// tell a cached handle from a freshly materialized one.
final class MockVmnetNetworkOperator: VmnetNetworkOperating, @unchecked Sendable {
    /// The addressing a fresh (unpinned) create reserves.
    var freshAddressing = VmnetNetworkAddressing(
        ipv4Subnet: "192.168.213.0", ipv4Mask: "255.255.255.0",
        ipv6Prefix: "fd5a:1c2b:3d4e:5f60::", ipv6PrefixLength: 64)

    // MARK: - Error Injection

    /// Thrown by every create when set.
    var createNetworkError: (any Error)?
    /// Thrown only by pinned creates when set — the "stored addressing is no
    /// longer reservable" case.
    var pinnedCreateError: (any Error)?

    // MARK: - Recorded calls

    private(set) var createdKinds: [VmnetNetworkKind] = []
    private(set) var pinnedAddressings: [VmnetNetworkAddressing?] = []

    private var fabricatedNetworks: [UnsafeMutableRawPointer] = []

    deinit { fabricatedNetworks.forEach { $0.deallocate() } }

    func createNetwork(_ kind: VmnetNetworkKind, addressing: VmnetNetworkAddressing?) throws
        -> (handle: VmnetNetworkHandle, addressing: VmnetNetworkAddressing)
    {
        createdKinds.append(kind)
        pinnedAddressings.append(addressing)
        if let createNetworkError { throw createNetworkError }
        if addressing != nil, let pinnedCreateError { throw pinnedCreateError }
        return (makeHandle(), addressing ?? freshAddressing)
    }

    /// A handle over a one-byte allocation standing in for the vmnet ref:
    /// distinct per call, and nothing ever reads what it points at.
    private func makeHandle() -> VmnetNetworkHandle {
        let network = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        fabricatedNetworks.append(network)
        return VmnetNetworkHandle(network: OpaquePointer(network))
    }
}

/// Scripted stand-in for `VmnetNetworkProviding`, so attachment-building tests
/// name a Host Only attachment without materializing a vmnet network.
///
/// `scriptedAttachment` is a NAT attachment purely as a stand-in object —
/// callers only compare its identity.
final class MockVmnetNetworkProvider: VmnetNetworkProviding, @unchecked Sendable {
    var scriptedAttachment: VZNetworkDeviceAttachment = VZNATNetworkDeviceAttachment()

    // MARK: - Error Injection

    var attachmentError: (any Error)?

    private(set) var requestedKinds: [VmnetNetworkKind] = []

    func attachment(for kind: VmnetNetworkKind) throws -> VZNetworkDeviceAttachment {
        requestedKinds.append(kind)
        if let attachmentError { throw attachmentError }
        return scriptedAttachment
    }
}
