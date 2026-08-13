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
    /// The Shared Network network: guests reach the internet through the
    /// host's connection (NAT44/NAT66, DHCP, DNS proxy), and the host reaches
    /// them at their reserved addresses.
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

/// The addressing an app-managed network keeps stable across launches:
/// dotted-quad IPv4 subnet and mask, plus the IPv6 prefix and its bit length.
struct VmnetNetworkAddressing: Codable, Sendable, Equatable {
    var ipv4Subnet: String
    var ipv4Mask: String
    var ipv6Prefix: String
    var ipv6PrefixLength: UInt8

    /// The IPv4 address reservation slot `index` maps to: host `2 + index`
    /// within the subnet (the gateway holds host 1), `nil` once the slot
    /// index runs past the subnet's last usable address or when the stored
    /// strings do not parse.
    func reservedAddress(slot index: Int) -> String? {
        guard let subnet = IPv4Value.parse(ipv4Subnet), let mask = IPv4Value.parse(ipv4Mask)
        else { return nil }
        let network = subnet & mask
        let broadcast = network | ~mask
        let host = network &+ UInt32(2 + index)
        guard host < broadcast else { return nil }
        return IPv4Value.string(host)
    }
}

/// Dotted-quad IPv4 conversions over host-byte-order values.
enum IPv4Value {
    static func parse(_ dottedQuad: String) -> UInt32? {
        var address = in_addr()
        guard dottedQuad.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    static func string(_ value: UInt32) -> String {
        var address = in_addr(s_addr: value.bigEndian)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return "?"
        }
        return String(cString: buffer)
    }
}

/// What one app-managed network persists across launches: its addressing once
/// first reserved, and the ordered MACs holding DHCP reservation slots —
/// slot order is the address assignment, so the list only ever appends.
struct VmnetNetworkRecord: Codable, Sendable, Equatable {
    /// `nil` until the network first materializes.
    var addressing: VmnetNetworkAddressing?
    var reservedMACs: [String]
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
    /// system's choice when `nil` — installing the given MAC → IPv4 DHCP
    /// reservations, and returns the handle plus the addressing the network
    /// actually reserved. Reservations are fixed for the life of the network.
    func createNetwork(
        _ kind: VmnetNetworkKind,
        addressing: VmnetNetworkAddressing?,
        reservations: [(mac: String, address: String)]
    ) throws -> (handle: VmnetNetworkHandle, addressing: VmnetNetworkAddressing)
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
struct HostVmnetNetworkOperator: VmnetNetworkOperating {
    private static let logger = Logger(subsystem: "app.kernova", category: "HostVmnetNetworkOperator")

    func createNetwork(
        _ kind: VmnetNetworkKind,
        addressing: VmnetNetworkAddressing?,
        reservations: [(mac: String, address: String)]
    ) throws -> (handle: VmnetNetworkHandle, addressing: VmnetNetworkAddressing) {
        var status = vmnet_return_t.VMNET_SUCCESS
        guard let configuration = vmnet_network_configuration_create(mode(for: kind), &status) else {
            throw VmnetOperationError(operation: "vmnet_network_configuration_create", status: status)
        }
        defer { releaseVmnetRef(configuration) }
        if let addressing {
            try pin(addressing, onto: configuration)
        }
        try install(reservations, onto: configuration)
        guard let network = vmnet_network_create(configuration, &status) else {
            throw VmnetOperationError(operation: "vmnet_network_create", status: status)
        }

        let reserved = Self.reservedAddressing(of: network)
        Self.logger.notice(
            "Created \(kind.rawValue, privacy: .public) network (\(addressing == nil ? "fresh" : "pinned", privacy: .public), \(reservations.count, privacy: .public) reservations): \(reserved.ipv4Subnet, privacy: .public) mask \(reserved.ipv4Mask, privacy: .public), \(reserved.ipv6Prefix, privacy: .public)/\(reserved.ipv6PrefixLength, privacy: .public)"
        )
        return (VmnetNetworkHandle(network: network), reserved)
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

    private func install(
        _ reservations: [(mac: String, address: String)],
        onto configuration: vmnet_network_configuration_ref
    ) throws {
        for entry in reservations {
            let octets = entry.mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
            var address = in_addr()
            guard octets.count == 6,
                entry.address.withCString({ inet_pton(AF_INET, $0, &address) }) == 1
            else {
                throw VmnetOperationError(operation: "parsing DHCP reservation", status: nil)
            }
            var mac = ether_addr_t(
                octet: (octets[0], octets[1], octets[2], octets[3], octets[4], octets[5]))
            let status = vmnet_network_configuration_add_dhcp_reservation(
                configuration, &mac, &address)
            guard status == .VMNET_SUCCESS else {
                throw VmnetOperationError(
                    operation: "vmnet_network_configuration_add_dhcp_reservation", status: status)
            }
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
    /// Ensures `mac` holds a DHCP reservation slot on the network of `kind`.
    /// Cheap and non-blocking — safe from the main actor; the reservation is
    /// installed at the network's next materialization.
    func reserveAddressIfNeeded(for mac: String, kind: VmnetNetworkKind)
    /// The IPv4 address reserved for `mac` on the network of `kind`; `nil`
    /// while `mac` holds no slot or the network has never materialized (its
    /// addressing is not yet known).
    func reservedAddress(for mac: String, kind: VmnetNetworkKind) -> String?
    /// The kind whose materialized network `network` is, `nil` for a network
    /// this service does not hold.
    func kind(ofNetwork network: vmnet_network_ref) -> VmnetNetworkKind?
}

/// Owns the app's managed vmnet networks — the Host Only network and the
/// Shared Network network — and the per-VM DHCP reservations riding them.
///
/// vmnet networks do not survive the process, so each network's record —
/// addressing plus reservation slots — is persisted to
/// `Application Support/Kernova/networks.json`, and the addressing is pinned
/// onto the recreated network in later launches, keeping guest addressing
/// stable. Materialization is lazy — a launch that never uses a kind never
/// creates it — and a materialized network is held until the app exits: the
/// subnet reservation lives as long as the ref, and every concurrent VM in
/// the mode shares the one network.
///
/// Reservations are fixed at network creation (vmnet.h: modifying them is not
/// allowed while a network is active), so a slot assigned while its network
/// is materialized takes effect at the next materialization — the next app
/// launch, or a recovery-driven recreate.
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
    /// Guards `handles` and `records` only — never held across a vmnet call
    /// or file I/O, so the main-actor paths (`attachmentIfMaterialized`,
    /// `reserveAddressIfNeeded`, `reservedAddress`) can never block behind a
    /// materialization in flight.
    private let stateLock = NSLock()
    private var handles: [VmnetNetworkKind: VmnetNetworkHandle] = [:]
    private var records: [VmnetNetworkKind: VmnetNetworkRecord]
    /// Serializes materialization, so concurrent callers produce one network.
    private let materializeLock = NSLock()
    /// Store writes happen here, off whatever thread mutated the records.
    private let persistQueue = DispatchQueue(label: "app.kernova.vmnet-store", qos: .utility)

    /// `storeURL: nil` disables persistence — networks still materialize, with
    /// addressing and reservations stable only within the session.
    init(
        operations: any VmnetNetworkOperating = HostVmnetNetworkOperator(),
        storeURL: URL? = VmnetNetworkService.defaultStoreURL()
    ) {
        self.operations = operations
        self.storeURL = storeURL
        self.records = Self.loadRecords(from: storeURL)
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
        let record = currentRecord(for: kind)
        if let stored = record.addressing {
            do {
                let (handle, reserved) = try operations.createNetwork(
                    kind, addressing: stored,
                    reservations: reservations(for: record.reservedMACs, addressing: stored, kind: kind))
                if reserved == stored {
                    Self.logger.info(
                        "Recreated the \(kind.rawValue, privacy: .public) network with its stored addressing"
                    )
                } else {
                    // vmnet accepted the pin but reserved something else; the
                    // store must follow what the network actually is, or every
                    // later launch re-pins a value no network carries. The
                    // installed reservations were derived from the old
                    // addressing — the next materialization re-derives them.
                    updateRecord(for: kind) { $0.addressing = reserved }
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
        return try materializeFresh(kind)
    }

    /// First-ever (or fallback) materialization: the reservation slots' IPs
    /// depend on the subnet, which is only known once a network exists — so
    /// create fresh to discover the addressing, then release and recreate
    /// pinned to it with the reservations installed.
    private func materializeFresh(_ kind: VmnetNetworkKind) throws -> VmnetNetworkHandle {
        let (probe, discovered) = try operations.createNetwork(
            kind, addressing: nil, reservations: [])
        let macs = currentRecord(for: kind).reservedMACs
        guard !macs.isEmpty else {
            updateRecord(for: kind) { $0.addressing = discovered }
            Self.logger.notice("Created and persisted the \(kind.rawValue, privacy: .public) network")
            return probe
        }

        operations.releaseNetwork(probe)
        do {
            let (handle, reserved) = try operations.createNetwork(
                kind, addressing: discovered,
                reservations: reservations(for: macs, addressing: discovered, kind: kind))
            updateRecord(for: kind) { $0.addressing = reserved }
            Self.logger.notice(
                "Created and persisted the \(kind.rawValue, privacy: .public) network with \(macs.count, privacy: .public) reservation slots"
            )
            return handle
        } catch {
            // The discovered subnet was re-grabbed between release and
            // recreate. Fall back to a working network without reservations —
            // the mode beats the IP display — and let the next
            // materialization install them.
            Self.logger.warning(
                "Recreating the \(kind.rawValue, privacy: .public) network with reservations failed — falling back to a fresh network without them: \(error.localizedDescription, privacy: .public)"
            )
            let (handle, addressing) = try operations.createNetwork(
                kind, addressing: nil, reservations: [])
            updateRecord(for: kind) { $0.addressing = addressing }
            return handle
        }
    }

    /// The MAC → IPv4 pairs to install for `macs` on a network of
    /// `addressing`, in slot order; slots past the subnet's capacity are
    /// dropped with a warning.
    private func reservations(
        for macs: [String], addressing: VmnetNetworkAddressing, kind: VmnetNetworkKind
    ) -> [(mac: String, address: String)] {
        macs.enumerated().compactMap { index, mac in
            guard let address = addressing.reservedAddress(slot: index) else {
                Self.logger.warning(
                    "No address left in the \(kind.rawValue, privacy: .public) subnet for reservation slot \(index, privacy: .public)"
                )
                return nil
            }
            return (mac: mac, address: address)
        }
    }

    // MARK: - Records

    private func currentRecord(for kind: VmnetNetworkKind) -> VmnetNetworkRecord {
        stateLock.lock()
        defer { stateLock.unlock() }
        return records[kind] ?? VmnetNetworkRecord(addressing: nil, reservedMACs: [])
    }

    /// Mutates `kind`'s record under the state lock and schedules a persist.
    private func updateRecord(for kind: VmnetNetworkKind, _ mutate: (inout VmnetNetworkRecord) -> Void) {
        stateLock.lock()
        var record = records[kind] ?? VmnetNetworkRecord(addressing: nil, reservedMACs: [])
        mutate(&record)
        records[kind] = record
        let snapshot = records
        stateLock.unlock()
        persistAsync(snapshot)
    }

    // MARK: - Store

    private static func loadRecords(from storeURL: URL?) -> [VmnetNetworkKind: VmnetNetworkRecord] {
        guard let storeURL, let data = try? Data(contentsOf: storeURL) else { return [:] }
        do {
            return try VMConfiguration.makeJSONDecoder()
                .decode([VmnetNetworkKind: VmnetNetworkRecord].self, from: data)
        } catch {
            logger.warning(
                "networks.json is unreadable — treating as empty: \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }

    private func persistAsync(_ snapshot: [VmnetNetworkKind: VmnetNetworkRecord]) {
        guard let storeURL else { return }
        persistQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try VMConfiguration.makeJSONEncoder().encode(snapshot)
                    .write(to: storeURL, options: .atomic)
            } catch {
                // Non-fatal: networks work for this session; only relaunch
                // stability of addressing and reservations is lost.
                Self.logger.warning(
                    "Could not persist networks.json — addressing may change at next launch: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    #if DEBUG
    /// Blocks until every scheduled store write has landed, for tests.
    func flushPersistsForTesting() {
        persistQueue.sync {}
    }
    #endif
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

    func reserveAddressIfNeeded(for mac: String, kind: VmnetNetworkKind) {
        let normalized = mac.lowercased()
        stateLock.lock()
        var record = records[kind] ?? VmnetNetworkRecord(addressing: nil, reservedMACs: [])
        guard !record.reservedMACs.contains(normalized) else {
            stateLock.unlock()
            return
        }
        record.reservedMACs.append(normalized)
        records[kind] = record
        let snapshot = records
        stateLock.unlock()
        persistAsync(snapshot)
        Self.logger.info(
            "Reserved \(kind.rawValue, privacy: .public) address slot \(record.reservedMACs.count - 1, privacy: .public)"
        )
    }

    func reservedAddress(for mac: String, kind: VmnetNetworkKind) -> String? {
        let normalized = mac.lowercased()
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let record = records[kind], let addressing = record.addressing,
            let slot = record.reservedMACs.firstIndex(of: normalized)
        else { return nil }
        return addressing.reservedAddress(slot: slot)
    }

    func kind(ofNetwork network: vmnet_network_ref) -> VmnetNetworkKind? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return handles.first(where: { $0.value.network == network })?.key
    }
}
