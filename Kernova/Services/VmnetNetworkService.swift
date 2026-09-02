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
enum VmnetNetworkKind: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable {
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
        withUnsafeBytes(of: in_addr(s_addr: value.bigEndian)) {
            presentationString($0, family: AF_INET, capacity: INET_ADDRSTRLEN)
        }
    }
}

/// The dotted-quad or colon-hex form of the socket address whose bytes are
/// `address`, `"?"` when `inet_ntop` fails. `capacity` is the family's
/// `INET*_ADDRSTRLEN`.
private func presentationString(
    _ address: UnsafeRawBufferPointer, family: Int32, capacity: Int32
) -> String {
    var buffer = [CChar](repeating: 0, count: Int(capacity))
    return buffer.withUnsafeMutableBufferPointer { buffer in
        guard
            let text = inet_ntop(
                family, address.baseAddress, buffer.baseAddress, socklen_t(buffer.count))
        else { return "?" }
        return String(cString: text)
    }
}

/// What one app-managed network persists across launches: its addressing once
/// first reserved, and the ordered MACs holding DHCP reservation slots.
///
/// Slot position *is* the address (``VmnetNetworkAddressing/reservedAddress(slot:)``),
/// so a slot is released by emptying it in place — a `nil` element is a free
/// slot the next MAC needing one refills, leaving every surviving VM's address
/// where it was. Trailing free slots are trimmed.
struct VmnetNetworkRecord: Codable, Sendable, Equatable {
    /// `nil` until the network first materializes.
    var addressing: VmnetNetworkAddressing?
    var reservedMACs: [String?]

    init(addressing: VmnetNetworkAddressing? = nil, reservedMACs: [String?] = []) {
        self.addressing = addressing
        self.reservedMACs = reservedMACs
    }
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

/// One DHCP reservation: the MAC holding a slot and the IPv4 address that
/// slot's position maps to.
struct VmnetReservation: Equatable, Sendable {
    let mac: String
    let address: String
}

/// The vmnet calls `VmnetNetworkService` makes, abstracted so tests run
/// without `com.apple.vm.networking` — the real call is an XPC round-trip to
/// the NetworkSharing daemon that fails unentitled.
protocol VmnetNetworkOperating: Sendable {
    /// Creates a network of `kind` — reserving `addressing` when given, the
    /// system's choice when `nil` — installing the given MAC → IPv4 DHCP
    /// reservations and port-forwarding rules, and returns the handle plus the
    /// addressing the network actually reserved. Both are fixed for the life of
    /// the network; `forwardingRules` arrives already deduped, each rule paired
    /// with the guest address it forwards to.
    func createNetwork(
        _ kind: VmnetNetworkKind,
        addressing: VmnetNetworkAddressing?,
        reservations: [VmnetReservation],
        forwardingRules: [(rule: PortForwardingRule, internalAddress: String)]
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

extension PortForwardingTransport {
    /// The `IPPROTO_*` value vmnet takes for this transport.
    fileprivate var ipProtocol: UInt8 {
        switch self {
        case .tcp: UInt8(IPPROTO_TCP)
        case .udp: UInt8(IPPROTO_UDP)
        }
    }
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
        reservations: [VmnetReservation],
        forwardingRules: [(rule: PortForwardingRule, internalAddress: String)]
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
        try install(forwarding: forwardingRules, onto: configuration)
        guard let network = vmnet_network_create(configuration, &status) else {
            throw VmnetOperationError(operation: "vmnet_network_create", status: status)
        }

        let reserved = Self.reservedAddressing(of: network)
        Self.logger.notice(
            "Created \(kind.rawValue, privacy: .public) network (\(addressing == nil ? "fresh" : "pinned", privacy: .public), \(reservations.count, privacy: .public) reservations, \(forwardingRules.count, privacy: .public) forwarding rules): \(reserved.ipv4Subnet, privacy: .public) mask \(reserved.ipv4Mask, privacy: .public), \(reserved.ipv6Prefix, privacy: .public)/\(reserved.ipv6PrefixLength, privacy: .public)"
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
        _ reservations: [VmnetReservation],
        onto configuration: vmnet_network_configuration_ref
    ) throws {
        for entry in reservations {
            let octets = entry.mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
            guard octets.count == 6, let addressValue = IPv4Value.parse(entry.address) else {
                throw VmnetOperationError(operation: "parsing DHCP reservation", status: nil)
            }
            var address = in_addr(s_addr: addressValue.bigEndian)
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

    private func install(
        forwarding rules: [(rule: PortForwardingRule, internalAddress: String)],
        onto configuration: vmnet_network_configuration_ref
    ) throws {
        for entry in rules {
            guard let addressValue = IPv4Value.parse(entry.internalAddress) else {
                throw VmnetOperationError(
                    operation: "parsing a port forwarding rule's guest address", status: nil)
            }
            var address = in_addr(s_addr: addressValue.bigEndian)
            // Argument order follows the signature, which takes the internal
            // (guest) port before the external (host) one — vmnet.h's own
            // `@param` block for this function lists them the other way round.
            let status = vmnet_network_configuration_add_port_forwarding_rule(
                configuration, entry.rule.transport.ipProtocol, sa_family_t(AF_INET),
                entry.rule.guestPort, entry.rule.hostPort, &address)
            guard status == .VMNET_SUCCESS else {
                throw VmnetOperationError(
                    operation: "vmnet_network_configuration_add_port_forwarding_rule", status: status)
            }
        }
    }

    private func pin(
        _ addressing: VmnetNetworkAddressing, onto configuration: vmnet_network_configuration_ref
    ) throws {
        guard let subnetValue = IPv4Value.parse(addressing.ipv4Subnet),
            let maskValue = IPv4Value.parse(addressing.ipv4Mask)
        else {
            throw VmnetOperationError(operation: "parsing stored IPv4 addressing", status: nil)
        }
        var subnet = in_addr(s_addr: subnetValue.bigEndian)
        var mask = in_addr(s_addr: maskValue.bigEndian)
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
            ipv4Subnet: IPv4Value.string(UInt32(bigEndian: subnet.s_addr)),
            ipv4Mask: IPv4Value.string(UInt32(bigEndian: mask.s_addr)),
            ipv6Prefix: ipv6String(prefix),
            ipv6PrefixLength: prefixLength)
    }

    private static func ipv6String(_ address: in6_addr) -> String {
        withUnsafeBytes(of: address) {
            presentationString($0, family: AF_INET6, capacity: INET6_ADDRSTRLEN)
        }
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
    /// Ensures `mac` holds a DHCP reservation slot on the network of `kind`.
    /// Cheap and non-blocking — safe from the main actor; the reservation is
    /// installed at the network's next materialization.
    func reserveAddressIfNeeded(for mac: String, kind: VmnetNetworkKind)
    /// Frees the DHCP reservation slot `mac` holds on the network of `kind`,
    /// so a later MAC can take it; a no-op when it holds none. Cheap and
    /// non-blocking — safe from the main actor.
    ///
    /// The slot is emptied in place, so no surviving VM's reserved address
    /// moves. The live network keeps honoring the freed reservation until its
    /// next materialization.
    func releaseAddressReservation(for mac: String, kind: VmnetNetworkKind)
    /// Frees every DHCP reservation slot on the network of `kind` whose MAC is
    /// not in `macs` — the reclaim for slots orphaned while the app was not
    /// running. Same in-place semantics as
    /// ``releaseAddressReservation(for:kind:)``.
    ///
    /// Callers pass the complete set of MACs wanting a slot on that network;
    /// an incomplete set frees slots that are still in use.
    func retainAddressReservations(_ macs: Set<String>, kind: VmnetNetworkKind)
    /// The IPv4 address reserved for `mac` on the network of `kind`; `nil`
    /// while `mac` holds no slot or the network has never materialized (its
    /// addressing is not yet known).
    func reservedAddress(for mac: String, kind: VmnetNetworkKind) -> String?
    /// Records `rules` as what the VM at `mac` forwards on the network of
    /// `kind`, replacing whatever it declared before; an empty array declares
    /// none. Cheap and non-blocking — safe from the main actor.
    ///
    /// Rules are fixed at network creation, so a change reaches guests at the
    /// network's next materialization.
    func setPortForwardingRules(_ rules: [PortForwardingRule], for mac: String, kind: VmnetNetworkKind)
    /// The kind whose materialized network `network` is, `nil` for a network
    /// this service does not hold.
    func kind(ofNetwork network: vmnet_network_ref) -> VmnetNetworkKind?
}

/// Recreating an app-managed network — split off ``VmnetNetworkProviding`` so
/// only the library's arbiter can express the call.
///
/// Dropping a network pulls it out from under every VM sharing it, so the one
/// type that can see every VM is the one that decides. A consumer holding a
/// plain ``VmnetNetworkProviding`` — attachment construction, one session's
/// attachment recovery — cannot name these members at all.
protocol VmnetNetworkRecreating: Sendable {
    /// Drops (and releases) the materialized network of `kind`, so the next
    /// materialization creates it anew — pinned to the persisted addressing,
    /// so recovery cannot drift the subnet.
    func invalidateNetwork(for kind: VmnetNetworkKind)
    /// Whether the materialized network of `kind` carries a different set of
    /// DHCP reservations or forwarding rules than the ones that would install
    /// right now — so recreating it would change what guests get. `false`
    /// while no network of `kind` is materialized.
    func networkConfigurationIsPending(for kind: VmnetNetworkKind) -> Bool
}

/// Owns the app's managed vmnet networks — the Host Only network and the
/// Shared Network network — and the per-VM DHCP reservations and
/// port-forwarding rules riding them.
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
/// Reservations and forwarding rules are both fixed at network creation
/// (vmnet.h: modifying reservations is not allowed while a network is active,
/// and rules can only be added to a configuration), so either one declared
/// while its network is materialized takes effect at the next materialization
/// — the next app launch, or a recreate driven by recovery or by
/// ``networkConfigurationIsPending(for:)``.
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
    /// Guards `networks`, `records`, `desiredForwardingRules` and
    /// `pinnedOnlyKinds` — never held across a vmnet call or file I/O, so the
    /// main-actor paths (`attachmentIfMaterialized`, `reserveAddressIfNeeded`,
    /// `reservedAddress`) can never block behind a materialization in flight.
    private let stateLock = NSLock()
    /// The materialized network of each kind, present exactly for the kinds one
    /// exists for.
    private var networks: [VmnetNetworkKind: MaterializedNetworkState] = [:]
    private var records: [VmnetNetworkKind: VmnetNetworkRecord]
    /// The forwarding rules each VM declares on a network, keyed by lowercased
    /// MAC.
    ///
    /// In-memory only: each VM's `config.json` owns its rules, and the library
    /// re-declares every VM's at load, before anything materializes.
    private var desiredForwardingRules: [VmnetNetworkKind: [String: [PortForwardingRule]]] = [:]
    /// Kinds whose next materialization must reserve the stored addressing or
    /// fail. Set by invalidation: its recreate races VZ still holding the old
    /// network's refs (a sibling VM's live attachment keeps the subnet
    /// reserved), and falling back to a fresh subnet there would silently
    /// shift every VM's reserved address.
    private var pinnedOnlyKinds: Set<VmnetNetworkKind> = []
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

    /// How many networks one request may create before publishing whatever the
    /// last attempt produced: each retry answers a reservation or rule
    /// declaration that landed while the previous create was in flight, and a
    /// caller cannot be made to wait on an editor that keeps typing.
    private static let materializeAttemptLimit = 3

    /// Names the declaration kinds a log line is about, for the two that report
    /// what changed mid-create.
    private static func declarationNames(reservations: Bool, rules: Bool) -> String {
        [reservations ? "DHCP reservations" : nil, rules ? "forwarding rules" : nil]
            .compactMap { $0 }
            .joined(separator: " and ")
    }

    /// The app-managed network of `kind`, materializing it on first use.
    /// Blocks for the vmnet XPC round-trip — never call on the main actor.
    ///
    /// A reservation slot taken (or freed) and a rule declared during the create
    /// are not in the network that comes back, and would go unnoticed — nothing
    /// was materialized when they arrived, so they never read as pending. Such a
    /// network is released and recreated before anyone can take it, up to
    /// ``materializeAttemptLimit`` attempts.
    func network(for kind: VmnetNetworkKind) throws -> VmnetNetworkHandle {
        if let handle = cachedHandle(for: kind) { return handle }
        materializeLock.lock()
        defer { materializeLock.unlock() }
        if let handle = cachedHandle(for: kind) { return handle }
        var attempt = 0
        while true {
            attempt += 1
            let materialized = try materialize(kind)
            stateLock.lock()
            // Both sides are measured against the addressing this attempt
            // submitted with, so only a changed declaration registers: a
            // network that came back on addressing the record did not ask for
            // re-derives every address without anyone having declared
            // anything, and reading that as a mid-create change would recreate
            // on every attempt. It publishes pending instead, for a later idle
            // rebuild to carry.
            let installable = resolveDeclarationsLocked(
                for: kind, addressing: materialized.submittedAddressing
            ).installable
            let reservationsChanged = materialized.submitted.reservations != installable.reservations
            let rulesChanged = materialized.submitted.forwardingRules != installable.forwardingRules
            let stale = reservationsChanged || rulesChanged
            let changed = Self.declarationNames(
                reservations: reservationsChanged, rules: rulesChanged)
            if stale, attempt < Self.materializeAttemptLimit {
                stateLock.unlock()
                // Never published, so nothing else can hold this network.
                operations.releaseNetwork(materialized.handle)
                Self.logger.info(
                    "The \(kind.rawValue, privacy: .public) network's \(changed, privacy: .public) changed while it was being created — recreating it"
                )
                continue
            }
            networks[kind] = MaterializedNetworkState(
                handle: materialized.handle, installed: materialized.installed)
            pinnedOnlyKinds.remove(kind)
            stateLock.unlock()
            if stale {
                // Left pending on purpose: the next configuration sync or
                // session teardown recreates the network at an idle moment.
                Self.logger.warning(
                    "Published the \(kind.rawValue, privacy: .public) network without the \(changed, privacy: .public) declared during its creation — they take effect at the next recreate"
                )
            }
            return materialized.handle
        }
    }

    private func cachedHandle(for kind: VmnetNetworkKind) -> VmnetNetworkHandle? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return networks[kind]?.handle
    }

    private func materialize(_ kind: VmnetNetworkKind) throws -> MaterializedNetwork {
        if let stored = currentRecord(for: kind).addressing {
            do {
                let submitted = submission(for: kind, addressing: stored)
                let (handle, reserved) = try operations.createNetwork(
                    kind, addressing: stored, reservations: submitted.reservations,
                    forwardingRules: Self.operatorRules(submitted.forwardingRules))
                if reserved == stored {
                    Self.logger.info(
                        "Recreated the \(kind.rawValue, privacy: .public) network with its stored addressing"
                    )
                    return MaterializedNetwork(
                        handle: handle, submitted: submitted, submittedAddressing: stored)
                }
                // vmnet accepted the pin but reserved something else; the
                // store must follow what the network actually is, or every
                // later launch re-pins a value no network carries. The
                // installed reservations were derived from the old addressing,
                // so none of them — nor the rules forwarding to them — holds on
                // this network; report none, and let the pending rule set drive
                // a later recreate.
                updateRecord(for: kind) { $0.addressing = reserved }
                Self.logger.warning(
                    "Pinned \(kind.rawValue, privacy: .public) network addressing was adjusted by the system — persisting the reserved values"
                )
                return MaterializedNetwork(
                    handle: handle, submitted: submitted, honorsSubmission: false,
                    submittedAddressing: stored)
            } catch {
                if isPinnedOnly(kind) {
                    // An invalidation recreate racing VZ's own refs on the old
                    // network: a fresh-subnet fallback here would silently
                    // shift every VM's reserved address, so fail and let the
                    // recovery ladder retry once the old refs drain.
                    Self.logger.warning(
                        "Recreating the invalidated \(kind.rawValue, privacy: .public) network at its stored addressing failed — retrying later rather than drifting the subnet: \(error.localizedDescription, privacy: .public)"
                    )
                    throw error
                }
                Self.logger.warning(
                    "Stored \(kind.rawValue, privacy: .public) network addressing is no longer reservable — creating fresh, guest addressing may change: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return try materializeFresh(kind)
    }

    private func isPinnedOnly(_ kind: VmnetNetworkKind) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pinnedOnlyKinds.contains(kind)
    }

    /// First-ever (or fallback) materialization: the reservation slots' IPs
    /// depend on the subnet, which is only known once a network exists — so
    /// create fresh to discover the addressing, then release and recreate
    /// pinned to it with the reservations installed.
    private func materializeFresh(_ kind: VmnetNetworkKind) throws -> MaterializedNetwork {
        let (probe, discovered) = try operations.createNetwork(
            kind, addressing: nil, reservations: [], forwardingRules: [])
        let slotCount = currentRecord(for: kind).reservedMACs.count(where: { $0 != nil })
        guard slotCount > 0 else {
            updateRecord(for: kind) { $0.addressing = discovered }
            Self.logger.notice("Created and persisted the \(kind.rawValue, privacy: .public) network")
            return MaterializedNetwork(handle: probe)
        }

        operations.releaseNetwork(probe)
        do {
            let submitted = submission(for: kind, addressing: discovered)
            let (handle, reserved) = try operations.createNetwork(
                kind, addressing: discovered, reservations: submitted.reservations,
                forwardingRules: Self.operatorRules(submitted.forwardingRules))
            updateRecord(for: kind) { $0.addressing = reserved }
            Self.logger.notice(
                "Created and persisted the \(kind.rawValue, privacy: .public) network with \(slotCount, privacy: .public) reservation slots"
            )
            return MaterializedNetwork(
                handle: handle, submitted: submitted,
                honorsSubmission: reserved == discovered, submittedAddressing: discovered)
        } catch {
            // The discovered subnet was re-grabbed between release and
            // recreate. Fall back to a working network without reservations —
            // the mode beats the IP display — and let the next
            // materialization install them.
            Self.logger.warning(
                "Recreating the \(kind.rawValue, privacy: .public) network with reservations failed — falling back to a fresh network without them: \(error.localizedDescription, privacy: .public)"
            )
            let (handle, addressing) = try operations.createNetwork(
                kind, addressing: nil, reservations: [], forwardingRules: [])
            updateRecord(for: kind) { $0.addressing = addressing }
            // Submitted nothing and carries nothing, which is what it reports:
            // the retry that answers reads as one more declaration to install,
            // and it pins the subnet just persisted rather than the one that
            // was re-grabbed — a create that can succeed where this one could
            // not.
            return MaterializedNetwork(handle: handle)
        }
    }

    /// The configuration a network of `kind` pinned to `addressing` will be
    /// created with, warning about every slot and rule that cannot install.
    private func submission(
        for kind: VmnetNetworkKind, addressing: VmnetNetworkAddressing
    ) -> InstalledConfiguration {
        stateLock.lock()
        let resolved = resolveDeclarationsLocked(for: kind, addressing: addressing)
        stateLock.unlock()
        for (index, slot) in resolved.slots.enumerated() {
            switch slot {
            case .installable, .free:
                continue
            case .unparseableMAC:
                Self.logger.warning(
                    "Skipping unparseable MAC in \(kind.rawValue, privacy: .public) reservation slot \(index, privacy: .public)"
                )
            case .noAddressLeft:
                Self.logger.warning(
                    "No address left in the \(kind.rawValue, privacy: .public) subnet for reservation slot \(index, privacy: .public)"
                )
            }
        }
        for duplicate in resolved.duplicateRules {
            Self.logger.warning(
                "Dropping a \(kind.rawValue, privacy: .public) forwarding rule: \(duplicate.rule.transport.displayName, privacy: .public) host port \(duplicate.rule.hostPort, privacy: .public) is already forwarded on that network"
            )
        }
        for unreserved in resolved.unreservedRules {
            Self.logger.warning(
                "Dropping \(unreserved.count, privacy: .public) \(kind.rawValue, privacy: .public) forwarding rules for a VM holding no address reservation on that network"
            )
        }
        return resolved.installable
    }

    /// What one reservation slot resolves to against a network's addressing.
    private enum ResolvedSlot {
        case installable(mac: String, address: String)
        /// The slot holds no MAC — released, and waiting to be refilled.
        case free
        /// The slot's MAC no longer parses (a hand-edited store).
        case unparseableMAC
        /// The subnet has no address left at this slot's index.
        case noAddressLeft
    }

    /// Resolves every reservation slot in order, without logging — the shared
    /// source of truth for what a network of `addressing` would install, read
    /// both while materializing and while answering
    /// ``networkConfigurationIsPending(for:)``.
    private static func resolveSlots(
        macs: [String?], addressing: VmnetNetworkAddressing
    ) -> [ResolvedSlot] {
        macs.enumerated().map { index, mac in
            guard let mac else { return .free }
            guard VZMACAddress(string: mac) != nil else { return .unparseableMAC }
            guard let address = addressing.reservedAddress(slot: index) else { return .noAddressLeft }
            return .installable(mac: mac, address: address)
        }
    }

    private static func installableReservations(_ slots: [ResolvedSlot]) -> [VmnetReservation] {
        slots.compactMap { slot in
            guard case .installable(let mac, let address) = slot else { return nil }
            return VmnetReservation(mac: mac, address: address)
        }
    }

    // MARK: - Port forwarding

    /// One declared rule resolved against the reservation carrying it.
    private struct ResolvedForwardingRule: Equatable {
        let mac: String
        let rule: PortForwardingRule
        /// The guest's reserved IPv4 address — the rule's internal address.
        let address: String
    }

    /// What one network of a kind installs at creation: the DHCP reservations
    /// in slot order, and the rules those reservations carry.
    ///
    /// Both staleness questions the service asks — did a declaration change
    /// while the network was being created, is the live network out of date now
    /// — are equality on this one value, and every side of both comes from
    /// ``resolveDeclarationsLocked(for:addressing:)``, the configuration each
    /// create submits included.
    private struct InstalledConfiguration: Equatable {
        var reservations: [VmnetReservation] = []
        var forwardingRules: [ResolvedForwardingRule] = []

        /// The address this network installed for `mac`; `nil` when it
        /// installed none.
        func address(for mac: String) -> String? {
            reservations.first(where: { $0.mac == mac })?.address
        }
    }

    /// What one successful materialization produced: the handle, plus what the
    /// created network actually honors.
    private struct MaterializedNetwork {
        let handle: VmnetNetworkHandle
        /// What this attempt handed to `createNetwork` — the declarations as
        /// they stood when it started. Comparing it against what would install
        /// now is what tells a declaration that changed mid-create from one
        /// that never held.
        var submitted = InstalledConfiguration()
        /// Whether the network came back on the addressing ``submitted`` was
        /// resolved against. `false` means it honors none of it: the
        /// reservations were derived from addressing this network does not
        /// carry, and neither do the rules forwarding to them.
        var honorsSubmission = true
        /// The addressing ``submitted`` was resolved against, so an equivalent
        /// submission made now is measured on the same footing — otherwise a
        /// network that came back on addressing the record did not ask for
        /// reads as a declaration change on every attempt. `nil` where the
        /// attempt submitted nothing, which measures against the record as it
        /// stands.
        var submittedAddressing: VmnetNetworkAddressing?

        /// What the live network actually installs.
        var installed: InstalledConfiguration {
            honorsSubmission ? submitted : InstalledConfiguration()
        }
    }

    /// A published network: the handle callers attach to, and the configuration
    /// it was created with — the only one it honors.
    private struct MaterializedNetworkState {
        let handle: VmnetNetworkHandle
        let installed: InstalledConfiguration
    }

    /// Pairs each declared rule with the address of the reservation carrying
    /// it, in reservation-slot order and each MAC's own rule order — so the
    /// same library always yields the same rule set — and drops every later
    /// claimant of a (transport, host port) pair.
    private static func resolveForwardingRules(
        desired: [String: [PortForwardingRule]],
        reservations: [VmnetReservation]
    ) -> (
        installing: [ResolvedForwardingRule], duplicates: [ResolvedForwardingRule],
        unreservedMACs: [String]
    ) {
        var installing: [ResolvedForwardingRule] = []
        var duplicates: [ResolvedForwardingRule] = []
        var claimed: Set<PortForwardingHostClaim> = []
        for entry in reservations {
            for rule in desired[entry.mac] ?? [] {
                let resolved = ResolvedForwardingRule(
                    mac: entry.mac, rule: rule, address: entry.address)
                if claimed.insert(rule.hostClaim).inserted {
                    installing.append(resolved)
                } else {
                    duplicates.append(resolved)
                }
            }
        }
        let reserved = Set(reservations.map(\.mac))
        return (installing, duplicates, desired.keys.filter { !reserved.contains($0) }.sorted())
    }

    private static func operatorRules(
        _ resolved: [ResolvedForwardingRule]
    ) -> [(rule: PortForwardingRule, internalAddress: String)] {
        resolved.map { (rule: $0.rule, internalAddress: $0.address) }
    }

    /// One resolution of a kind's declarations: what a network created right
    /// now would install, and everything it would have to drop.
    private struct ResolvedDeclarations {
        var installable = InstalledConfiguration()
        /// Every reservation slot in order — the ones that are neither
        /// installable nor free are the ones a create drops.
        var slots: [ResolvedSlot] = []
        /// Rules dropped because another VM already claims their host port.
        var duplicateRules: [ResolvedForwardingRule] = []
        /// How many rules each MAC holding no reservation declared — all of
        /// them dropped.
        var unreservedRules: [(mac: String, count: Int)] = []
    }

    /// Resolves `kind`'s declarations against the addressing its network
    /// carries. `installable` is what a create right now would install — slots
    /// past the subnet's capacity, MACs that no longer parse, and rules with no
    /// reservation or a host port another VM claims are not in it, so it is
    /// directly comparable with what a materialized network installed. Pass
    /// `addressing` to resolve against something other than what the record
    /// holds now — it is a resolution input, never a compared field.
    ///
    /// The one producer: both staleness comparisons and the configuration every
    /// create submits come from here, so nothing is kept in step by hand.
    ///
    /// The caller holds `stateLock`.
    private func resolveDeclarationsLocked(
        for kind: VmnetNetworkKind, addressing override: VmnetNetworkAddressing? = nil
    ) -> ResolvedDeclarations {
        guard let record = records[kind], let addressing = override ?? record.addressing
        else { return ResolvedDeclarations() }
        let slots = Self.resolveSlots(macs: record.reservedMACs, addressing: addressing)
        let reservations = Self.installableReservations(slots)
        let desired = desiredForwardingRules[kind] ?? [:]
        let rules = Self.resolveForwardingRules(desired: desired, reservations: reservations)
        return ResolvedDeclarations(
            installable: InstalledConfiguration(
                reservations: reservations, forwardingRules: rules.installing),
            slots: slots,
            duplicateRules: rules.duplicates,
            unreservedRules: rules.unreservedMACs.map { (mac: $0, count: desired[$0]?.count ?? 0) })
    }

    // MARK: - Records

    private func currentRecord(for kind: VmnetNetworkKind) -> VmnetNetworkRecord {
        stateLock.lock()
        defer { stateLock.unlock() }
        return records[kind] ?? VmnetNetworkRecord()
    }

    /// Mutates `kind`'s record under the state lock and schedules a persist
    /// when the mutation changed it. The enqueue happens inside the critical
    /// section (it does no I/O on the calling thread) so snapshots reach the
    /// serial persist queue in mutation order — enqueued after unlock, two
    /// racing mutators could write the stale snapshot last.
    private func updateRecord(for kind: VmnetNetworkKind, _ mutate: (inout VmnetNetworkRecord) -> Void) {
        stateLock.lock()
        let original = records[kind] ?? VmnetNetworkRecord()
        var record = original
        mutate(&record)
        guard record != original else {
            stateLock.unlock()
            return
        }
        records[kind] = record
        persistAsync(records)
        stateLock.unlock()
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

extension VmnetNetworkService: VmnetNetworkProviding, VmnetNetworkRecreating {
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
        let dropped = networks.removeValue(forKey: kind)?.handle
        // A sibling VM's live attachment may still hold the old network (VZ
        // retains its own ref), keeping the subnet reserved past our release —
        // so the recreate must reserve the stored addressing or fail, never
        // drift to a fresh subnet that would shift every reserved address.
        if dropped != nil { pinnedOnlyKinds.insert(kind) }
        stateLock.unlock()
        guard let dropped else { return }
        // Releasing the ref ends this process's claim on the subnet; without
        // it, a fully torn-down network would still block the pinned recreate
        // as a conflict.
        operations.releaseNetwork(dropped)
        Self.logger.notice("Invalidated the \(kind.rawValue, privacy: .public) network")
    }

    func reserveAddressIfNeeded(for mac: String, kind: VmnetNetworkKind) {
        let normalized = mac.lowercased()
        guard VZMACAddress(string: normalized) != nil else {
            // A malformed MAC (hand-edited config) would poison every later
            // materialization of the kind — refuse it a slot instead.
            Self.logger.warning(
                "Refusing a \(kind.rawValue, privacy: .public) reservation slot for an unparseable MAC"
            )
            return
        }
        updateRecord(for: kind) { record in
            guard !record.reservedMACs.contains(normalized) else { return }
            // A slot freed by an earlier release is refilled before the table
            // grows, so reclaimed addresses are the ones handed out next.
            let slot = record.reservedMACs.firstIndex(where: { $0 == nil }) ?? record.reservedMACs.count
            if slot == record.reservedMACs.count {
                record.reservedMACs.append(normalized)
            } else {
                record.reservedMACs[slot] = normalized
            }
            Self.logger.info(
                "Reserved \(kind.rawValue, privacy: .public) address slot \(slot, privacy: .public)"
            )
        }
    }

    func releaseAddressReservation(for mac: String, kind: VmnetNetworkKind) {
        let normalized = mac.lowercased()
        updateRecord(for: kind) { record in
            guard let slot = record.reservedMACs.firstIndex(of: normalized) else { return }
            record.reservedMACs[slot] = nil
            Self.trimFreeTail(&record.reservedMACs)
            Self.logger.info(
                "Released \(kind.rawValue, privacy: .public) address slot \(slot, privacy: .public)"
            )
        }
    }

    func retainAddressReservations(_ macs: Set<String>, kind: VmnetNetworkKind) {
        let retained = Set(macs.map { $0.lowercased() })
        updateRecord(for: kind) { record in
            var freed = 0
            for (slot, mac) in record.reservedMACs.enumerated() {
                guard let mac, !retained.contains(mac) else { continue }
                record.reservedMACs[slot] = nil
                freed += 1
            }
            guard freed > 0 else { return }
            Self.trimFreeTail(&record.reservedMACs)
            Self.logger.info(
                "Released \(freed, privacy: .public) \(kind.rawValue, privacy: .public) address slots no VM claims"
            )
        }
    }

    /// Drops trailing free slots, so an emptied table reads as empty and the
    /// store never accumulates a tail of `null`s.
    private static func trimFreeTail(_ macs: inout [String?]) {
        while let last = macs.last, last == nil { macs.removeLast() }
    }

    func reservedAddress(for mac: String, kind: VmnetNetworkKind) -> String? {
        let normalized = mac.lowercased()
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let record = records[kind], let addressing = record.addressing,
            let slot = record.reservedMACs.firstIndex(of: normalized),
            let derived = addressing.reservedAddress(slot: slot)
        else { return nil }
        // While the network is materialized, answer only what it actually
        // installed: reservations are fixed at creation, so a slot assigned
        // (or re-derived) after that is pending until the next
        // materialization — showing it now would display an address the
        // guest never receives.
        if let live = networks[kind], live.installed.address(for: normalized) != derived {
            return nil
        }
        return derived
    }

    func setPortForwardingRules(
        _ rules: [PortForwardingRule], for mac: String, kind: VmnetNetworkKind
    ) {
        let normalized = mac.lowercased()
        guard VZMACAddress(string: normalized) != nil else {
            // A malformed MAC (hand-edited config) resolves to no reservation,
            // so its rules could never install — refuse them instead.
            Self.logger.warning(
                "Refusing \(kind.rawValue, privacy: .public) port forwarding rules for an unparseable MAC"
            )
            return
        }
        stateLock.lock()
        let previous = desiredForwardingRules[kind]?[normalized] ?? []
        if rules.isEmpty {
            desiredForwardingRules[kind]?[normalized] = nil
        } else {
            desiredForwardingRules[kind, default: [:]][normalized] = rules
        }
        stateLock.unlock()
        guard previous != rules else { return }
        Self.logger.info(
            "A VM now declares \(rules.count, privacy: .public) \(kind.rawValue, privacy: .public) forwarding rules"
        )
    }

    func networkConfigurationIsPending(for kind: VmnetNetworkKind) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        // Nothing pends against a network that does not exist yet: its next
        // materialization installs whatever is declared then.
        guard let live = networks[kind] else { return false }
        // Both sides are compared as what would *install*, not as everything
        // declared: a slot past the subnet's capacity, a MAC that no longer
        // parses, and a rule whose VM holds no reservation can never install,
        // and measuring against them would leave the flag stuck true and drive
        // an endless recreate.
        //
        // The whole reservation set is compared rather than only its additions,
        // so a slot released by a departed VM also pends — the live network
        // honors its reservation until the recreate.
        return resolveDeclarationsLocked(for: kind).installable != live.installed
    }

    func kind(ofNetwork network: vmnet_network_ref) -> VmnetNetworkKind? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return networks.first(where: { $0.value.handle.network == network })?.key
    }
}
