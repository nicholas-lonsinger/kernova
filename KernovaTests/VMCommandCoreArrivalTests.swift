import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// A create, clone or import as the command core runs it: an arrival that is
/// no VM, whose outcome belongs to the call that waits on it — or, with nobody
/// waiting, to the unattended failure hook — and whose cancel is decided
/// before its rename.
@Suite("VMCommandCore arrivals", .serialized, .admissionGated)
@MainActor
struct VMCommandCoreArrivalTests {
    private let preferences = makeTestPreferences()
    private let storage = MockVMStorageService()

    private struct Harness {
        let core: VMCommandCore
        let library: VMLibrary
        let reports: Reports
        let virtualization: MockVirtualizationService
    }

    /// Every failure the core handed its unattended hook.
    private final class Reports {
        var failures: [CommandError] = []
        let changed = AsyncGate()
    }

    /// Every `.failure` event the core emitted.
    private final class EventLog {
        var failures: [(id: UUID, message: String)] = []
        let changed = AsyncGate()
    }

    private func makeHarness() -> Harness {
        let virtualization = MockVirtualizationService()
        let lifecycle = makeTestLifecycle(virtualization: virtualization)
        let library = makeWiredLibrary(
            storage: storage, lifecycle: lifecycle, preferences: preferences)
        let core = VMCommandCore(
            library: library,
            lifecycle: lifecycle,
            storageService: storage,
            diskImageService: MockDiskImageService(),
            fileSystem: MockFileSystem(),
            preferences: preferences)
        let reports = Reports()
        core.onFailure = { failure, _ in
            reports.failures.append(failure)
            reports.changed.notify()
        }
        return Harness(
            core: core, library: library, reports: reports, virtualization: virtualization)
    }

    private func makeSource(in harness: Harness) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: "Source", phase: .stopped, guestOS: .linux, library: harness.library,
            storage: storage, preferences: preferences)
    }

    /// Collects every `.failure` event from here on.
    private func recordFailureEvents(of core: VMCommandCore) -> (EventLog, Task<Void, Never>) {
        let log = EventLog()
        let stream = core.events()
        let task = Task {
            for await batch in stream {
                for case .failure(let id, _, let message) in batch {
                    log.failures.append((id, message))
                }
                log.changed.notify()
            }
        }
        return (log, task)
    }

    /// A bundle whose configuration reads, at a path with nothing on disk to
    /// copy — an import of it fails in the copy.
    private func unreadableSource() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArrivalTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Vanished.\(VMBundleFormat.fileExtension)", isDirectory: true)
        storage.files.seed(
            VMConfiguration(name: "Vanished", guestOS: .linux, bootMode: .efi),
            hostState: VMHostState(), snapshots: VMSnapshotManifest(),
            pairings: USBAccessoryPairingSet(), at: url)
        return url
    }

    private func isBusy(_ refusal: CommandError?) -> Bool {
        guard case .busy? = refusal else { return false }
        return true
    }

    // MARK: - R9: One Report per Failure

    @Test("A failed import with a waiter throws to the waiter and never reaches the report hook")
    func failedImportWithAWaiterThrowsToTheWaiterAndNeverReports() async throws {
        let harness = makeHarness()
        let (events, recording) = recordFailureEvents(of: harness.core)
        defer { recording.cancel() }

        await #expect(throws: CommandError.self) {
            try await harness.core.importVM(from: unreadableSource(), waitForOutcome: true)
        }

        #expect(harness.reports.failures.isEmpty)
        #expect(harness.library.entries.isEmpty)
        // Recorded as an event all the same: the event stream observes the
        // library, whoever the failure is reported to.
        try await events.changed.wait { events.failures.count == 1 }
    }

    @Test("A failed clone nobody waits on is reported once")
    func failedUnwaitedCloneReportsOnce() async throws {
        let harness = makeHarness()
        let source = makeSource(in: harness)
        let (events, recording) = recordFailureEvents(of: harness.core)
        defer { recording.cancel() }
        storage.cloneVMBundleError = CocoaError(.fileWriteOutOfSpace)

        let row = try await harness.core.clone(
            .id(source.id), machineIdentity: .new, waitForOutcome: false)
        #expect(row.status == VMStatus.preparingWireName)
        let arrival = try #require(harness.library.arrivals.first)
        await arrival.settle()

        try await harness.reports.changed.wait { !harness.reports.failures.isEmpty }
        try await events.changed.wait { !events.failures.isEmpty }
        #expect(harness.reports.failures.count == 1)
        #expect(events.failures.map(\.id) == [row.id])
    }

    @Test("A waiter that leaves before the outcome hands the failure to the report hook")
    func aWaiterThatLeavesBeforeTheOutcomeHandsTheFailureToReport() async throws {
        let harness = makeHarness()
        let source = makeSource(in: harness)
        let hold = DispatchSemaphore(value: 0)
        storage.cloneHold = hold

        let waiter = Task {
            try await harness.core.clone(.id(source.id), machineIdentity: .new, waitForOutcome: true)
        }
        try await storage.cloneEntered.wait { storage.cloneVMBundleCallCount == 1 }
        storage.cloneVMBundleError = CocoaError(.fileWriteOutOfSpace)
        waiter.cancel()
        hold.signal()

        await #expect(throws: CommandError.self) { try await waiter.value }
        try await harness.reports.changed.wait { harness.reports.failures.count == 1 }
    }

    @Test("A cancelled waited clone throws its cancel and reports nothing")
    func cancelledWaitedCloneThrowsCancelledAndNeverReports() async throws {
        let harness = makeHarness()
        let source = makeSource(in: harness)
        let hold = DispatchSemaphore(value: 0)
        storage.cloneHold = hold

        let waiter = Task {
            try await harness.core.clone(.id(source.id), machineIdentity: .new, waitForOutcome: true)
        }
        try await storage.cloneEntered.wait { storage.cloneVMBundleCallCount == 1 }
        let arrival = try #require(harness.library.arrivals.first)
        try harness.core.cancelPreparing(.id(arrival.id), confirmed: true)
        hold.signal()

        let outcome = await waiter.result
        guard case .failure(let error) = outcome,
            case .operationFailed(_, _, let message, _)? =
                error as? CommandError
        else {
            Issue.record("expected the clone's cancel, got \(outcome)")
            return
        }
        #expect(message.contains("cancelled"))
        #expect(harness.reports.failures.isEmpty)
        #expect(harness.library.instances.map(\.id) == [source.id])
        #expect(storage.publishBundleCallCount == 0)
        #expect(storage.discardedStagedURLs.count == 1)
    }

    // MARK: - F2: An Arrival Is Not a VM

    @Test("An arrival is not a VM: it lists, but every VM verb refuses it as busy")
    func anArrivalIsNotAVM() async throws {
        let harness = makeHarness()
        let source = makeSource(in: harness)
        let hold = DispatchSemaphore(value: 0)
        storage.cloneHold = hold
        defer { hold.signal() }

        let row = try await harness.core.clone(
            .id(source.id), machineIdentity: .new, waitForOutcome: false)
        let savesBefore = storage.saveConfigurationCallCount

        #expect(harness.library.instances.map(\.id) == [source.id])
        #expect(Set(harness.library.entries.map(\.id)) == [source.id, row.id])
        #expect(harness.core.list().map(\.status).contains(VMStatus.preparingWireName))
        #expect(try harness.core.info(.id(row.id)).status == VMStatus.preparingWireName)
        let renameRefusal = #expect(throws: CommandError.self) {
            try harness.core.rename(.id(row.id), to: "Renamed")
        }
        #expect(isBusy(renameRefusal))
        let writeRefusal = #expect(throws: CommandError.self) {
            try harness.core.setConfiguration(
                .id(row.id), assignments: [ConfigurationEntry(key: "name", value: "Renamed")],
                confirmed: true)
        }
        #expect(isBusy(writeRefusal))
        #expect(storage.saveConfigurationCallCount == savesBefore)
    }

    @Test("An arrival's address and snapshots refuse as busy")
    func ipAddressAndSnapshotsOnAnArrivalRefuseAsBusy() async throws {
        let harness = makeHarness()
        let source = makeSource(in: harness)
        let hold = DispatchSemaphore(value: 0)
        storage.cloneHold = hold
        defer { hold.signal() }

        let row = try await harness.core.clone(
            .id(source.id), machineIdentity: .new, waitForOutcome: false)

        let addressRefusal = #expect(throws: CommandError.self) {
            try harness.core.ipAddress(of: .id(row.id))
        }
        #expect(isBusy(addressRefusal))
        let snapshotsRefusal = #expect(throws: CommandError.self) {
            try harness.core.snapshots(of: .id(row.id))
        }
        #expect(isBusy(snapshotsRefusal))
    }

    // MARK: - F14: Cancel Around the Rename

    @Test("A cancel during the rename of a create that starts after creating trashes it and starts nothing")
    func aCancelDuringPublishingOfAStartingCreateTrashesItAndStartsNothing() async throws {
        let harness = makeHarness()
        let hold = DispatchSemaphore(value: 0)
        storage.publishHold = hold
        let configuration = VMConfiguration(name: "Withdrawn", guestOS: .linux, bootMode: .efi)
        let destination = try storage.bundleURL(for: configuration)

        let row = try harness.core.create(
            configuration: configuration, startAfterCreate: true, guestAccountPassword: nil)
        let arrival = try #require(harness.library.arrivals.first)
        try await storage.publishLanded.wait { storage.publishBundleCallCount == 1 }
        #expect(arrival.stage == .publishing)

        try harness.core.cancelPreparing(.id(row.id), confirmed: true)
        #expect(arrival.stage == .withdrawing)
        #expect(arrival.displayLabel == "Cancelling\u{2026}")
        hold.signal()

        // The auto-start chains off a VM the outcome delivers, and the outcome
        // is the cancel.
        await #expect(throws: CancellationError.self) { try await arrival.settled.value }
        #expect(storage.deleteVMBundleCallCount == 1)
        #expect(storage.bundleIdentity(at: destination) == nil)
        #expect(harness.library.entries.isEmpty)
        #expect(harness.virtualization.startCallCount == 0)
        #expect(harness.reports.failures.isEmpty)
    }

    @Test("A create publishing when the termination begins is adopted, and its start is refused unreported")
    func aCreatePublishingAtTerminationStartsNothing() async throws {
        let harness = makeHarness()
        let hold = DispatchSemaphore(value: 0)
        storage.publishHold = hold
        let configuration = VMConfiguration(name: "Quitting", guestOS: .linux, bootMode: .efi)

        try harness.core.create(
            configuration: configuration, startAfterCreate: true, guestAccountPassword: nil)
        let arrival = try #require(harness.library.arrivals.first)
        try await storage.publishLanded.wait { storage.publishBundleCallCount == 1 }
        #expect(arrival.stage == .publishing)

        harness.library.beginTermination()
        hold.signal()

        let instance = try #require(await arrival.settle())
        // The start-after-create follows the adoption on the main actor; once
        // the queue drains it has been decided.
        await drainMainQueue()
        #expect(instance.phase == .stopped)
        #expect(harness.virtualization.startCallCount == 0)
        #expect(harness.reports.failures.isEmpty)
    }

    @Test("A waiter on an arrival cancelled during its rename receives the cancel, not the VM")
    func aWaiterOnAnArrivalCancelledDuringItsRenameReceivesTheCancel() async throws {
        let harness = makeHarness()
        let source = makeSource(in: harness)
        let hold = DispatchSemaphore(value: 0)
        storage.publishHold = hold

        let waiter = Task {
            try await harness.core.clone(.id(source.id), machineIdentity: .new, waitForOutcome: true)
        }
        try await storage.publishLanded.wait { storage.publishBundleCallCount == 1 }
        let arrival = try #require(harness.library.arrivals.first)
        try harness.core.cancelPreparing(.id(arrival.id), confirmed: true)
        hold.signal()

        let outcome = await waiter.result
        guard case .failure(let error) = outcome,
            case .operationFailed(_, _, let message, _)? = error as? CommandError
        else {
            Issue.record("expected the clone's cancel, got \(outcome)")
            return
        }
        #expect(message == "The clone was cancelled.")
        #expect(storage.deleteVMBundleCallCount == 1)
        #expect(harness.library.instances.map(\.id) == [source.id])
        #expect(harness.reports.failures.isEmpty)
    }

    @Test("A cancel during the rename whose trash fails keeps the VM and reports the failure once")
    func aCancelDuringTheRenameWhoseTrashFailsKeepsTheVM() async throws {
        let harness = makeHarness()
        let source = makeSource(in: harness)
        let hold = DispatchSemaphore(value: 0)
        storage.publishHold = hold
        storage.deleteVMBundleError = CocoaError(.fileWriteNoPermission)

        let row = try await harness.core.clone(
            .id(source.id), machineIdentity: .new, waitForOutcome: false)
        let arrival = try #require(harness.library.arrivals.first)
        try await storage.publishLanded.wait { storage.publishBundleCallCount == 1 }

        try harness.core.cancelPreparing(.id(row.id), confirmed: true)
        hold.signal()

        // The bundle the Trash turned down is still in the VMs directory, so
        // it is the VM it now is, and nothing follows the arrival with it.
        #expect(await arrival.settle() == nil)
        #expect(storage.deleteVMBundleCallCount == 1)
        #expect(Set(harness.library.instances.map(\.id)) == [source.id, row.id])
        #expect(harness.library.arrivals.isEmpty)
        try await harness.reports.changed.wait { harness.reports.failures.count == 1 }
    }

    @Test("A cancel that arrives after adoption is refused and deletes nothing")
    func aCancelAfterAdoptionIsRefusedAndDeletesNothing() async throws {
        let harness = makeHarness()
        let source = makeSource(in: harness)
        let clone = try await harness.core.clone(
            .id(source.id), machineIdentity: .new, waitForOutcome: true)
        #expect(clone.status == VMStatus.stopped.rawValue)

        do {
            try harness.core.cancelPreparing(.id(clone.id), confirmed: true)
            Issue.record("expected the cancel to be refused")
        } catch let refusal as CommandError {
            guard case .invalidState = refusal else {
                Issue.record("expected an invalid-state refusal, got \(refusal)")
                return
            }
        }
        #expect(storage.deleteVMBundleCallCount == 0)
        #expect(Set(harness.library.instances.map(\.id)) == [source.id, clone.id])
    }
}
