import Foundation
import KernovaLogging
import Virtualization
import vmnet

/// The vmnet mode an app-managed network runs in.
enum VmnetNetworkKind: String, CaseIterable, Sendable {
    /// Host Only: guests reach the host and the other guests on their network,
    /// never the LAN or the internet.
    case hostOnly
    /// Shared Network: guests reach the internet through the host's connection
    /// (NAT44/NAT66, DHCP, DNS proxy), and the host reaches them at the
    /// addresses they hold on its subnet.
    case shared

    /// The kind backing `mode`, `nil` for a mode no app-managed network
    /// realizes (Bridged — external DHCP owns addressing there).
    init?(mode: VMNetworkMode) {
        switch mode {
        case .shared: self = .shared
        case .hostOnly: self = .hostOnly
        case .bridged: return nil
        }
    }
}

/// One app-managed vmnet network. Membership is what expresses guest↔guest
/// reachability (docs/NETWORKING.md): separate networks do not reach each
/// other (docs/research/2026-09-30-separate-vmnet-networks-isolate-their-guests.md).
struct VmnetNetworkID: Hashable, Sendable {
    let kind: VmnetNetworkKind
    /// The VM whose network of its own this is, `nil` for the one network
    /// every VM of `kind` without one of its own joins.
    let owner: UUID?
}

/// A network as one VM's session names it: the common network of `kind`, or
/// the VM's own.
struct VmnetNetworkSelection: Hashable, Sendable {
    let kind: VmnetNetworkKind
    let isOwn: Bool
}

/// The IPv4 block a network hands its guests, in host byte order.
struct IPv4Subnet: Equatable, Sendable {
    let network: UInt32
    let mask: UInt32

    /// The block any `address` inside it under `mask` belongs to.
    init(containing address: UInt32, mask: UInt32) {
        self.network = address & mask
        self.mask = mask
    }

    func contains(_ address: UInt32) -> Bool {
        address & mask == network
    }
}

/// Dotted-quad IPv4 presentation of host-byte-order values.
enum IPv4Value {
    static func string(_ value: UInt32) -> String {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var address = in_addr(s_addr: value.bigEndian)
        return buffer.withUnsafeMutableBufferPointer { buffer in
            guard let text = inet_ntop(AF_INET, &address, buffer.baseAddress, socklen_t(buffer.count))
            else { return "?" }
            return String(cString: text)
        }
    }
}

// A class, not a struct: Swift 6.4 at -Onone reads `dictionary[key]?.field`
// from a class's stored dictionary as `.some(garbage)` for a missing key when
// the value pairs a bare `OpaquePointer` with the field, and wrapping the
// pointer in a class reference compiles correctly
// (docs/research/2026-09-30-swift-6-4-onone-optional-chain-through-a-pointer-payload.md).
/// A materialized app-managed vmnet network.
final class VmnetNetworkHandle: @unchecked Sendable {
    /// Feed to `VZVmnetNetworkDeviceAttachment(network:)`. Safe to cross
    /// isolation domains: the ref is an immutable reservation handle.
    let network: vmnet_network_ref

    init(network: vmnet_network_ref) {
        self.network = network
    }
}

/// The vmnet calls `VmnetNetworkService` makes, and every use of the refs they
/// return, abstracted so tests run without `com.apple.vm.networking` — the real
/// call is an XPC round-trip to the NetworkSharing daemon that fails
/// unentitled.
protocol VmnetNetworkOperating: Sendable {
    /// Creates a network of `kind` on the subnet the system picks, returning
    /// the handle and that subnet.
    func createNetwork(_ kind: VmnetNetworkKind) throws -> (
        handle: VmnetNetworkHandle, subnet: IPv4Subnet
    )
    /// A VZ attachment joining `handle`'s network.
    func attachment(joining handle: VmnetNetworkHandle) -> VZNetworkDeviceAttachment
    /// Gives up the reference `createNetwork` returned. An attachment built
    /// over the network holds its own.
    func releaseNetwork(_ handle: VmnetNetworkHandle)
}

/// Releases a vmnet object Swift imports as a bare `OpaquePointer`. The vmnet
/// header documents these as `CFRelease()`-able; Swift refuses a direct
/// `CFRelease` on an unmanaged import, so route through `Unmanaged`.
func releaseVmnetRef(_ ref: OpaquePointer) {
    Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(ref)).release()
}

/// A vmnet call that failed.
struct VmnetOperationError: Error, LocalizedError {
    let operation: String
    let status: vmnet_return_t?

    var errorDescription: String? {
        if let status {
            "\(operation) failed (vmnet status \(status.rawValue))"
        } else {
            "\(operation) failed"
        }
    }
}

/// The real `VmnetNetworkOperating`, over the macOS 26 vmnet network APIs.
struct HostVmnetNetworkOperator: VmnetNetworkOperating {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "HostVmnetNetworkOperator")

    func createNetwork(_ kind: VmnetNetworkKind) throws -> (
        handle: VmnetNetworkHandle, subnet: IPv4Subnet
    ) {
        var status = vmnet_return_t.VMNET_SUCCESS
        guard let configuration = vmnet_network_configuration_create(mode(for: kind), &status) else {
            throw VmnetOperationError(operation: "vmnet_network_configuration_create", status: status)
        }
        defer { releaseVmnetRef(configuration) }
        guard let network = vmnet_network_create(configuration, &status) else {
            throw VmnetOperationError(operation: "vmnet_network_create", status: status)
        }

        var address = in_addr()
        var mask = in_addr()
        vmnet_network_get_ipv4_subnet(network, &address, &mask)
        let subnet = IPv4Subnet(
            containing: UInt32(bigEndian: address.s_addr), mask: UInt32(bigEndian: mask.s_addr))
        #log(
            Self.logger, .notice,
            "Created a \(kind.rawValue, privacy: .public) network on \(IPv4Value.string(subnet.network), privacy: .public) mask \(IPv4Value.string(subnet.mask), privacy: .public)"
        )
        return (VmnetNetworkHandle(network: network), subnet)
    }

    func attachment(joining handle: VmnetNetworkHandle) -> VZNetworkDeviceAttachment {
        VZVmnetNetworkDeviceAttachment(network: handle.network)
    }

    func releaseNetwork(_ handle: VmnetNetworkHandle) {
        releaseVmnetRef(handle.network)
    }

    private func mode(for kind: VmnetNetworkKind) -> operating_modes_t {
        switch kind {
        case .hostOnly: .VMNET_HOST_MODE
        case .shared: .VMNET_SHARED_MODE
        }
    }
}

/// App-managed vmnet networks, as the app at large reads them.
protocol VmnetNetworkProviding: Sendable {
    /// The view one session of the VM `owner` attaches through. The VM's own
    /// networks exist only while a view opened for it lives.
    func sessionNetworks(ownedBy owner: UUID) -> any VmnetSessionNetworking
    /// The IPv4 subnet `network` hands its guests, `nil` while it is not
    /// materialized. Cheap and non-blocking — safe from the main actor.
    func ipv4Subnet(for network: VmnetNetworkID) -> IPv4Subnet?
}

/// App-managed vmnet networks as one VM session's attachment construction and
/// attachment recovery consume them.
protocol VmnetSessionNetworking: Sendable {
    /// A VZ attachment joining `network`, materializing it first when it is
    /// not. Blocks for the vmnet XPC round-trip — never call on the main
    /// actor; config assembly runs off-main. Throws when the network cannot be
    /// materialized.
    func attachment(for network: VmnetNetworkSelection) throws -> VZNetworkDeviceAttachment
    /// The non-blocking variant for the main-actor live-attach path: an
    /// attachment when the network is already materialized, `nil` otherwise.
    func attachmentIfMaterialized(for network: VmnetNetworkSelection) -> VZNetworkDeviceAttachment?
    /// Materializes `network` off the caller's actor. `true` on success (or
    /// when already materialized); failures are logged here.
    func materializeNetwork(for network: VmnetNetworkSelection) async -> Bool
    /// The selection `network` is for this session, `nil` for a network it
    /// cannot attach to — one the service does not hold, or another VM's own.
    func selection(ofNetwork network: vmnet_network_ref) -> VmnetNetworkSelection?
}

/// Owns the app's managed vmnet networks: the common Host Only and Shared
/// networks, and each VM's networks of its own.
///
/// A common network is created on first use and held for the life of the
/// process: one whose last VM leaves goes idle rather than away, and the same
/// ref starts it again
/// (docs/research/2026-09-18-vmnet-dhcp-reservations-lapse-on-network-stop.md).
/// A VM's own network is created only through a ``VmnetSessionNetworks`` view
/// opened for that VM, and released when the last such view goes — so it is
/// held for the whole session (an in-guest reboot stops and restarts it,
/// docs/research/2026-09-22-vmnet-network-run-and-forwarding-rules.md) and
/// never outlives it.
///
/// Every network gets the subnet the system picks. A process holds a bounded
/// number of networks; a create past that fails like any other.
///
/// Lock-guarded `Sendable` rather than `@MainActor`: it never touches
/// `VZVirtualMachine`, and `ConfigurationBuilder` consumes it during off-main
/// config assembly while the live-switch path consumes it on the main actor.
final class VmnetNetworkService: @unchecked Sendable {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VmnetNetworkService")

    /// A materialized network: the handle callers attach to, and the subnet it
    /// hands its guests.
    private struct MaterializedNetwork {
        let handle: VmnetNetworkHandle
        let subnet: IPv4Subnet
    }

    private let operations: any VmnetNetworkOperating
    /// Guards `networks` and `openViews` — never held across a vmnet call, so
    /// the main-actor paths (`attachmentIfMaterialized`, `ipv4Subnet`) can
    /// never block behind a materialization in flight.
    private let stateLock = NSLock()
    /// Every materialized network, present exactly for the ones that exist.
    private var networks: [VmnetNetworkID: MaterializedNetwork] = [:]
    /// How many session views are open for each VM, present exactly for VMs
    /// with at least one.
    private var openViews: [UUID: Int] = [:]
    /// Serializes materialization, so concurrent callers produce one network.
    private let materializeLock = NSLock()

    init(operations: any VmnetNetworkOperating) {
        self.operations = operations
    }

    /// `id`'s network, materializing it on first use. Blocks for the vmnet XPC
    /// round-trip — never call on the main actor.
    ///
    /// File-private: an owned network is materialized only through a view
    /// opened for its owner, which keeps the owner's view count above zero for
    /// the whole call.
    fileprivate func network(for id: VmnetNetworkID) throws -> VmnetNetworkHandle {
        if let handle = cachedHandle(for: id) { return handle }
        materializeLock.lock()
        defer { materializeLock.unlock() }
        if let handle = cachedHandle(for: id) { return handle }
        let (handle, subnet) = try operations.createNetwork(id.kind)
        stateLock.withLock { networks[id] = MaterializedNetwork(handle: handle, subnet: subnet) }
        if let owner = id.owner {
            #log(
                Self.logger, .notice,
                "Created VM \(owner.uuidString, privacy: .public)'s own \(id.kind.rawValue, privacy: .public) network on \(IPv4Value.string(subnet.network), privacy: .public)"
            )
        }
        return handle
    }

    fileprivate func cachedHandle(for id: VmnetNetworkID) -> VmnetNetworkHandle? {
        stateLock.withLock { networks[id]?.handle }
    }

    fileprivate func attachment(joining handle: VmnetNetworkHandle) -> VZNetworkDeviceAttachment {
        operations.attachment(joining: handle)
    }

    fileprivate func id(ofNetwork network: vmnet_network_ref) -> VmnetNetworkID? {
        stateLock.withLock { networks.first(where: { $0.value.handle.network == network })?.key }
    }

    fileprivate func openView(for owner: UUID) {
        stateLock.withLock { openViews[owner, default: 0] += 1 }
    }

    /// Closes one of `owner`'s views, releasing its own networks with the last.
    fileprivate func closeView(for owner: UUID) {
        let released: [(VmnetNetworkID, VmnetNetworkHandle)] = stateLock.withLock {
            let remaining = (openViews[owner] ?? 0) - 1
            guard remaining <= 0 else {
                openViews[owner] = remaining
                return []
            }
            openViews[owner] = nil
            let owned = networks.filter { $0.key.owner == owner }
            for id in owned.keys { networks[id] = nil }
            return owned.map { ($0.key, $0.value.handle) }
        }
        for (id, handle) in released {
            operations.releaseNetwork(handle)
            #log(
                Self.logger, .notice,
                "Released VM \(owner.uuidString, privacy: .public)'s own \(id.kind.rawValue, privacy: .public) network"
            )
        }
    }
}

extension VmnetNetworkService: VmnetNetworkProviding {
    func sessionNetworks(ownedBy owner: UUID) -> any VmnetSessionNetworking {
        VmnetSessionNetworks(service: self, owner: owner)
    }

    func ipv4Subnet(for network: VmnetNetworkID) -> IPv4Subnet? {
        stateLock.withLock { networks[network]?.subnet }
    }
}

/// One VM session's view of the app-managed networks: the common ones, and
/// the VM's own, which exist only while a view of the VM's is open.
///
/// The session context holds it for the session's whole life, and anything
/// still materializing through it holds it until that finishes.
final class VmnetSessionNetworks: VmnetSessionNetworking {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VmnetSessionNetworks")

    private let service: VmnetNetworkService
    let owner: UUID

    fileprivate init(service: VmnetNetworkService, owner: UUID) {
        self.service = service
        self.owner = owner
        service.openView(for: owner)
    }

    deinit {
        service.closeView(for: owner)
    }

    private func id(_ selection: VmnetNetworkSelection) -> VmnetNetworkID {
        VmnetNetworkID(kind: selection.kind, owner: selection.isOwn ? owner : nil)
    }

    func attachment(for network: VmnetNetworkSelection) throws -> VZNetworkDeviceAttachment {
        service.attachment(joining: try service.network(for: id(network)))
    }

    func attachmentIfMaterialized(for network: VmnetNetworkSelection) -> VZNetworkDeviceAttachment? {
        service.cachedHandle(for: id(network)).map(service.attachment(joining:))
    }

    // A nonisolated async method runs off the caller's actor, so the blocking
    // vmnet round-trip inside `network(for:)` never lands on the main thread.
    func materializeNetwork(for network: VmnetNetworkSelection) async -> Bool {
        do {
            _ = try service.network(for: id(network))
            return true
        } catch {
            #log(
                Self.logger, .error,
                "Could not materialize the \(network.isOwn ? "own " : "", privacy: .public)\(network.kind.rawValue, privacy: .public) network: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    func selection(ofNetwork network: vmnet_network_ref) -> VmnetNetworkSelection? {
        guard let id = service.id(ofNetwork: network) else { return nil }
        guard let networkOwner = id.owner else {
            return VmnetNetworkSelection(kind: id.kind, isOwn: false)
        }
        return networkOwner == owner ? VmnetNetworkSelection(kind: id.kind, isOwn: true) : nil
    }
}
