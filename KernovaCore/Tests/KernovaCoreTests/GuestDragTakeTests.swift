import Foundation
import KernovaAgentCore
import KernovaKit
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Observation
import Testing
import UniformTypeIdentifiers

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// A take of a guest's drag over: the press it withholds until the guest's
/// catcher is the drag's target, the release it injects only then, the writes a
/// Mac destination asks for, each a pull into the promise's own place, and the
/// offer's release once nothing will pull again.
@Suite("GuestDragTake", .caseScoped)
@MainActor
struct GuestDragTakeTests {
    // MARK: - Doubles

    /// What a take asked the display to do.
    enum DisplayCall: Equatable {
        case nudge(GuestDragNudge)
        case returnToExit
        case beginSession
        case release
        case resumeTracking
    }

    /// A display that records what the take asks of it.
    @MainActor
    final class RecordingDisplay: GuestDragDisplay {
        private(set) var calls: [DisplayCall] = []
        var sessionBegins = true

        func injectNudge(_ nudge: GuestDragNudge) { calls.append(.nudge(nudge)) }
        func returnToExitPoint() { calls.append(.returnToExit) }
        func injectRelease() { calls.append(.release) }
        func resumeTracking() { calls.append(.resumeTracking) }

        func beginHostSession(carrying take: any GuestDragTaking) -> Bool {
            calls.append(.beginSession)
            return sessionBegins
        }
    }

    /// The guest's side as the take reaches it: each call recorded, each end
    /// the test's to deliver.
    @MainActor
    final class FakeTransport: GuestDragTransport {
        struct Pull {
            let index: Int
            let directory: URL
            let name: String
            let ended: @MainActor (Result<Void, WireError>) -> Void
            var cancelled = false
        }

        private(set) var takeEnded: (@MainActor (DragTakeResult) -> Void)?
        private(set) var pulls: [Pull] = []
        private(set) var releases = 0
        let changed = AsyncGate()

        func take(ended: @escaping @MainActor (DragTakeResult) -> Void) {
            takeEnded = ended
        }

        func pull(
            _ item: DraggedOutItem, at index: Int, into directory: URL, named name: String,
            ended: @escaping @MainActor (Result<Void, WireError>) -> Void
        ) -> @MainActor () -> Void {
            let position = pulls.count
            pulls.append(Pull(index: index, directory: directory, name: name, ended: ended))
            changed.notify()
            return { [weak self] in self?.pulls[position].cancelled = true }
        }

        func release() {
            releases += 1
        }

        /// Ends pull `position` with `result`.
        func end(_ position: Int, _ result: Result<Void, WireError>) {
            pulls[position].ended(result)
        }
    }

    /// The condition a take holds under, standing in for the VM's status.
    @MainActor
    @Observable
    final class RunningFlag {
        var isRunning = true
    }

    /// How many times the take reported itself finished.
    @MainActor
    final class FinishedFlag {
        var count = 0
    }

    private let display = RecordingDisplay()
    private let transport = FakeTransport()
    private let running = RunningFlag()
    private let finished = FinishedFlag()

    private static let items = [
        DraggedOutItem(name: Data("a.txt".utf8), type: .plainText, isDirectory: false, sizeEstimate: 4),
        DraggedOutItem(name: Data("Folder".utf8), type: .folder, isDirectory: true),
    ]

    private func makeTake(items: [DraggedOutItem] = Self.items) -> GuestDragTake {
        let running = running
        let finished = finished
        let take = GuestDragTake(
            items: items, transport: transport, display: display, reporter: ClipboardTransferReporter(),
            peerName: "Test VM", holds: { running.isRunning }, onFinished: { _ in finished.count += 1 })
        take.begin()
        return take
    }

    /// Hands the take the guest's answer `result`.
    private func answerTake(_ result: DragTakeResult) throws {
        let ended = try #require(transport.takeEnded)
        ended(result)
    }

    /// A take the guest has answered `TAKEN`.
    private func readyTake() throws -> GuestDragTake {
        let take = makeTake()
        try answerTake(.taken)
        try #require(take.phase == .ready)
        return take
    }

    /// A take a Mac session carries, which a destination took.
    private func droppedTake() throws -> GuestDragTake {
        let take = try readyTake()
        take.withheldDrag()
        try #require(take.phase == .carried)
        take.hostSessionEnded(dropped: true)
        return take
    }

    /// Writes item `index` to `destination` and returns the write's outcome
    /// once `end` ends its pull.
    private func write(
        _ take: GuestDragTake, item index: Int, to destination: URL,
        ending end: (FakeTransport) throws -> Void = { _ in }
    ) async throws -> (any Error)? {
        let pulls = transport.pulls.count
        let outcome = OutcomeBox(gate: transport.changed)
        take.writeItem(at: index, to: destination) { error in outcome.set(error) }
        try await transport.changed.wait { transport.pulls.count > pulls || outcome.isSet }
        try end(transport)
        try await transport.changed.wait { outcome.isSet }
        return outcome.error
    }

    /// One write's outcome, announced on `gate`.
    final class OutcomeBox: Sendable {
        private let state = Locked<(set: Bool, error: (any Error)?)>((false, nil))
        private let changed: AsyncGate

        init(gate: AsyncGate) { changed = gate }

        var isSet: Bool { state.withLock { $0.set } }
        var error: (any Error)? { state.withLock { $0.error } }

        func set(_ error: (any Error)?) {
            state.withLock { $0 = (true, error) }
            changed.notify()
        }
    }

    // MARK: - The hand-off

    @Test("the press is nudged until the guest takes the drag; the session then releases onto the catcher")
    func handOffThenSession() throws {
        let take = makeTake()
        take.withheldDrag()
        take.withheldDrag()
        #expect(display.calls == [.nudge(.exitPoint), .nudge(.offset)])

        try answerTake(.taken)
        #expect(take.phase == .ready)
        take.withheldDrag()

        #expect(take.phase == .carried)
        #expect(display.calls.suffix(2) == [.beginSession, .release])
        #expect(transport.releases == 0)
    }

    @Test("a refused take hands the press back, looking again for a drag, and injects no release")
    func refusedTakeHandsBack() throws {
        let take = makeTake()
        try answerTake(.refused(WireError(.dragPressOver)))

        #expect(take.phase == .abandoned)
        #expect(display.calls == [.returnToExit, .resumeTracking])
        #expect(transport.releases == 1)
        #expect(finished.count == 1)
    }

    @Test("the button coming up before the guest takes the drag hands it back")
    func earlyMouseUpHandsBack() {
        let take = makeTake()
        take.withheldMouseUp()

        #expect(take.phase == .abandoned)
        #expect(!display.calls.contains(.release))
        // Releasing the offer is what refuses the take still out.
        #expect(transport.releases == 1)
    }

    @Test("the button coming up once the guest took the drag releases onto the catcher and completes the drag")
    func readyMouseUpReleases() throws {
        let take = try readyTake()
        take.withheldMouseUp()

        #expect(take.phase == .released)
        #expect(display.calls == [.release])
        #expect(transport.releases == 1)
        #expect(finished.count == 1)
    }

    @Test("a Mac session that does not begin releases onto the catcher")
    func sessionThatDoesNotBeginReleases() throws {
        display.sessionBegins = false
        let take = try readyTake()
        take.withheldDrag()

        #expect(take.phase == .released)
        #expect(display.calls == [.beginSession, .release])
        #expect(transport.releases == 1)
    }

    @Test("the VM stopping mid-hand-off hands the press back")
    func vmStopAbandons() async throws {
        let take = makeTake()
        running.isRunning = false

        try await waitForChange { take.phase == .abandoned }
        #expect(display.calls == [.returnToExit, .resumeTracking])
    }

    @Test("the guest's offer ending mid-hand-off hands the press back without releasing it again")
    func offerEndHandsBack() {
        let take = makeTake()
        take.offerEnded()

        #expect(take.phase == .abandoned)
        #expect(transport.releases == 0)
        #expect(finished.count == 1)
    }

    // MARK: - Completing the drag

    @Test("a session that ends with nothing taking it completes the drag at once")
    func undroppedSessionCompletes() throws {
        let take = try readyTake()
        take.withheldDrag()
        take.hostSessionEnded(dropped: false)

        #expect(transport.releases == 1)
        #expect(finished.count == 1)
    }

    @Test("a dropped session holds the offer until every item is written, then releases it")
    func releaseFollowsTheLastWrite() async throws {
        let take = try droppedTake()
        let folder = URL(fileURLWithPath: "/Volumes/Exchange/Inbox", isDirectory: true)

        let first = try await write(take, item: 0, to: folder.appendingPathComponent("a.txt")) {
            $0.end(0, .success(()))
        }
        #expect(first == nil)
        #expect(transport.releases == 0)

        let second = try await write(take, item: 1, to: folder.appendingPathComponent("Folder 2")) {
            $0.end(1, .success(()))
        }
        #expect(second == nil)
        #expect(transport.releases == 1)
        #expect(finished.count == 1)
    }

    // MARK: - Writing items

    @Test("a promise is filled by a pull into the promise URL's directory under exactly its name")
    func writePullsIntoThePromiseURL() async throws {
        let take = try droppedTake()
        let destination = URL(fileURLWithPath: "/Users/me/Desktop/a 2.txt")

        let outcome = try await write(take, item: 0, to: destination) { $0.end(0, .success(())) }

        #expect(outcome == nil)
        let pull = try #require(transport.pulls.first)
        #expect(pull.index == 0)
        #expect(pull.directory.path == "/Users/me/Desktop")
        #expect(pull.name == "a 2.txt")
    }

    @Test("a destination is told each item by the name the guest offered it under")
    func filenamesAreTheOffersNames() throws {
        let take = try droppedTake()
        #expect(take.filename(forItemAt: 0) == "a.txt")
        #expect(take.filename(forItemAt: 1) == "Folder")
    }

    @Test("a failed pull fails its write and every write after it")
    func failedPullEndsTheWrites() async throws {
        let take = try droppedTake()
        let folder = URL(fileURLWithPath: "/tmp/drag-out", isDirectory: true)

        let failed = try await write(take, item: 0, to: folder.appendingPathComponent("a.txt")) {
            $0.end(0, .failure(WireError(.itemRepresentationUnavailable)))
        }
        #expect(failed as? GuestDragWriteError == .failed(.peerReported(.dragItemUnavailable)))

        let after = try await write(take, item: 1, to: folder.appendingPathComponent("Folder"))
        #expect(after as? GuestDragWriteError == .failed(.peerReported(.dragItemUnavailable)))
        #expect(transport.pulls.count == 1)
        #expect(transport.releases == 1)
    }

    @Test("the offer ending mid-write cancels the pull, and the write fails interrupted")
    func offerEndInterruptsTheWrite() async throws {
        let take = try droppedTake()
        let destination = URL(fileURLWithPath: "/tmp/drag-out/a.txt")

        let outcome = try await write(take, item: 0, to: destination) { transport in
            take.offerEnded()
            #expect(transport.pulls[0].cancelled)
            transport.end(0, .failure(WireError(.cancelled)))
        }

        #expect(outcome as? GuestDragWriteError == .failed(.interrupted(fileCount: 2)))
        #expect(transport.releases == 0)
        #expect(finished.count == 1)
    }

    @Test("no item is written before a Mac session carries the drag")
    func noWriteBeforeTheSession() async throws {
        let take = try readyTake()
        let outcome = try await write(take, item: 0, to: URL(fileURLWithPath: "/tmp/drag-out/a.txt"))

        #expect(outcome as? GuestDragWriteError == .failed(.transferFailed))
        #expect(transport.pulls.isEmpty)
    }

    @Test("a pull's error says what the readout reports")
    func failureMapping() {
        #expect(GuestDragTake.failure(for: WireError(.itemOfferStale), owed: 3) == .interrupted(fileCount: 3))
        #expect(
            GuestDragTake.failure(for: WireError(.writeFailed, posixErrno: ENOSPC), owed: 1)
                == .diskFull(needed: nil, available: nil))
        #expect(GuestDragTake.failure(for: WireError(.writeFailed), owed: 1) == .stagingFailed)
        #expect(GuestDragTake.failure(for: WireError(.readFailed), owed: 1) == .sourceUnreadable(nil))
    }
}
