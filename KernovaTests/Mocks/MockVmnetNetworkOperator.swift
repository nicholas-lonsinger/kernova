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
    /// Whether the network counts as materialized: `attachmentIfMaterialized`
    /// answers `nil` while `false`, and `materializeNetwork` flips it `true`
    /// unless scripted to fail.
    var isMaterialized = true
    /// When `true`, `materializeNetwork` fails and leaves `isMaterialized` as is.
    var materializeFails = false

    // MARK: - Error Injection

    var attachmentError: (any Error)?

    private(set) var requestedKinds: [VmnetNetworkKind] = []
    private(set) var materializeCount = 0
    private(set) var materializedKinds: [VmnetNetworkKind] = []
    private(set) var invalidatedKinds: [VmnetNetworkKind] = []

    func attachment(for kind: VmnetNetworkKind) throws -> VZNetworkDeviceAttachment {
        requestedKinds.append(kind)
        if let attachmentError { throw attachmentError }
        return scriptedAttachment
    }

    func attachmentIfMaterialized(for kind: VmnetNetworkKind) -> VZNetworkDeviceAttachment? {
        requestedKinds.append(kind)
        guard isMaterialized, attachmentError == nil else { return nil }
        return scriptedAttachment
    }

    func materializeNetwork(for kind: VmnetNetworkKind) async -> Bool {
        materializeCount += 1
        materializedKinds.append(kind)
        guard !materializeFails else { return false }
        isMaterialized = true
        return true
    }

    func invalidateNetwork(for kind: VmnetNetworkKind) {
        invalidatedKinds.append(kind)
        isMaterialized = false
    }

    // MARK: - Reservations

    /// Scripted answer for `reservedAddress(for:kind:)`, keyed by lowercased MAC.
    var scriptedAddresses: [String: String] = [:]
    private(set) var reservedMACs: [(mac: String, kind: VmnetNetworkKind)] = []

    func reserveAddressIfNeeded(for mac: String, kind: VmnetNetworkKind) {
        let normalized = mac.lowercased()
        guard !reservedMACs.contains(where: { $0.mac == normalized && $0.kind == kind }) else {
            return
        }
        reservedMACs.append((mac: normalized, kind: kind))
    }

    func reservedAddress(for mac: String, kind: VmnetNetworkKind) -> String? {
        scriptedAddresses[mac.lowercased()]
    }

    // MARK: - Port forwarding

    /// The rules last declared per lowercased MAC, in declaration order.
    private(set) var declaredForwardingRules: [(mac: String, rules: [PortForwardingRule])] = []
    /// Scripted answer for `portForwardingRulesArePending(for:)`.
    var scriptedPendingForwardingKinds: Set<VmnetNetworkKind> = []
    private(set) var pendingQueriedKinds: [VmnetNetworkKind] = []

    func setPortForwardingRules(
        _ rules: [PortForwardingRule], for mac: String, kind: VmnetNetworkKind
    ) {
        declaredForwardingRules.append((mac: mac.lowercased(), rules: rules))
    }

    func portForwardingRulesArePending(for kind: VmnetNetworkKind) -> Bool {
        pendingQueriedKinds.append(kind)
        // Mirrors the service: nothing pends against a network that is not
        // materialized — its next materialization installs what is declared then.
        return isMaterialized && scriptedPendingForwardingKinds.contains(kind)
    }

    /// Scripted answer for `kind(ofNetwork:)`.
    var scriptedNetworkKind: VmnetNetworkKind?

    func kind(ofNetwork network: vmnet_network_ref) -> VmnetNetworkKind? {
        scriptedNetworkKind
    }
}
