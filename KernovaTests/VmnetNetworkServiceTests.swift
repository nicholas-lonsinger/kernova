import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("VmnetNetworkService Tests")
struct VmnetNetworkServiceTests {
    // MARK: - Helpers

    private static let storedAddressing = VmnetNetworkAddressing(
        ipv4Subnet: "192.168.77.0", ipv4Mask: "255.255.255.0",
        ipv6Prefix: "fd00:aaaa:bbbb:cccc::", ipv6PrefixLength: 64)

    /// A store location inside a directory unique to the calling test, so
    /// suites running in parallel never share `networks.json`.
    ///
    /// Caller must `defer` removal of the returned directory.
    private func makeStoreLocation() -> (directory: URL, storeURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VmnetNetworkServiceTests-\(UUID().uuidString)", isDirectory: true)
        return (directory, directory.appendingPathComponent("networks.json", isDirectory: false))
    }

    /// Writes `store` where the service reads it, creating the directory.
    private func seed(_ store: [VmnetNetworkKind: VmnetNetworkRecord], at storeURL: URL) throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try VMConfiguration.makeJSONEncoder().encode(store).write(to: storeURL)
    }

    /// The persisted store after every scheduled write has landed, or `nil`
    /// when nothing was written.
    private func readStore(
        at storeURL: URL, from service: VmnetNetworkService
    ) throws -> [VmnetNetworkKind: VmnetNetworkRecord]? {
        service.flushPersistsForTesting()
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        return try VMConfiguration.makeJSONDecoder()
            .decode([VmnetNetworkKind: VmnetNetworkRecord].self, from: data)
    }

    // MARK: - First materialization

    @Test("The first request creates the network fresh and persists its addressing")
    func firstRequestCreatesAndPersists() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)

        _ = try service.network(for: .hostOnly)

        #expect(operations.createdKinds == [.hostOnly])
        #expect(operations.pinnedAddressings == [nil])
        let store = try readStore(at: location.storeURL, from: service)
        #expect(
            store == [
                .hostOnly: VmnetNetworkRecord(
                    addressing: operations.freshAddressing, reservedMACs: [])
            ])
    }

    @Test("A second request returns the held network without touching vmnet again")
    func secondRequestReturnsTheHeldNetwork() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)

        let first = try service.network(for: .hostOnly)
        let second = try service.network(for: .hostOnly)

        // Every concurrent VM in the mode shares the one network, and its
        // subnet reservation lives as long as the ref.
        #expect(first.network == second.network)
        #expect(operations.createdKinds == [.hostOnly])
    }

    // MARK: - Recreating from the store

    @Test("Stored addressing is pinned onto the recreated network, not re-persisted")
    func storedAddressingPinsTheRecreatedNetwork() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try seed(
            [.hostOnly: VmnetNetworkRecord(addressing: Self.storedAddressing, reservedMACs: [])],
            at: location.storeURL)
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)

        _ = try service.network(for: .hostOnly)

        #expect(operations.pinnedAddressings == [Self.storedAddressing])
        let store = try readStore(at: location.storeURL, from: service)
        #expect(
            store == [
                .hostOnly: VmnetNetworkRecord(addressing: Self.storedAddressing, reservedMACs: [])
            ])
    }

    @Test("Unreservable stored addressing falls back to a fresh network and rewrites the store")
    func unreservableStoredAddressingCreatesFresh() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try seed(
            [.hostOnly: VmnetNetworkRecord(addressing: Self.storedAddressing, reservedMACs: [])],
            at: location.storeURL)
        let operations = MockVmnetNetworkOperator()
        operations.pinnedCreateError = TestFailure("subnet taken")
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)

        _ = try service.network(for: .hostOnly)

        #expect(operations.pinnedAddressings == [Self.storedAddressing, nil])
        let store = try readStore(at: location.storeURL, from: service)
        #expect(store?[.hostOnly]?.addressing == operations.freshAddressing)
    }

    @Test("Addressing the system adjusts on a pinned create is what gets persisted")
    func adjustedPinnedAddressingRewritesTheStore() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try seed(
            [.hostOnly: VmnetNetworkRecord(addressing: Self.storedAddressing, reservedMACs: [])],
            at: location.storeURL)
        let operations = MockVmnetNetworkOperator()
        operations.reservedAddressingOverride = operations.freshAddressing
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)

        _ = try service.network(for: .hostOnly)

        // The store must follow what the network actually reserved, or every
        // later launch re-pins a value no network carries.
        let store = try readStore(at: location.storeURL, from: service)
        #expect(store?[.hostOnly]?.addressing == operations.freshAddressing)
    }

    @Test("Invalidation releases the network and the next request recreates it pinned")
    func invalidationReleasesAndRecreatesPinned() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)

        let first = try service.network(for: .hostOnly)
        service.invalidateNetwork(for: .hostOnly)
        #expect(operations.releasedNetworks == [first.network])

        let second = try service.network(for: .hostOnly)
        #expect(second.network != first.network)
        // The recreate pins the addressing the first create persisted, so
        // invalidation can never drift the subnet.
        #expect(operations.pinnedAddressings == [nil, operations.freshAddressing])
    }

    @Test("An unreadable store is treated as empty rather than failing the request")
    func corruptStoreIsTreatedAsEmpty() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        try Data("not the store".utf8).write(to: location.storeURL)
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)

        _ = try service.network(for: .hostOnly)

        #expect(operations.pinnedAddressings == [nil])
        let store = try readStore(at: location.storeURL, from: service)
        #expect(store?[.hostOnly]?.addressing == operations.freshAddressing)
    }

    // MARK: - Failures

    @Test("A creation failure reaches the caller")
    func creationFailureReachesTheCaller() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let operations = MockVmnetNetworkOperator()
        operations.createNetworkError = TestFailure("vmnet refused")
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)

        #expect(throws: TestFailure.self) {
            try service.network(for: .hostOnly)
        }
        let store = try readStore(at: location.storeURL, from: service)
        #expect(store == nil)
    }

    @Test("Persistence disabled materializes the network and writes nothing")
    func disabledPersistenceMaterializesWithoutWriting() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations, storeURL: nil)

        let first = try service.network(for: .hostOnly)
        let second = try service.network(for: .hostOnly)

        #expect(first.network == second.network)
        #expect(operations.createdKinds == [.hostOnly])
        #expect(!FileManager.default.fileExists(atPath: location.directory.path(percentEncoded: false)))
    }

    // MARK: - Reservation slots

    @Test("Slots assign sequential addresses from host 2, keyed case-insensitively")
    func slotsAssignSequentialAddresses() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try seed(
            [.shared: VmnetNetworkRecord(addressing: Self.storedAddressing, reservedMACs: [])],
            at: location.storeURL)
        let service = VmnetNetworkService(
            operations: MockVmnetNetworkOperator(), storeURL: location.storeURL)

        service.reserveAddressIfNeeded(for: "AA:BB:CC:DD:EE:01", kind: .shared)
        service.reserveAddressIfNeeded(for: "aa:bb:cc:dd:ee:02", kind: .shared)
        // Re-reserving an existing MAC in another case must not take a new slot.
        service.reserveAddressIfNeeded(for: "aa:bb:cc:dd:ee:01", kind: .shared)

        #expect(service.reservedAddress(for: "aa:bb:cc:dd:ee:01", kind: .shared) == "192.168.77.2")
        #expect(service.reservedAddress(for: "AA:BB:CC:DD:EE:02", kind: .shared) == "192.168.77.3")
        #expect(service.reservedAddress(for: "aa:bb:cc:dd:ee:03", kind: .shared) == nil)
    }

    @Test("A reserved address is unknown until the network's addressing exists")
    func reservedAddressUnknownBeforeFirstMaterialization() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)

        service.reserveAddressIfNeeded(for: "aa:bb:cc:dd:ee:01", kind: .shared)
        #expect(service.reservedAddress(for: "aa:bb:cc:dd:ee:01", kind: .shared) == nil)

        _ = try service.network(for: .shared)
        #expect(service.reservedAddress(for: "aa:bb:cc:dd:ee:01", kind: .shared) == "192.168.213.2")
    }

    @Test("Slots persist across service instances")
    func slotsPersistAcrossInstances() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let first = VmnetNetworkService(
            operations: MockVmnetNetworkOperator(), storeURL: location.storeURL)
        first.reserveAddressIfNeeded(for: "aa:bb:cc:dd:ee:01", kind: .shared)
        first.flushPersistsForTesting()

        let second = VmnetNetworkService(
            operations: MockVmnetNetworkOperator(), storeURL: location.storeURL)
        second.reserveAddressIfNeeded(for: "aa:bb:cc:dd:ee:02", kind: .shared)

        let store = try readStore(at: location.storeURL, from: second)
        #expect(store?[.shared]?.reservedMACs == ["aa:bb:cc:dd:ee:01", "aa:bb:cc:dd:ee:02"])
    }

    // MARK: - Reservations at materialization

    @Test("First materialization with slots discovers addressing, then recreates pinned with reservations")
    func firstMaterializationInstallsReservationsViaDiscovery() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)
        service.reserveAddressIfNeeded(for: "aa:bb:cc:dd:ee:01", kind: .shared)

        let handle = try service.network(for: .shared)

        // Discovery create (fresh, no reservations), released, then the
        // pinned create carrying the reservations.
        #expect(operations.pinnedAddressings == [nil, operations.freshAddressing])
        #expect(operations.installedReservations.first?.isEmpty == true)
        #expect(operations.releasedNetworks.count == 1)
        #expect(operations.releasedNetworks.first != handle.network)
        let installed = try #require(operations.installedReservations.last)
        #expect(installed.map(\.mac) == ["aa:bb:cc:dd:ee:01"])
        #expect(installed.map(\.address) == ["192.168.213.2"])
    }

    @Test("Stored addressing materializes in one create with the reservations installed")
    func storedAddressingInstallsReservationsInOneCreate() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try seed(
            [
                .shared: VmnetNetworkRecord(
                    addressing: Self.storedAddressing,
                    reservedMACs: ["aa:bb:cc:dd:ee:01", "aa:bb:cc:dd:ee:02"])
            ], at: location.storeURL)
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)

        _ = try service.network(for: .shared)

        #expect(operations.pinnedAddressings == [Self.storedAddressing])
        let installed = try #require(operations.installedReservations.first)
        #expect(installed.map(\.address) == ["192.168.77.2", "192.168.77.3"])
    }

    @Test("A failed pinned recreate after discovery falls back to a fresh network without reservations")
    func failedRecreateAfterDiscoveryFallsBackFresh() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let operations = MockVmnetNetworkOperator()
        operations.pinnedCreateError = TestFailure("subnet re-grabbed")
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)
        service.reserveAddressIfNeeded(for: "aa:bb:cc:dd:ee:01", kind: .shared)

        _ = try service.network(for: .shared)

        // Discovery, failed pinned recreate, then the working fallback — the
        // mode beats the IP display.
        #expect(operations.pinnedAddressings == [nil, operations.freshAddressing, nil])
        #expect(operations.installedReservations.last?.isEmpty == true)
        let store = try readStore(at: location.storeURL, from: service)
        #expect(store?[.shared]?.addressing == operations.freshAddressing)
        #expect(store?[.shared]?.reservedMACs == ["aa:bb:cc:dd:ee:01"])
    }

    @Test("Slots past the subnet's capacity are dropped from the installed reservations")
    func slotsPastSubnetCapacityAreDropped() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        // A /30 leaves exactly one usable host past the gateway: host 2.
        let tiny = VmnetNetworkAddressing(
            ipv4Subnet: "192.168.77.0", ipv4Mask: "255.255.255.252",
            ipv6Prefix: "fd00:aaaa:bbbb:cccc::", ipv6PrefixLength: 64)
        try seed(
            [
                .shared: VmnetNetworkRecord(
                    addressing: tiny, reservedMACs: ["aa:bb:cc:dd:ee:01", "aa:bb:cc:dd:ee:02"])
            ], at: location.storeURL)
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)

        _ = try service.network(for: .shared)

        let installed = try #require(operations.installedReservations.first)
        #expect(installed.map(\.address) == ["192.168.77.2"])
        #expect(service.reservedAddress(for: "aa:bb:cc:dd:ee:02", kind: .shared) == nil)
    }

    // MARK: - Installed vs pending reservations

    @Test("A slot assigned while its network is materialized reads as pending, then resolves after rematerialization")
    func slotAssignedAfterMaterializationIsPending() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)
        service.reserveAddressIfNeeded(for: "aa:bb:cc:dd:ee:01", kind: .shared)
        _ = try service.network(for: .shared)

        service.reserveAddressIfNeeded(for: "aa:bb:cc:dd:ee:02", kind: .shared)

        // The live network was created before the second slot existed, so its
        // address is pending — showing it would display an address the guest
        // never receives.
        #expect(service.reservedAddress(for: "aa:bb:cc:dd:ee:01", kind: .shared) == "192.168.213.2")
        #expect(service.reservedAddress(for: "aa:bb:cc:dd:ee:02", kind: .shared) == nil)

        service.invalidateNetwork(for: .shared)
        // No network is materialized now, so the durable assignment shows.
        #expect(service.reservedAddress(for: "aa:bb:cc:dd:ee:02", kind: .shared) == "192.168.213.3")
        _ = try service.network(for: .shared)
        #expect(service.reservedAddress(for: "aa:bb:cc:dd:ee:02", kind: .shared) == "192.168.213.3")
    }

    @Test("System-adjusted pinned addressing leaves every reservation pending until rematerialization")
    func adjustedPinnedAddressingLeavesReservationsPending() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try seed(
            [
                .shared: VmnetNetworkRecord(
                    addressing: Self.storedAddressing, reservedMACs: ["aa:bb:cc:dd:ee:01"])
            ], at: location.storeURL)
        let operations = MockVmnetNetworkOperator()
        operations.reservedAddressingOverride = operations.freshAddressing
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)

        _ = try service.network(for: .shared)

        // The installed reservations were derived from the old addressing, so
        // none of them holds on the adjusted network.
        #expect(service.reservedAddress(for: "aa:bb:cc:dd:ee:01", kind: .shared) == nil)
    }

    @Test("An unparseable MAC is refused a reservation slot")
    func unparseableMACIsRefusedASlot() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let service = VmnetNetworkService(
            operations: MockVmnetNetworkOperator(), storeURL: location.storeURL)

        service.reserveAddressIfNeeded(for: "not-a-mac", kind: .shared)
        service.reserveAddressIfNeeded(for: "aa:bb:cc:dd:ee:01", kind: .shared)

        let store = try readStore(at: location.storeURL, from: service)
        #expect(store?[.shared]?.reservedMACs == ["aa:bb:cc:dd:ee:01"])
    }

    // MARK: - Invalidation stays pinned

    @Test("A recreate after invalidation never drifts to a fresh subnet")
    func invalidationRecreateNeverDriftsTheSubnet() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)
        _ = try service.network(for: .shared)

        service.invalidateNetwork(for: .shared)
        // A sibling VM's live attachment can keep the old subnet reserved past
        // our release; a fresh-subnet fallback would shift every VM's address.
        operations.pinnedCreateError = TestFailure("subnet still held by VZ refs")
        #expect(throws: TestFailure.self) {
            try service.network(for: .shared)
        }
        let store = try readStore(at: location.storeURL, from: service)
        #expect(store?[.shared]?.addressing == operations.freshAddressing)

        // Once the old refs drain, the pinned recreate succeeds and the
        // constraint lifts.
        operations.pinnedCreateError = nil
        _ = try service.network(for: .shared)
        #expect(operations.pinnedAddressings.last == operations.freshAddressing)
    }

    // MARK: - Network identity

    @Test("kind(ofNetwork:) answers for held networks only")
    func kindOfNetworkAnswersForHeldNetworks() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)

        let hostOnly = try service.network(for: .hostOnly)
        let shared = try service.network(for: .shared)

        #expect(service.kind(ofNetwork: hostOnly.network) == .hostOnly)
        #expect(service.kind(ofNetwork: shared.network) == .shared)
        service.invalidateNetwork(for: .shared)
        #expect(service.kind(ofNetwork: shared.network) == nil)
    }
}
