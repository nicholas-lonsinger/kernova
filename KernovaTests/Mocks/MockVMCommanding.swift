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
    /// What `info` answers for a VM, overriding the value synthesized from its
    /// summary — for tests that vary a field the library alone doesn't carry.
    var infoByID: [UUID: VMInfo] = [:]
    /// What `snapshots(of:)` answers per VM.
    var snapshotsByVM: [UUID: [SnapshotSummary]] = [:]
    /// The row `clone` answers with, synthesized from the source when unset.
    var cloneResult: VMSummary?

    // MARK: - Recorded calls

    private(set) var listCallCount = 0
    private(set) var infoSelectors: [VMSelector] = []
    private(set) var ipAddressSelectors: [VMSelector] = []
    private(set) var snapshotsSelectors: [VMSelector] = []
    private(set) var startCalls: [(selector: VMSelector, recovery: Bool)] = []
    private(set) var stopCalls: [(selector: VMSelector, disposition: StopDisposition, confirmed: Bool)] =
        []
    private(set) var pauseSelectors: [VMSelector] = []
    private(set) var resumeSelectors: [VMSelector] = []
    private(set) var suspendSelectors: [VMSelector] = []
    private(set) var restartSelectors: [VMSelector] = []
    private(set) var openSelectors: [VMSelector] = []
    private(set) var cancelGuestSetupCalls: [(selector: VMSelector, confirmed: Bool)] = []
    private(set) var takeSnapshotCalls: [(selector: VMSelector, name: String, notes: String)] = []
    private(set) var revertCalls: [(selector: VMSelector, snapshot: UUID, takingCheckpoint: Bool, confirmed: Bool)] = []
    private(set) var deleteSnapshotCalls: [(selector: VMSelector, snapshot: UUID, confirmed: Bool)] =
        []
    private(set) var renameSnapshotCalls: [(selector: VMSelector, snapshot: UUID, newName: String)] =
        []
    private(set) var setSnapshotNotesCalls: [(selector: VMSelector, snapshot: UUID, notes: String)] =
        []
    private(set) var createCalls: [(configuration: VMConfiguration, startAfterCreate: Bool)] = []
    private(set) var cloneCalls: [(selector: VMSelector, machineIdentity: CloneMachineIdentity)] = []
    private(set) var renameCalls: [(selector: VMSelector, newName: String)] = []
    private(set) var deleteCalls:
        [(selector: VMSelector, permanently: Bool, alsoRemoving: Set<UUID>, confirmed: Bool)] = []
    private(set) var cancelPreparingCalls: [(selector: VMSelector, confirmed: Bool)] = []

    // MARK: - Error injection

    var infoError: (any Error)?
    var ipAddressError: (any Error)?
    var snapshotsError: (any Error)?
    var startError: (any Error)?
    var stopError: (any Error)?
    var pauseError: (any Error)?
    var resumeError: (any Error)?
    var suspendError: (any Error)?
    var restartError: (any Error)?
    var openError: (any Error)?
    var cancelGuestSetupError: (any Error)?
    var takeSnapshotError: (any Error)?
    var revertError: (any Error)?
    var deleteSnapshotError: (any Error)?
    var renameSnapshotError: (any Error)?
    var setSnapshotNotesError: (any Error)?
    var createError: (any Error)?
    var cloneError: (any Error)?
    var renameError: (any Error)?
    var deleteError: (any Error)?
    var cancelPreparingError: (any Error)?

    /// Refuses `stop` until it is called with `confirmed: true`, then succeeds —
    /// the consent round trip every destructive verb performs.
    var stopConsentPrompt: ConfirmationPrompt?
    /// The same round trip for `revertToSnapshot`.
    var revertConsentPrompt: ConfirmationPrompt?
    /// The same round trip for `deleteSnapshot`.
    var deleteSnapshotConsentPrompt: ConfirmationPrompt?
    /// The same round trip for `delete`.
    var deleteConsentPrompt: ConfirmationPrompt?
    /// The same round trip for `cancelPreparing`.
    var cancelPreparingConsentPrompt: ConfirmationPrompt?
    /// The same round trip for `cancelGuestSetup`.
    var cancelGuestSetupConsentPrompt: ConfirmationPrompt?

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
        if let seeded = infoByID[summary.id] { return seeded }
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
        snapshotsSelectors.append(selector)
        if let snapshotsError { throw snapshotsError }
        return snapshotsByVM[try resolve(selector).id] ?? []
    }

    // MARK: - Lifecycle

    func start(_ selector: VMSelector, recovery: Bool) async throws {
        startCalls.append((selector, recovery))
        if let startError { throw startError }
    }

    func cancelGuestSetup(_ selector: VMSelector, confirmed: Bool) throws {
        cancelGuestSetupCalls.append((selector, confirmed))
        if let cancelGuestSetupError { throw cancelGuestSetupError }
        if let cancelGuestSetupConsentPrompt, !confirmed {
            throw CommandError.confirmationRequired(cancelGuestSetupConsentPrompt)
        }
    }

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
    ) async throws {
        revertCalls.append((selector, snapshot, takingCheckpoint, confirmed))
        if let revertError { throw revertError }
        if let revertConsentPrompt, !confirmed {
            throw CommandError.confirmationRequired(revertConsentPrompt)
        }
    }

    func deleteSnapshot(_ selector: VMSelector, snapshot: UUID, confirmed: Bool) async throws {
        deleteSnapshotCalls.append((selector, snapshot, confirmed))
        if let deleteSnapshotError { throw deleteSnapshotError }
        if let deleteSnapshotConsentPrompt, !confirmed {
            throw CommandError.confirmationRequired(deleteSnapshotConsentPrompt)
        }
    }

    func renameSnapshot(_ selector: VMSelector, snapshot: UUID, to newName: String) throws {
        renameSnapshotCalls.append((selector, snapshot, newName))
        if let renameSnapshotError { throw renameSnapshotError }
    }

    func setSnapshotNotes(_ selector: VMSelector, snapshot: UUID, notes: String) throws {
        setSnapshotNotesCalls.append((selector, snapshot, notes))
        if let setSnapshotNotesError { throw setSnapshotNotesError }
    }

    // MARK: - Library

    func create(configuration: VMConfiguration, startAfterCreate: Bool) throws -> VMSummary {
        createCalls.append((configuration, startAfterCreate))
        if let createError { throw createError }
        // The core registers the new VM's phantom row before answering, so a
        // caller that reads it back on the same turn finds it.
        let created = VMSummary(
            id: configuration.id, name: configuration.name,
            status: VMCommandCore.preparingWireStatus)
        library.append(created)
        return created
    }

    func clone(_ selector: VMSelector, machineIdentity: CloneMachineIdentity) throws -> VMSummary {
        cloneCalls.append((selector, machineIdentity))
        if let cloneError { throw cloneError }
        let source = try resolve(selector)
        let copy =
            cloneResult
            ?? VMSummary(id: UUID(), name: "\(source.name) copy", status: source.status)
        // The core registers the copy's phantom row before answering, so a
        // caller that reads it back on the same turn finds it.
        library.append(copy)
        return copy
    }

    func rename(_ selector: VMSelector, to newName: String) throws {
        renameCalls.append((selector, newName))
        if let renameError { throw renameError }
    }

    func delete(
        _ selector: VMSelector, permanently: Bool, alsoRemoving: Set<UUID>, confirmed: Bool
    ) async throws {
        deleteCalls.append((selector, permanently, alsoRemoving, confirmed))
        if let deleteError { throw deleteError }
        if let deleteConsentPrompt, !confirmed {
            throw CommandError.confirmationRequired(deleteConsentPrompt)
        }
    }

    func importVM(from url: URL) throws -> VMSummary {
        throw CommandError.unsupported(capability: "importing")
    }

    func cancelPreparing(_ selector: VMSelector, confirmed: Bool) throws {
        cancelPreparingCalls.append((selector, confirmed))
        if let cancelPreparingError { throw cancelPreparingError }
        if let cancelPreparingConsentPrompt, !confirmed {
            throw CommandError.confirmationRequired(cancelPreparingConsentPrompt)
        }
    }

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
