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
    /// One create call's forwarding-rule argument.
    typealias RecordedForwardingRules = [(rule: PortForwardingRule, internalAddress: String)]

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

    /// When set, a pinned create reserves this instead of the pin — the
    /// "system adjusted the addressing" case.
    var reservedAddressingOverride: VmnetNetworkAddressing?

    private(set) var createdKinds: [VmnetNetworkKind] = []
    private(set) var pinnedAddressings: [VmnetNetworkAddressing?] = []
    private(set) var installedReservations: [[(mac: String, address: String)]] = []
    /// The forwarding rules each create was handed, in call order.
    private(set) var installedForwardingRules: [RecordedForwardingRules] = []
    private(set) var releasedNetworks: [OpaquePointer] = []

    /// Runs inside each create, before it returns, with the 1-based number of
    /// the call — the seam for a test that has to change service state while a
    /// create is in flight.
    var duringCreateNetwork: ((Int) -> Void)?

    private var fabricatedNetworks: [UnsafeMutableRawPointer] = []

    deinit { fabricatedNetworks.forEach { $0.deallocate() } }

    func createNetwork(
        _ kind: VmnetNetworkKind,
        addressing: VmnetNetworkAddressing?,
        reservations: [(mac: String, address: String)],
        forwardingRules: [(rule: PortForwardingRule, internalAddress: String)]
    ) throws -> (handle: VmnetNetworkHandle, addressing: VmnetNetworkAddressing) {
        createdKinds.append(kind)
        pinnedAddressings.append(addressing)
        installedReservations.append(reservations)
        installedForwardingRules.append(forwardingRules)
        duringCreateNetwork?(createdKinds.count)
        if let createNetworkError { throw createNetworkError }
        if addressing != nil, let pinnedCreateError { throw pinnedCreateError }
        return (makeHandle(), reservedAddressingOverride ?? addressing ?? freshAddressing)
    }

    func releaseNetwork(_ handle: VmnetNetworkHandle) {
        releasedNetworks.append(handle.network)
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
    /// The kinds counting as materialized — held per kind, since one pass of the
    /// idle rebuild queries every kind and a shared flag would let the first
    /// invalidation mask the rest. `attachmentIfMaterialized` answers `nil` for
    /// a kind not in it, `materializeNetwork` inserts, and `invalidateNetwork`
    /// removes.
    var materializedKinds: Set<VmnetNetworkKind> = Set(VmnetNetworkKind.allCases)
    /// When `true`, `materializeNetwork` fails and leaves `materializedKinds` as is.
    var materializeFails = false

    // MARK: - Error Injection

    var attachmentError: (any Error)?

    private(set) var requestedKinds: [VmnetNetworkKind] = []
    private(set) var materializeCount = 0
    /// Every `materializeNetwork` call, in order — failures included.
    private(set) var materializeRequestedKinds: [VmnetNetworkKind] = []
    private(set) var invalidatedKinds: [VmnetNetworkKind] = []

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

    func invalidateNetwork(for kind: VmnetNetworkKind) {
        invalidatedKinds.append(kind)
        materializedKinds.remove(kind)
    }

    // MARK: - Reservations

    /// Scripted answer for `reservedAddress(for:kind:)`, keyed by lowercased MAC.
    var scriptedAddresses: [String: String] = [:]
    /// The slots currently held, so a test reads the live set rather than a
    /// call log — mirroring the service, where a release frees the slot.
    private(set) var reservedMACs: [(mac: String, kind: VmnetNetworkKind)] = []
    /// Every release, in call order — kept alongside `reservedMACs` so a test
    /// can assert a release happened, and that it preceded a reserve.
    private(set) var releasedMACs: [(mac: String, kind: VmnetNetworkKind)] = []
    /// Every retain set, in call order.
    private(set) var retainedMACs: [(macs: Set<String>, kind: VmnetNetworkKind)] = []

    func reserveAddressIfNeeded(for mac: String, kind: VmnetNetworkKind) {
        let normalized = mac.lowercased()
        guard !reservedMACs.contains(where: { $0.mac == normalized && $0.kind == kind }) else {
            return
        }
        reservedMACs.append((mac: normalized, kind: kind))
    }

    func releaseAddressReservation(for mac: String, kind: VmnetNetworkKind) {
        let normalized = mac.lowercased()
        releasedMACs.append((mac: normalized, kind: kind))
        reservedMACs.removeAll { $0.mac == normalized && $0.kind == kind }
    }

    func retainAddressReservations(_ macs: Set<String>, kind: VmnetNetworkKind) {
        let retained = Set(macs.map { $0.lowercased() })
        retainedMACs.append((macs: retained, kind: kind))
        reservedMACs.removeAll { $0.kind == kind && !retained.contains($0.mac) }
    }

    func reservedAddress(for mac: String, kind: VmnetNetworkKind) -> String? {
        scriptedAddresses[mac.lowercased()]
    }

    // MARK: - Port forwarding

    /// The rules last declared per lowercased MAC, in declaration order.
    private(set) var declaredForwardingRules: [(mac: String, rules: [PortForwardingRule])] = []
    /// Scripted answer for `networkConfigurationIsPending(for:)`.
    var scriptedPendingKinds: Set<VmnetNetworkKind> = []

    func setPortForwardingRules(
        _ rules: [PortForwardingRule], for mac: String, kind: VmnetNetworkKind
    ) {
        declaredForwardingRules.append((mac: mac.lowercased(), rules: rules))
    }

    func networkConfigurationIsPending(for kind: VmnetNetworkKind) -> Bool {
        // Mirrors the service: nothing pends against a network that is not
        // materialized — its next materialization installs what is declared then.
        materializedKinds.contains(kind) && scriptedPendingKinds.contains(kind)
    }

    func kind(ofNetwork network: vmnet_network_ref) -> VmnetNetworkKind? {
        nil
    }
}
