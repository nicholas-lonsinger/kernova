import Foundation
import Virtualization
import os
import vmnet

/// An app-managed vmnet network, keyed by role. Each case is one logical
/// network the app owns; every VM whose mode maps to that role joins the same
/// network, so membership is what expresses guest↔guest reachability
/// (docs/NETWORKING.md).
// `CodingKeyRepresentable` so a `[VmnetNetworkKind: …]` store encodes as a
// JSON object keyed by kind, not Codable's array-of-pairs fallback.
enum VmnetNetworkKind: String, Codable, CodingKeyRepresentable, Sendable {
    /// The Host Only network: guests on it reach the host and each other,
    /// never the LAN or the internet.
    case hostOnly
}

/// The addressing an app-managed network keeps stable across launches:
/// dotted-quad IPv4 subnet and mask, plus the IPv6 prefix and its bit length.
struct VmnetNetworkAddressing: Codable, Sendable, Equatable {
    var ipv4Subnet: String
    var ipv4Mask: String
    var ipv6Prefix: String
    var ipv6PrefixLength: UInt8
}

/// A materialized app-managed vmnet network.
///
/// The wrapped ref stays alive as long as the service caches the handle — the
/// subnet reservation lives exactly as long as the ref (vmnet.h), and a
/// network must outlive any single VM session so concurrent VMs can share it.
/// Only `invalidateNetwork(for:)` releases one.
struct VmnetNetworkHandle: @unchecked Sendable {
    /// Feed to `VZVmnetNetworkDeviceAttachment(network:)`. Safe to cross
    /// isolation domains: the ref is an immutable reservation handle.
    let network: vmnet_network_ref
}

/// The vmnet calls `VmnetNetworkService` makes, abstracted so tests run
/// without `com.apple.vm.networking` — the real call is an XPC round-trip to
/// the NetworkSharing daemon that fails unentitled.
protocol VmnetNetworkOperating: Sendable {
    /// Creates a network of `kind` — reserving `addressing` when given, the
    /// system's choice when `nil` — and returns the handle plus the addressing
    /// the network actually reserved.
    func createNetwork(_ kind: VmnetNetworkKind, addressing: VmnetNetworkAddressing?) throws
        -> (handle: VmnetNetworkHandle, addressing: VmnetNetworkAddressing)
    /// Releases `handle`'s network ref, ending its subnet reservation.
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
///
/// RATIONALE (2026-08-13): `vmnet_network_copy_serialization` /
/// `vmnet_network_create_with_serialization` look like the intended
/// persistence path, but a rebuilt network is defective: VZ accepts an
/// attachment to it and then disconnects within milliseconds ("Internal
/// Network Error"), every time, while a freshly created network attaches
/// cleanly — observed on macOS 27 beta (Darwin 27.0), with the serialization
/// round-trip verified lossless via `xpc_equal`. Creating fresh with the
/// persisted addressing pinned delivers the same relaunch stability on the
/// path that works.
struct HostVmnetNetworkOperator: VmnetNetworkOperating {
    private static let logger = Logger(subsystem: "app.kernova", category: "HostVmnetNetworkOperator")

    func createNetwork(_ kind: VmnetNetworkKind, addressing: VmnetNetworkAddressing?) throws
        -> (handle: VmnetNetworkHandle, addressing: VmnetNetworkAddressing)
    {
        var status = vmnet_return_t.VMNET_SUCCESS
        guard let configuration = vmnet_network_configuration_create(mode(for: kind), &status) else {
            throw VmnetOperationError(operation: "vmnet_network_configuration_create", status: status)
        }
        defer { releaseVmnetRef(configuration) }
        if let addressing {
            try pin(addressing, onto: configuration)
        }
        guard let network = vmnet_network_create(configuration, &status) else {
            throw VmnetOperationError(operation: "vmnet_network_create", status: status)
        }

        let reserved = Self.reservedAddressing(of: network)
        Self.logger.notice(
            "Created \(kind.rawValue, privacy: .public) network (\(addressing == nil ? "fresh" : "pinned", privacy: .public)): \(reserved.ipv4Subnet, privacy: .public) mask \(reserved.ipv4Mask, privacy: .public), \(reserved.ipv6Prefix, privacy: .public)/\(reserved.ipv6PrefixLength, privacy: .public)"
        )
        return (VmnetNetworkHandle(network: network), reserved)
    }

    func releaseNetwork(_ handle: VmnetNetworkHandle) {
        releaseVmnetRef(handle.network)
    }

    private func mode(for kind: VmnetNetworkKind) -> operating_modes_t {
        switch kind {
        case .hostOnly: .VMNET_HOST_MODE
        }
    }

    private func pin(
        _ addressing: VmnetNetworkAddressing, onto configuration: vmnet_network_configuration_ref
    ) throws {
        var subnet = in_addr()
        var mask = in_addr()
        guard
            addressing.ipv4Subnet.withCString({ inet_pton(AF_INET, $0, &subnet) }) == 1,
            addressing.ipv4Mask.withCString({ inet_pton(AF_INET, $0, &mask) }) == 1
        else {
            throw VmnetOperationError(operation: "parsing stored IPv4 addressing", status: nil)
        }
        let ipv4Status = vmnet_network_configuration_set_ipv4_subnet(configuration, &subnet, &mask)
        guard ipv4Status == .VMNET_SUCCESS else {
            throw VmnetOperationError(
                operation: "vmnet_network_configuration_set_ipv4_subnet", status: ipv4Status)
        }

        var prefix = in6_addr()
        guard addressing.ipv6Prefix.withCString({ inet_pton(AF_INET6, $0, &prefix) }) == 1 else {
            throw VmnetOperationError(operation: "parsing stored IPv6 prefix", status: nil)
        }
        let ipv6Status = vmnet_network_configuration_set_ipv6_prefix(
            configuration, &prefix, addressing.ipv6PrefixLength)
        guard ipv6Status == .VMNET_SUCCESS else {
            throw VmnetOperationError(
                operation: "vmnet_network_configuration_set_ipv6_prefix", status: ipv6Status)
        }
    }

    private static func reservedAddressing(of network: vmnet_network_ref) -> VmnetNetworkAddressing {
        var subnet = in_addr()
        var mask = in_addr()
        vmnet_network_get_ipv4_subnet(network, &subnet, &mask)
        var prefix = in6_addr()
        var prefixLength: UInt8 = 0
        vmnet_network_get_ipv6_prefix(network, &prefix, &prefixLength)
        return VmnetNetworkAddressing(
            ipv4Subnet: ipv4String(subnet),
            ipv4Mask: ipv4String(mask),
            ipv6Prefix: ipv6String(prefix),
            ipv6PrefixLength: prefixLength)
    }

    private static func ipv4String(_ address: in_addr) -> String {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return "?"
        }
        return String(cString: buffer)
    }

    private static func ipv6String(_ address: in6_addr) -> String {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
            return "?"
        }
        return String(cString: buffer)
    }
}

/// App-managed vmnet networks, as attachment construction and attachment
/// recovery consume them.
protocol VmnetNetworkProviding: Sendable {
    /// A VZ attachment joining the app-managed network of `kind`, materializing
    /// the network first if this launch hasn't yet. Blocks for the vmnet XPC
    /// round-trip — never call on the main actor; config assembly runs
    /// off-main. Throws when the network cannot be materialized.
    func attachment(for kind: VmnetNetworkKind) throws -> VZNetworkDeviceAttachment
    /// The non-blocking variant for the main-actor live-attach path: an
    /// attachment when the network is already materialized, `nil` otherwise.
    func attachmentIfMaterialized(for kind: VmnetNetworkKind) -> VZNetworkDeviceAttachment?
    /// Materializes the network of `kind` off the caller's actor. `true` on
    /// success (or when already materialized); failures are logged here.
    func materializeNetwork(for kind: VmnetNetworkKind) async -> Bool
    /// Drops (and releases) the materialized network of `kind`, so the next
    /// materialization creates it anew — pinned to the persisted addressing,
    /// so recovery cannot drift the subnet.
    func invalidateNetwork(for kind: VmnetNetworkKind)
}

/// Owns the app's managed vmnet networks — today the Host Only network; the
/// networks behind DHCP reservations and port forwarding extend this.
///
/// vmnet networks do not survive the process, so each network's addressing is
/// persisted to `Application Support/Kernova/networks.json` and pinned onto
/// the recreated network in later launches, keeping guest addressing stable.
/// Materialization is lazy — a launch that never uses a kind never creates it —
/// and a materialized network is held until the app exits: the subnet
/// reservation lives as long as the ref, and every concurrent VM in the mode
/// shares the one network.
///
/// Lock-guarded `Sendable` rather than `@MainActor`: it never touches
/// `VZVirtualMachine`, and `ConfigurationBuilder` consumes it during off-main
/// config assembly while the live-switch path consumes it on the main actor.
final class VmnetNetworkService: @unchecked Sendable {
    private static let logger = Logger(subsystem: "app.kernova", category: "VmnetNetworkService")

    /// The process-wide instance over the real vmnet calls and store location.
    static let shared = VmnetNetworkService()

    private let operations: any VmnetNetworkOperating
    private let storeURL: URL?
    /// Guards `handles` only — never held across a vmnet call or file I/O, so
    /// the main-actor `attachmentIfMaterialized` path can never block behind a
    /// materialization in flight.
    private let stateLock = NSLock()
    private var handles: [VmnetNetworkKind: VmnetNetworkHandle] = [:]
    /// Serializes materialization, so concurrent callers produce one network.
    private let materializeLock = NSLock()

    /// `storeURL: nil` disables persistence — networks still materialize, with
    /// addressing stable only within the session.
    init(
        operations: any VmnetNetworkOperating = HostVmnetNetworkOperator(),
        storeURL: URL? = VmnetNetworkService.defaultStoreURL()
    ) {
        self.operations = operations
        self.storeURL = storeURL
    }

    /// `networks.json` beside the `VMs/` directory.
    static func defaultStoreURL() -> URL? {
        try? VMStorageService.supportDirectory
            .appendingPathComponent("networks.json", isDirectory: false)
    }

    /// The app-managed network of `kind`, materializing it on first use.
    /// Blocks for the vmnet XPC round-trip — never call on the main actor.
    func network(for kind: VmnetNetworkKind) throws -> VmnetNetworkHandle {
        if let handle = cachedHandle(for: kind) { return handle }
        materializeLock.lock()
        defer { materializeLock.unlock() }
        if let handle = cachedHandle(for: kind) { return handle }
        let handle = try materialize(kind)
        stateLock.lock()
        handles[kind] = handle
        stateLock.unlock()
        return handle
    }

    private func cachedHandle(for kind: VmnetNetworkKind) -> VmnetNetworkHandle? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return handles[kind]
    }

    private func materialize(_ kind: VmnetNetworkKind) throws -> VmnetNetworkHandle {
        var store = loadStore()
        if let stored = store[kind] {
            do {
                let (handle, reserved) = try operations.createNetwork(kind, addressing: stored)
                if reserved == stored {
                    Self.logger.info(
                        "Recreated the \(kind.rawValue, privacy: .public) network with its stored addressing"
                    )
                } else {
                    // vmnet accepted the pin but reserved something else; the
                    // store must follow what the network actually is, or every
                    // later launch re-pins a value no network carries.
                    store[kind] = reserved
                    try? persist(store)
                    Self.logger.warning(
                        "Pinned \(kind.rawValue, privacy: .public) network addressing was adjusted by the system — persisting the reserved values"
                    )
                }
                return handle
            } catch {
                Self.logger.warning(
                    "Stored \(kind.rawValue, privacy: .public) network addressing is no longer reservable — creating fresh, guest addressing may change: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        let (handle, addressing) = try operations.createNetwork(kind, addressing: nil)
        store[kind] = addressing
        do {
            try persist(store)
            Self.logger.notice("Created and persisted the \(kind.rawValue, privacy: .public) network")
        } catch {
            // Non-fatal: the network works for this session; only relaunch
            // addressing stability is lost.
            Self.logger.warning(
                "Created the \(kind.rawValue, privacy: .public) network but could not persist it — addressing may change at next launch: \(error.localizedDescription, privacy: .public)"
            )
        }
        return handle
    }

    // MARK: - Store

    private func loadStore() -> [VmnetNetworkKind: VmnetNetworkAddressing] {
        guard let storeURL, let data = try? Data(contentsOf: storeURL) else { return [:] }
        do {
            return try VMConfiguration.makeJSONDecoder()
                .decode([VmnetNetworkKind: VmnetNetworkAddressing].self, from: data)
        } catch {
            Self.logger.warning(
                "networks.json is unreadable — treating as empty: \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }

    private func persist(_ store: [VmnetNetworkKind: VmnetNetworkAddressing]) throws {
        guard let storeURL else { return }
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try VMConfiguration.makeJSONEncoder().encode(store).write(to: storeURL, options: .atomic)
    }
}

extension VmnetNetworkService: VmnetNetworkProviding {
    func attachment(for kind: VmnetNetworkKind) throws -> VZNetworkDeviceAttachment {
        VZVmnetNetworkDeviceAttachment(network: try network(for: kind).network)
    }

    func attachmentIfMaterialized(for kind: VmnetNetworkKind) -> VZNetworkDeviceAttachment? {
        guard let handle = cachedHandle(for: kind) else { return nil }
        return VZVmnetNetworkDeviceAttachment(network: handle.network)
    }

    // A nonisolated async method runs off the caller's actor, so the blocking
    // vmnet round-trip inside `network(for:)` never lands on the main thread.
    func materializeNetwork(for kind: VmnetNetworkKind) async -> Bool {
        do {
            _ = try network(for: kind)
            return true
        } catch {
            Self.logger.error(
                "Could not materialize the \(kind.rawValue, privacy: .public) network: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    func invalidateNetwork(for kind: VmnetNetworkKind) {
        stateLock.lock()
        let dropped = handles.removeValue(forKey: kind)
        stateLock.unlock()
        guard let dropped else { return }
        // Releasing the ref ends its subnet reservation; without this, the
        // dropped network would keep the subnet and the pinned recreate of the
        // same addressing would be refused as a conflict. The only caller is
        // ladder exhaustion, where VZ has already torn down every attachment
        // to the network.
        operations.releaseNetwork(dropped)
        Self.logger.notice("Invalidated the \(kind.rawValue, privacy: .public) network")
    }
}
