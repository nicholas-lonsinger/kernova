import Foundation
import KernovaKit
import KernovaLogging

/// The IPv4 address the host last saw each running VM use on its app-managed
/// network, read from the host's ARP table by the VM's MAC address — the one
/// answer the Overview, the Network panel and the command surface all state.
///
/// An entry counts only while it is unexpired: the table keeps listing an entry
/// for minutes past its expiry
/// (docs/research/2026-09-22-host-arp-table-observes-vmnet-guests.md).
///
/// The table is read every ``defaultPollInterval`` seconds, off the main actor,
/// while at least one VM is running on an app-managed network, and not at all
/// otherwise.
@MainActor
@Observable
final class GuestAddressObserver {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "GuestAddressObserver")

    /// How often, in seconds, the table is read while anything is watched.
    nonisolated static let defaultPollInterval: TimeInterval = 2

    /// A watched VM: its MAC address on the network its mode joins.
    struct Key: Hashable, Sendable {
        let hardwareAddress: EthernetAddress
        let kind: VmnetNetworkKind
    }

    /// The address each watched VM was seen using at the last read.
    private var observedAddresses: [Key: String] = [:]

    @ObservationIgnored private let reader: any ARPTableReading
    @ObservationIgnored private let vmnetNetworks: any VmnetNetworkProviding
    /// Whether this process can read the table —
    /// `EntitlementService.supportsGuestAddressObservation`.
    @ObservationIgnored private let canObserve: Bool
    /// Whether Shared rides the app-managed network rather than the system NAT
    /// attachment, which no network here backs.
    @ObservationIgnored private let isVMNetworkingEntitled: Bool
    @ObservationIgnored private let clock: any EngineClock
    @ObservationIgnored private let pollInterval: TimeInterval
    /// The wall clock the table's expiries are measured against, in Unix
    /// seconds.
    @ObservationIgnored private let now: @Sendable () -> Int

    /// Which VMs exist. Weak and assigned after construction: the library owns
    /// this observer, so a strong reference back would be a cycle.
    @ObservationIgnored weak var roster: (any VMInstanceRoster)?

    @ObservationIgnored private var readTask: Task<Void, Never>?
    /// Whether the last read failed, so a failing streak is logged once.
    @ObservationIgnored private var readIsFailing = false

    init(
        reader: any ARPTableReading,
        vmnetNetworks: any VmnetNetworkProviding,
        canObserve: Bool,
        isVMNetworkingEntitled: Bool,
        clock: any EngineClock = makePlatformEngineClock(),
        pollInterval: TimeInterval = GuestAddressObserver.defaultPollInterval,
        now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970) }
    ) {
        self.reader = reader
        self.vmnetNetworks = vmnetNetworks
        self.canObserve = canObserve
        self.isVMNetworkingEntitled = isVMNetworkingEntitled
        self.clock = clock
        self.pollInterval = pollInterval
        self.now = now
    }

    /// What `instance`'s guest is seen using for an address on the network its
    /// mode joins.
    func address(for instance: VMInstance) -> GuestIPAddress {
        let config = instance.configuration
        guard config.networkEnabled, config.networkMode != .bridged,
            instance.hasLiveVirtualMachine, let key = key(for: config)
        else { return Self.address(withNoLiveGuest: config) }
        return observedAddresses[key].map(GuestIPAddress.observed) ?? .notObserved
    }

    /// What a guest configured as `config` answers for an address while
    /// nothing of it is live — a VM at rest, or one still being written.
    static func address(withNoLiveGuest config: VMConfiguration) -> GuestIPAddress {
        guard config.networkEnabled else { return .unavailable }
        // Answered before the capability: external DHCP owns a bridged guest's
        // address whether or not this process can read the table.
        return config.networkMode == .bridged ? .externallyAssigned : .unavailable
    }

    /// Starts reading the table if a VM is running on an app-managed network
    /// and no read loop is — called wherever a VM can start being one. The
    /// loop ends by itself at the first pass that finds nothing to watch.
    func watch() {
        guard readTask == nil, !watchedKeys().isEmpty else { return }
        readTask = Task { await self.readWhileWatched() }
    }

    private func readWhileWatched() async {
        while !Task.isCancelled {
            let keys = watchedKeys()
            guard !keys.isEmpty else { break }
            await read(for: keys)
            do { try await clock.sleep(for: pollInterval) } catch { break }
        }
        readTask = nil
        // Nothing running reads these, and a VM that starts again is answered
        // from a fresh read.
        if !observedAddresses.isEmpty { observedAddresses = [:] }
    }

    /// Reads the table once and publishes what it shows for `keys`.
    private func read(for keys: Set<Key>) async {
        var subnets: [VmnetNetworkKind: IPv4Subnet] = [:]
        for kind in VmnetNetworkKind.allCases {
            subnets[kind] = vmnetNetworks.ipv4Subnet(for: kind)
        }
        let entries: [ARPEntry]
        do {
            entries = try await Self.entries(from: reader)
            readIsFailing = false
        } catch {
            if !readIsFailing {
                #log(
                    Self.logger, .error,
                    "Could not read the host's ARP table — guest addresses read as not seen until a read succeeds: \(error.localizedDescription, privacy: .public)"
                )
            }
            readIsFailing = true
            entries = []
        }
        let addresses = Self.addresses(in: entries, for: keys, on: subnets, at: now())
        if addresses != observedAddresses { observedAddresses = addresses }
    }

    // A nonisolated async method runs off the caller's actor, so the sysctl
    // never lands on the main thread.
    nonisolated private static func entries(from reader: any ARPTableReading) async throws -> [ARPEntry] {
        try reader.entries()
    }

    /// The address each of `keys` is bound to in `entries`: of the entries
    /// carrying its MAC inside its network's subnet and expiring after `now`,
    /// the one expiring last. A permanent entry (expiry `0`) never counts — the
    /// host's own addresses and multicast groups are the ones the table holds.
    nonisolated static func addresses(
        in entries: [ARPEntry], for keys: Set<Key>, on subnets: [VmnetNetworkKind: IPv4Subnet],
        at now: Int
    ) -> [Key: String] {
        var latest: [Key: ARPEntry] = [:]
        for entry in entries where entry.expiry > now {
            for (kind, subnet) in subnets where subnet.contains(entry.ipv4) {
                let key = Key(hardwareAddress: entry.hardwareAddress, kind: kind)
                guard keys.contains(key), (latest[key]?.expiry ?? .min) < entry.expiry else { continue }
                latest[key] = entry
            }
        }
        return latest.mapValues { IPv4Value.string($0.ipv4) }
    }

    /// Every running VM this observer answers for.
    private func watchedKeys() -> Set<Key> {
        guard let roster else { return [] }
        return Set(
            roster.instances.compactMap { instance in
                instance.hasLiveVirtualMachine ? key(for: instance.configuration) : nil
            })
    }

    /// What `config` is watched under, `nil` where nothing here can see its
    /// address: networking off, a mode no app-managed network realizes, a build
    /// that attaches Shared to system NAT, a process that cannot read the
    /// table, or a MAC address that does not parse.
    private func key(for config: VMConfiguration) -> Key? {
        guard canObserve, isVMNetworkingEntitled, config.networkEnabled,
            let kind = VmnetNetworkKind(mode: config.networkMode),
            let mac = config.macAddress, let hardwareAddress = EthernetAddress(mac)
        else { return nil }
        return Key(hardwareAddress: hardwareAddress, kind: kind)
    }

    #if DEBUG
    /// The running read loop, for event-driven test waits.
    var readTaskForTesting: Task<Void, Never>? { readTask }

    /// Reads the table once now, outside the loop, for tests that assert on an
    /// answer rather than on the cadence.
    func readForTesting() async {
        await read(for: watchedKeys())
    }
    #endif
}
