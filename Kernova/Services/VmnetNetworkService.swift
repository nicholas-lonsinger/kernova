import Foundation
import KernovaKit
import KernovaLogging
import Virtualization
import vmnet

/// An app-managed vmnet network, keyed by role. Each case is one logical
/// network the app owns; every VM whose mode maps to that role joins the same
/// network, so membership is what expresses guest↔guest reachability
/// (docs/NETWORKING.md).
enum VmnetNetworkKind: String, CaseIterable, Sendable {
    /// The Host Only network: guests on it reach the host and each other,
    /// never the LAN or the internet.
    case hostOnly
    /// The Shared Network network: guests reach the internet through the
    /// host's connection (NAT44/NAT66, DHCP, DNS proxy), and the host reaches
    /// them at the addresses they hold on its subnet.
    case shared

    /// The network backing `mode`, `nil` for a mode no app-managed network
    /// realizes (Bridged — external DHCP owns addressing there).
    init?(mode: VMNetworkMode) {
        switch mode {
        case .shared: self = .shared
        case .hostOnly: self = .hostOnly
        case .bridged: return nil
        }
    }
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

/// A materialized app-managed vmnet network.
struct VmnetNetworkHandle: @unchecked Sendable {
    /// Feed to `VZVmnetNetworkDeviceAttachment(network:)`. Safe to cross
    /// isolation domains: the ref is an immutable reservation handle.
    let network: vmnet_network_ref
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
            "Created the \(kind.rawValue, privacy: .public) network on \(IPv4Value.string(subnet.network), privacy: .public) mask \(IPv4Value.string(subnet.mask), privacy: .public)"
        )
        return (VmnetNetworkHandle(network: network), subnet)
    }

    func attachment(joining handle: VmnetNetworkHandle) -> VZNetworkDeviceAttachment {
        VZVmnetNetworkDeviceAttachment(network: handle.network)
    }

    private func mode(for kind: VmnetNetworkKind) -> operating_modes_t {
        switch kind {
        case .hostOnly: .VMNET_HOST_MODE
        case .shared: .VMNET_SHARED_MODE
        }
    }
}

/// App-managed vmnet networks, as attachment construction, attachment recovery
/// and the guest-address observer consume them.
protocol VmnetNetworkProviding: Sendable {
    /// A VZ attachment joining the app-managed network of `kind`, materializing
    /// the network first when none is materialized. Blocks for the vmnet XPC
    /// round-trip — never call on the main actor; config assembly runs
    /// off-main. Throws when the network cannot be materialized.
    func attachment(for kind: VmnetNetworkKind) throws -> VZNetworkDeviceAttachment
    /// The non-blocking variant for the main-actor live-attach path: an
    /// attachment when the network is already materialized, `nil` otherwise.
    func attachmentIfMaterialized(for kind: VmnetNetworkKind) -> VZNetworkDeviceAttachment?
    /// Materializes the network of `kind` off the caller's actor. `true` on
    /// success (or when already materialized); failures are logged here.
    func materializeNetwork(for kind: VmnetNetworkKind) async -> Bool
    /// The kind whose materialized network `network` is, `nil` for a network
    /// this service does not hold.
    func kind(ofNetwork network: vmnet_network_ref) -> VmnetNetworkKind?
    /// The IPv4 subnet the materialized network of `kind` hands its guests,
    /// `nil` while none is materialized. Cheap and non-blocking — safe from the
    /// main actor.
    func ipv4Subnet(for kind: VmnetNetworkKind) -> IPv4Subnet?
}

/// Owns the app's managed vmnet networks — the Host Only network and the
/// Shared Network network.
///
/// Each is created on first use, on the subnet the system picks, and held for
/// the life of the process: a network whose last VM leaves goes idle rather
/// than away, and the same ref starts it again
/// (docs/research/2026-09-18-vmnet-dhcp-reservations-lapse-on-network-stop.md).
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
    /// Guards `networks` — never held across a vmnet call, so the main-actor
    /// paths (`attachmentIfMaterialized`, `ipv4Subnet`) can never block behind
    /// a materialization in flight.
    private let stateLock = NSLock()
    /// The materialized network of each kind, present exactly for the kinds one
    /// exists for.
    private var networks: [VmnetNetworkKind: MaterializedNetwork] = [:]
    /// Serializes materialization, so concurrent callers produce one network.
    private let materializeLock = NSLock()

    init(operations: any VmnetNetworkOperating) {
        self.operations = operations
    }

    /// The app-managed network of `kind`, materializing it on first use.
    /// Blocks for the vmnet XPC round-trip — never call on the main actor.
    func network(for kind: VmnetNetworkKind) throws -> VmnetNetworkHandle {
        if let handle = cachedHandle(for: kind) { return handle }
        materializeLock.lock()
        defer { materializeLock.unlock() }
        if let handle = cachedHandle(for: kind) { return handle }
        let (handle, subnet) = try operations.createNetwork(kind)
        stateLock.withLock { networks[kind] = MaterializedNetwork(handle: handle, subnet: subnet) }
        return handle
    }

    private func cachedHandle(for kind: VmnetNetworkKind) -> VmnetNetworkHandle? {
        stateLock.withLock { networks[kind]?.handle }
    }
}

extension VmnetNetworkService: VmnetNetworkProviding {
    func attachment(for kind: VmnetNetworkKind) throws -> VZNetworkDeviceAttachment {
        operations.attachment(joining: try network(for: kind))
    }

    func attachmentIfMaterialized(for kind: VmnetNetworkKind) -> VZNetworkDeviceAttachment? {
        cachedHandle(for: kind).map(operations.attachment(joining:))
    }

    // A nonisolated async method runs off the caller's actor, so the blocking
    // vmnet round-trip inside `network(for:)` never lands on the main thread.
    func materializeNetwork(for kind: VmnetNetworkKind) async -> Bool {
        do {
            _ = try network(for: kind)
            return true
        } catch {
            #log(
                Self.logger, .error,
                "Could not materialize the \(kind.rawValue, privacy: .public) network: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    func kind(ofNetwork network: vmnet_network_ref) -> VmnetNetworkKind? {
        stateLock.withLock { networks.first(where: { $0.value.handle.network == network })?.key }
    }

    func ipv4Subnet(for kind: VmnetNetworkKind) -> IPv4Subnet? {
        stateLock.withLock { networks[kind]?.subnet }
    }
}
