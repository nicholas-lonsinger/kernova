import Foundation
import KernovaKit

@testable import Kernova

/// In-memory mock for `VMCommanding` that records what each verb was asked to
/// do without a library, a lifecycle coordinator, or a VM behind it.
///
/// `@MainActor` like the protocol, so no lock is needed: every call arrives on
/// the test's own isolation.
@MainActor
final class MockVMCommanding: VMCommanding {
    // MARK: - Seeding

    /// The library `list()` answers with, and what the recorded verbs address.
    var library: [VMSummary] = []
    /// The address `ipAddress(of:)` answers with.
    var reservedAddress: String?
    /// The snapshot `takeSnapshot` answers with, built from its arguments when
    /// left unset.
    var snapshotToReturn: SnapshotSummary?

    // MARK: - Recorded calls

    private(set) var listCallCount = 0
    private(set) var infoSelectors: [VMSelector] = []
    private(set) var ipAddressSelectors: [VMSelector] = []
    private(set) var startCalls: [(selector: VMSelector, recovery: Bool)] = []
    private(set) var stopCalls: [(selector: VMSelector, disposition: StopDisposition, confirmed: Bool)] =
        []
    private(set) var pauseSelectors: [VMSelector] = []
    private(set) var resumeSelectors: [VMSelector] = []
    private(set) var suspendSelectors: [VMSelector] = []
    private(set) var restartSelectors: [VMSelector] = []
    private(set) var openSelectors: [VMSelector] = []
    private(set) var takeSnapshotCalls: [(selector: VMSelector, name: String, notes: String)] = []
    private(set) var renameCalls: [(selector: VMSelector, newName: String)] = []

    // MARK: - Error injection

    var infoError: (any Error)?
    var ipAddressError: (any Error)?
    var startError: (any Error)?
    var stopError: (any Error)?
    var pauseError: (any Error)?
    var resumeError: (any Error)?
    var suspendError: (any Error)?
    var restartError: (any Error)?
    var openError: (any Error)?
    var takeSnapshotError: (any Error)?

    /// Refuses `stop` until it is called with `confirmed: true`, then succeeds —
    /// the consent round trip every destructive verb performs.
    var stopConsentPrompt: ConfirmationPrompt?

    // MARK: - Events

    private let eventStream = AsyncStream<VMLibraryEvent>.makeStream()

    /// Publishes one library event to whoever is reading `events()`.
    func emit(_ event: VMLibraryEvent) {
        eventStream.continuation.yield(event)
    }

    // MARK: - Reads

    func list() -> [VMSummary] {
        listCallCount += 1
        return library
    }

    func info(_ selector: VMSelector) throws -> VMInfo {
        infoSelectors.append(selector)
        if let infoError { throw infoError }
        let summary = try resolve(selector)
        return VMInfo(
            id: summary.id,
            name: summary.name,
            status: summary.status,
            guestOS: "linux",
            cpuCount: 2,
            memoryBytes: 4 << 30,
            diskSizeInGB: 64,
            networkMode: nil,
            macAddress: nil,
            ipAddress: reservedAddress,
            agentStatus: "notInstalled",
            hasSavedState: false,
            isEphemeral: false,
            snapshotCount: 0,
            bundlePath: "/tmp/\(summary.id.uuidString).kernova")
    }

    func ipAddress(of selector: VMSelector) throws -> String? {
        ipAddressSelectors.append(selector)
        if let ipAddressError { throw ipAddressError }
        _ = try resolve(selector)
        return reservedAddress
    }

    func snapshots(of selector: VMSelector) throws -> [SnapshotSummary] {
        _ = try resolve(selector)
        return []
    }

    // MARK: - Lifecycle

    func start(_ selector: VMSelector, recovery: Bool) async throws {
        startCalls.append((selector, recovery))
        if let startError { throw startError }
    }

    func cancelGuestSetup(_ selector: VMSelector, confirmed: Bool) throws {}

    func stop(_ selector: VMSelector, disposition: StopDisposition, confirmed: Bool) async throws {
        stopCalls.append((selector, disposition, confirmed))
        if let stopError { throw stopError }
        if let stopConsentPrompt, !confirmed {
            throw CommandError.confirmationRequired(stopConsentPrompt)
        }
    }

    func pause(_ selector: VMSelector) async throws {
        pauseSelectors.append(selector)
        if let pauseError { throw pauseError }
    }

    func resume(_ selector: VMSelector) async throws {
        resumeSelectors.append(selector)
        if let resumeError { throw resumeError }
    }

    func suspend(_ selector: VMSelector) async throws {
        suspendSelectors.append(selector)
        if let suspendError { throw suspendError }
    }

    func restart(_ selector: VMSelector) async throws {
        restartSelectors.append(selector)
        if let restartError { throw restartError }
    }

    func open(_ selector: VMSelector) throws {
        openSelectors.append(selector)
        if let openError { throw openError }
    }

    // MARK: - Snapshots

    func takeSnapshot(_ selector: VMSelector, name: String, notes: String) async throws
        -> SnapshotSummary
    {
        takeSnapshotCalls.append((selector, name, notes))
        if let takeSnapshotError { throw takeSnapshotError }
        return snapshotToReturn
            ?? SnapshotSummary(
                id: UUID(), name: name, notes: notes, kind: "cold", createdAt: Date(),
                isCurrent: true, isEphemeralBaseline: false)
    }

    func revertToSnapshot(
        _ selector: VMSelector, snapshot: UUID, takingCheckpoint: Bool, confirmed: Bool
    ) async throws {}

    func deleteSnapshot(_ selector: VMSelector, snapshot: UUID, confirmed: Bool) async throws {}

    func renameSnapshot(_ selector: VMSelector, snapshot: UUID, to newName: String) throws {}

    func setSnapshotNotes(_ selector: VMSelector, snapshot: UUID, notes: String) throws {}

    // MARK: - Library

    func clone(_ selector: VMSelector, machineIdentity: CloneMachineIdentity) throws -> VMSummary {
        throw CommandError.unsupported(capability: "cloning")
    }

    func rename(_ selector: VMSelector, to newName: String) throws {
        renameCalls.append((selector, newName))
    }

    func delete(
        _ selector: VMSelector, permanently: Bool, alsoRemoving: Set<UUID>, confirmed: Bool
    ) async throws {}

    func importVM(from url: URL) throws -> VMSummary {
        throw CommandError.unsupported(capability: "importing")
    }

    func cancelPreparing(_ selector: VMSelector, confirmed: Bool) throws {}

    // MARK: - Observation

    /// One stream shared by every call, unlike the core's per-caller streams:
    /// the doubles here drive a single subscriber.
    func events() -> AsyncStream<VMLibraryEvent> { eventStream.stream }

    // MARK: - Resolution

    /// The one VM `selector` names, by the same rules the core follows.
    private func resolve(_ selector: VMSelector) throws -> VMSummary {
        let matches: [VMSummary] =
            switch selector {
            case .id(let id): library.filter { $0.id == id }
            case .name(let name): library.filter { $0.name == name }
            case .idOrName(let text):
                library.filter { $0.id.uuidString == text || $0.name == text }
            }
        guard let only = matches.first else { throw CommandError.notFound(selector) }
        guard matches.count == 1 else {
            throw CommandError.ambiguous(selector: selector, candidates: matches)
        }
        return only
    }
}
