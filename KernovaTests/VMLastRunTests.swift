import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// When a VM last ran (``VMHostState/lastRunAt``) and when its session started
/// running (``VMSessionContext/runningSince``): written as a session first
/// settles running and again as it ends, however it ends.
@Suite("VM Last Run Tests", .serialized, .caseScoped)
@MainActor
struct VMLastRunTests {
    private struct Probe: Error {}

    /// A long-past moment, standing in for an earlier run's record so a later
    /// write is visible even within the second the encoding keeps.
    private static let earlier = Date(timeIntervalSince1970: 1_000_000_000)

    /// `date` as the host-state file keeps it: to the second.
    private func toTheSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// Cold-boots `instance` into a running session `session` through a real
    /// bring-up, as the start path opens and binds one.
    private func bootRunning(_ instance: VMInstance, session: UUID) async throws {
        try await instance.activity.launchAnyBringUp(.guestStart(.starting(recovery: false))) { context in
            instance.beginSessionContextForTesting()
            context.bindSessionForTesting(session)
            return .rest(.live(.running), ())
        }.value()
    }

    /// Writes `date` over the VM's last run, as an earlier session left it.
    private func backdate(_ instance: VMInstance, to date: Date) throws {
        try instance.activity.edit(.observations) { permit in
            _ = permit.updateSettings(configuration: { _ in }, hostState: { $0.lastRunAt = date })
        }
        #expect(instance.hostState.lastRunAt == date)
    }

    @Test("A VM with no run recorded has no last run")
    func noRunRecordedHasNoLastRun() {
        let library = makeWiredLibrary()
        let instance = library.registerFixture()

        #expect(instance.hostState.lastRunAt == nil)
        #expect(instance.sessionContext?.runningSince == nil)
    }

    @Test("A session records when it started running, as the last run too, as it first settles running")
    func startRecordsTheLastRun() async throws {
        let library = makeWiredLibrary()
        let instance = library.registerFixture()
        let before = toTheSecond(Date())

        try await bootRunning(instance, session: UUID())

        let since = try #require(instance.sessionContext?.runningSince)
        #expect(since >= before)
        let recorded = try #require(instance.hostState.lastRunAt)
        #expect(recorded >= before && recorded <= since)
    }

    @Test("A pause and resume keep the session's start and write no run")
    func resumeKeepsTheSessionStart() async throws {
        let library = makeWiredLibrary()
        let instance = library.registerFixture()
        try await bootRunning(instance, session: UUID())
        let since = try #require(instance.sessionContext?.runningSince)
        try backdate(instance, to: Self.earlier)

        try await instance.activity.launch(.pausing) { _ in .rest(.live(.paused), ()) }.value()
        try await instance.activity.launch(.resuming) { _ in .rest(.live(.running), ()) }.value()

        #expect(instance.sessionContext?.runningSince == since)
        #expect(instance.hostState.lastRunAt == Self.earlier)
    }

    @Test("A session that ends — powered off or stopped with an error — records the last run as it ends")
    func settledEndRecordsTheLastRun() async throws {
        for event in [VMSessionEvent.guestDidStop, .didStopWithError(Probe())] {
            let library = makeWiredLibrary()
            let instance = library.registerFixture()
            let session = UUID()
            try await bootRunning(instance, session: session)
            try backdate(instance, to: Self.earlier)
            let before = toTheSecond(Date())

            instance.activity.deliverSessionEvent(event, from: session)

            #expect(instance.sessionContext == nil)
            #expect(instance.sessionContext?.runningSince == nil)
            let recorded = try #require(instance.hostState.lastRunAt, "\(event)")
            #expect(recorded >= before, "\(event)")
        }
    }

    @Test("A save that ends its session records the last run as it ends")
    func saveRecordsTheLastRun() async throws {
        let library = makeWiredLibrary()
        let instance = library.registerFixture()
        try await bootRunning(instance, session: UUID())
        try backdate(instance, to: Self.earlier)
        let before = toTheSecond(Date())

        try await instance.activity.launch(.saving) { context in
            context.endSession()
            return .rest(.afterSessionEnd, ())
        }.value()

        #expect(instance.sessionContext == nil)
        let recorded = try #require(instance.hostState.lastRunAt)
        #expect(recorded >= before)
    }

    @Test("A session that never settled running records no run")
    func failedBringUpRecordsNoRun() async throws {
        let library = makeWiredLibrary()
        let instance = library.registerFixture()

        await #expect(throws: Probe.self) {
            try await instance.activity.launchAnyBringUp(.guestStart(.starting(recovery: false))) { context in
                instance.beginSessionContextForTesting()
                context.bindSessionForTesting(UUID())
                throw Probe()
            }.value()
        }

        #expect(instance.sessionContext == nil)
        #expect(instance.hostState.lastRunAt == nil)
    }
}
