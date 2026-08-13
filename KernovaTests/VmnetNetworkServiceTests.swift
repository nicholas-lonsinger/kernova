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
    private func seed(_ store: [VmnetNetworkKind: VmnetNetworkAddressing], at storeURL: URL) throws {
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try VMConfiguration.makeJSONEncoder().encode(store).write(to: storeURL)
    }

    /// The persisted store, or `nil` when nothing was written.
    private func readStore(at storeURL: URL) throws -> [VmnetNetworkKind: VmnetNetworkAddressing]? {
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        return try VMConfiguration.makeJSONDecoder()
            .decode([VmnetNetworkKind: VmnetNetworkAddressing].self, from: data)
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
        let store = try readStore(at: location.storeURL)
        #expect(store == [.hostOnly: operations.freshAddressing])
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
        try seed([.hostOnly: Self.storedAddressing], at: location.storeURL)
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)

        _ = try service.network(for: .hostOnly)

        #expect(operations.pinnedAddressings == [Self.storedAddressing])
        let store = try readStore(at: location.storeURL)
        #expect(store == [.hostOnly: Self.storedAddressing])
    }

    @Test("Unreservable stored addressing falls back to a fresh network and rewrites the store")
    func unreservableStoredAddressingCreatesFresh() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try seed([.hostOnly: Self.storedAddressing], at: location.storeURL)
        let operations = MockVmnetNetworkOperator()
        operations.pinnedCreateError = TestFailure("subnet taken")
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)

        _ = try service.network(for: .hostOnly)

        #expect(operations.pinnedAddressings == [Self.storedAddressing, nil])
        let store = try readStore(at: location.storeURL)
        #expect(store == [.hostOnly: operations.freshAddressing])
    }

    @Test("Addressing the system adjusts on a pinned create is what gets persisted")
    func adjustedPinnedAddressingRewritesTheStore() throws {
        let location = makeStoreLocation()
        defer { try? FileManager.default.removeItem(at: location.directory) }
        try seed([.hostOnly: Self.storedAddressing], at: location.storeURL)
        let operations = MockVmnetNetworkOperator()
        operations.reservedAddressingOverride = operations.freshAddressing
        let service = VmnetNetworkService(operations: operations, storeURL: location.storeURL)

        _ = try service.network(for: .hostOnly)

        // The store must follow what the network actually reserved, or every
        // later launch re-pins a value no network carries.
        let store = try readStore(at: location.storeURL)
        #expect(store == [.hostOnly: operations.freshAddressing])
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
        let store = try readStore(at: location.storeURL)
        #expect(store == [.hostOnly: operations.freshAddressing])
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
        let store = try readStore(at: location.storeURL)
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
}
