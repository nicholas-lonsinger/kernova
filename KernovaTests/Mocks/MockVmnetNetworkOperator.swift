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
    /// Thrown by every member start when set — the case a build degrades to
    /// a network nothing holds.
    var startMemberError: (any Error)?

    // MARK: - Recorded calls

    /// When set, a pinned create reserves this instead of the pin — the
    /// "system adjusted the addressing" case.
    var reservedAddressingOverride: VmnetNetworkAddressing?

    private(set) var createdKinds: [VmnetNetworkKind] = []
    private(set) var pinnedAddressings: [VmnetNetworkAddressing?] = []
    private(set) var installedReservations: [[VmnetReservation]] = []
    /// The forwarding rules each create was handed, in call order.
    private(set) var installedForwardingRules: [RecordedForwardingRules] = []
    private(set) var releasedNetworks: [OpaquePointer] = []
    /// The network each attachment was built to join, in call order.
    private(set) var attachedNetworks: [OpaquePointer] = []
    /// The network each member interface was started on, in call order.
    private(set) var startedMembers: [OpaquePointer] = []
    /// The network each stopped member was held on, in call order.
    private(set) var stoppedMembers: [OpaquePointer] = []
    /// Every member start, member stop and network release in one order, each
    /// naming the network it acted on — so a test can assert a member's stop
    /// landed before its network's ref went.
    private(set) var networkCalls: [NetworkCall] = []

    /// One recorded call in ``networkCalls``.
    enum NetworkCall: Equatable {
        case startMember(OpaquePointer)
        case stopMember(OpaquePointer)
        case releaseNetwork(OpaquePointer)
    }

    /// The network each member interface handed out was started on.
    private var memberNetworks: [OpaquePointer: OpaquePointer] = [:]

    /// Runs inside each create, before it returns, with the 1-based number of
    /// the call — the seam for a test that has to change service state while a
    /// create is in flight.
    var duringCreateNetwork: ((Int) -> Void)?

    private var fabricatedPointers: [UnsafeMutableRawPointer] = []

    deinit { fabricatedPointers.forEach { $0.deallocate() } }

    func createNetwork(
        _ kind: VmnetNetworkKind,
        addressing: VmnetNetworkAddressing?,
        reservations: [VmnetReservation],
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
        networkCalls.append(.releaseNetwork(handle.network))
    }

    func startMember(on handle: VmnetNetworkHandle) throws -> VmnetMemberHandle {
        startedMembers.append(handle.network)
        networkCalls.append(.startMember(handle.network))
        if let startMemberError { throw startMemberError }
        let interface = fabricatePointer()
        memberNetworks[interface] = handle.network
        return VmnetMemberHandle(interface: interface)
    }

    func stopMember(_ member: VmnetMemberHandle) {
        guard let network = memberNetworks[member.interface] else { return }
        stoppedMembers.append(network)
        networkCalls.append(.stopMember(network))
    }

    /// A NAT attachment standing in for the vmnet one, which would retain the
    /// fabricated pointer as a real network.
    func attachment(joining handle: VmnetNetworkHandle) -> VZNetworkDeviceAttachment {
        attachedNetworks.append(handle.network)
        return VZNATNetworkDeviceAttachment()
    }

    /// A handle over a one-byte allocation standing in for the vmnet ref:
    /// distinct per call, and nothing ever reads what it points at.
    private func makeHandle() -> VmnetNetworkHandle {
        VmnetNetworkHandle(network: fabricatePointer())
    }

    /// A one-byte allocation standing in for a vmnet ref, distinct per call.
    private func fabricatePointer() -> OpaquePointer {
        let allocation = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
        fabricatedPointers.append(allocation)
        return OpaquePointer(allocation)
    }
}

/// Scripted stand-in for `VmnetNetworkProviding` and `VmnetNetworkRecreating`,
/// so attachment-building tests name a Host Only attachment without
/// materializing a vmnet network.
///
/// `scriptedAttachment` is a NAT attachment purely as a stand-in object —
/// callers only compare its identity.
final class MockVmnetNetworkProvider: VmnetNetworkProviding, VmnetNetworkRecreating,
    @unchecked Sendable
{
    var scriptedAttachment: VZNetworkDeviceAttachment = VZNATNetworkDeviceAttachment()
    /// The kinds counting as materialized — held per kind, since one pass of the
    /// idle rebuild queries every kind and a shared flag would let the first
    /// invalidation mask the rest. `attachmentIfMaterialized` answers `nil` for
    /// a kind not in it, `materializeNetwork` inserts, and `invalidateNetwork`
    /// removes.
    var materializedKinds: Set<VmnetNetworkKind> = Set(VmnetNetworkKind.allCases)
    /// When `true`, `materializeNetwork` fails and leaves `materializedKinds` as is.
    var materializeFails = false
    /// The kinds whose run the service would be holding a member interface
    /// for — a suite opts one in to script the idle pass ending that run.
    /// `endRunIfHeld` takes a kind out of it and leaves the network wanting a
    /// recreate.
    var heldRunKinds: Set<VmnetNetworkKind> = []
    /// The kinds whose addressing is established, as `networks.json` carries it
    /// across launches. Defaults to every kind — a suite opts into the
    /// fresh-machine case, where the registry learns the addressing, by
    /// emptying it. `materializeNetwork` inserts.
    var knownAddressingKinds: Set<VmnetNetworkKind> = Set(VmnetNetworkKind.allCases)

    // MARK: - Error Injection

    var attachmentError: (any Error)?

    private(set) var requestedKinds: [VmnetNetworkKind] = []
    private(set) var materializeCount = 0
    /// Every `materializeNetwork` call, in order — failures included.
    private(set) var materializeRequestedKinds: [VmnetNetworkKind] = []
    private(set) var invalidatedKinds: [VmnetNetworkKind] = []
    /// Every `endRunIfHeld(for:)` call, in order.
    private(set) var endedRunKinds: [VmnetNetworkKind] = []

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
        knownAddressingKinds.insert(kind)
        return true
    }

    func invalidateNetwork(for kind: VmnetNetworkKind) {
        invalidatedKinds.append(kind)
        materializedKinds.remove(kind)
    }

    /// Mirrors the service: a run only ends where one was started, the network
    /// it ends is kept materialized, and a pending declaration outranks the
    /// run state as the reason to replace it.
    func endRunIfHeld(for kind: VmnetNetworkKind) {
        endedRunKinds.append(kind)
        guard materializedKinds.contains(kind), heldRunKinds.remove(kind) != nil,
            scriptedRecreationReasons[kind] == nil
        else { return }
        scriptedRecreationReasons[kind] = .runEnded
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

    func addressingIsKnown(for kind: VmnetNetworkKind) -> Bool {
        knownAddressingKinds.contains(kind)
    }

    // MARK: - Port forwarding

    /// The rules last declared per lowercased MAC, in declaration order.
    private(set) var declaredForwardingRules: [(mac: String, rules: [PortForwardingRule])] = []
    /// Scripted answer for `recreationReason(for:)`.
    var scriptedRecreationReasons: [VmnetNetworkKind: VmnetNetworkRecreationReason] = [:]

    func setPortForwardingRules(
        _ rules: [PortForwardingRule], for mac: String, kind: VmnetNetworkKind
    ) {
        declaredForwardingRules.append((mac: mac.lowercased(), rules: rules))
    }

    func recreationReason(for kind: VmnetNetworkKind) -> VmnetNetworkRecreationReason? {
        // Mirrors the service: no reason stands against a network that is not
        // materialized — its next materialization installs what is declared then.
        guard materializedKinds.contains(kind) else { return nil }
        return scriptedRecreationReasons[kind]
    }

    func kind(ofNetwork network: vmnet_network_ref) -> VmnetNetworkKind? {
        nil
    }
}
