import Foundation
import Testing
import KernovaTestSupport

@testable import KernovaKit

@Suite("LazyPullCoordinator", .admissionGated)
struct LazyPullCoordinatorTests {
    // RATIONALE: sanctioned no-signal polls (docs/TESTING.md "Async waits in
    // tests") — `pendingSlotCountForTesting` and `waiterCountForTesting` are
    // NSLock-guarded SUT state, not @Observable, and neither slot nor waiter
    // registration publishes anything a test could arm on. Stated once for the
    // suite: every poll below is one of these two reads.

    /// A `Sendable` slot to ferry a representation out of an off-actor awaiter
    /// closure.
    private final class RepBox: @unchecked Sendable {
        private let lock = NSLock()
        private var rep: ClipboardContent.Representation?
        private var abort: ClipboardStreamAbortInfo?
        func setRep(_ r: ClipboardContent.Representation) { lock.withLock { rep = r } }
        func setAbort(_ a: ClipboardStreamAbortInfo) { lock.withLock { abort = a } }
        var representation: ClipboardContent.Representation? { lock.withLock { rep } }
        var abortInfo: ClipboardStreamAbortInfo? { lock.withLock { abort } }
    }

    /// A `Sendable` tally for off-actor `onProgress` callbacks that also captures
    /// the latest `(bytes, total)` and whether the byte counts were monotonic.
    private final class ProgressCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var lastBytes = 0
        private var lastTotalBytes = 0
        private var monotonic = true
        func bump(bytes: Int, total: Int) {
            lock.withLock {
                if bytes < lastBytes { monotonic = false }
                count += 1
                lastBytes = bytes
                lastTotalBytes = total
            }
        }
        var value: Int { lock.withLock { count } }
        var lastBytesReceived: Int { lock.withLock { lastBytes } }
        var lastTotal: Int { lock.withLock { lastTotalBytes } }
        var isMonotonic: Bool { lock.withLock { monotonic } }
    }

    /// A `Sendable` call counter for a closure two joining pulls share.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    /// A `Sendable` log of labelled steps, for a test asserting the order two
    /// closures ran in.
    private final class OrderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [String] = []
        func record(_ step: String) { lock.withLock { steps.append(step) } }
        var entries: [String] { lock.withLock { steps } }
    }

    /// Runs the blocking `pull` on a dedicated thread so the test's
    /// cooperative thread stays free to deliver/abort/failAll and `await` the
    /// outcome.
    ///
    /// `pull` blocks its thread on a semaphore for up to `timeout`. A
    /// dedicated `Thread` — not `DispatchQueue.global()` — draws from no
    /// shared pool: Swift Testing runs this suite's tests in parallel, so the
    /// suite's ~15 concurrent blocking pulls would otherwise park shared
    /// global-pool workers at once, and GCD throttles new-worker creation
    /// under saturation. A freshly dispatched `pull` then can't get a thread
    /// within a sibling's `waitUntil` window, its slot never registers, and
    /// the whole cluster times out together — a starvation cascade that
    /// self-reinforces (each test's deliver/abort/failAll, which would free a
    /// worker, is gated behind the very `waitUntil` that's timing out) and
    /// survives the automatic retry (#578).
    ///
    /// That semaphore is a raw backstop the stopwatch helpers never see, so
    /// this arms the test session's OS activity itself. `timeout` is a
    /// *competing* clock rather than a stuck-condition one: the slot's backstop
    /// timer latches `.timedOut` and deregisters the slot, so a runner stall that
    /// outlasts the window turns a sound expectation into a failure.
    private func runPull(
        _ coordinator: LazyPullCoordinator,
        transferID: UInt64,
        timeout: TimeInterval = testWaitBackstop,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil,
        retire: @escaping @Sendable () -> Void = {},
        start: @escaping @Sendable () -> Void = {}
    ) async -> LazyPullOutcome {
        armTestSessionActivity()
        return await withCheckedContinuation { (cont: CheckedContinuation<LazyPullOutcome, Never>) in
            let thread = Thread {
                cont.resume(
                    returning: coordinator.pull(
                        transferID: transferID, timeout: timeout, onProgress: onProgress,
                        retire: retire, start: start))
            }
            thread.name = "LazyPullCoordinatorTests.runPull(\(transferID))"
            thread.start()
        }
    }

    private func inlineRep(_ text: String) -> ClipboardContent.Representation {
        ClipboardContent.Representation(uti: ClipboardContent.utf8TextUTI, data: Data(text.utf8))
    }

    // MARK: - The main thread is never parked

    @Test("a main-thread pull with no event loop available is refused, not parked")
    @MainActor
    func mainThreadPullWithoutEventLoopIsRefused() {
        // The seam stands in for the tracking or modal loop this bundle cannot
        // enter, so the answer does not depend on whether the host happens to
        // have an `NSApplication`. Parking here is what used to freeze the main
        // thread for the length of a transfer (docs/CLIPBOARD.md §8); the
        // app-hosted counterpart proving the served wait still wins is
        // `LazyPullCoordinatorMainThreadTests`.
        NestedEventLoopWait.declinesForTesting = true
        defer { NestedEventLoopWait.declinesForTesting = false }
        let coordinator = LazyPullCoordinator()
        let starts = Tally()

        // The refusal is immediate, so no timeout of this call's is ever read
        // and the main thread is held for nothing — the hostage-window rule in
        // docs/TESTING.md has nothing to bound here.
        let outcome = coordinator.pull(
            transferID: 77, timeout: testWaitBackstop, retire: {}, start: { starts.bump() })

        guard case .mainThreadUnavailable = outcome else {
            Issue.record("Expected .mainThreadUnavailable, got \(outcome)")
            return
        }
        // Refused before anything was registered: no awaiter to retire, no
        // request on the wire, and no slot left behind for the next pull.
        #expect(starts.value == 0)
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    // MARK: - Slot machinery

    @Test("pull blocks until deliver wakes it with the representation")
    func deliverWakesPull() async throws {
        let coordinator = LazyPullCoordinator()
        async let outcome = runPull(coordinator, transferID: 7)
        try await waitUntil { coordinator.pendingSlotCountForTesting == 1 }
        coordinator.deliver(7, inlineRep("hello"))

        guard case .delivered(let rep) = await outcome else {
            Issue.record("Expected .delivered")
            return
        }
        #expect(rep.inMemoryData == Data("hello".utf8))
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("pull surfaces an abort delivered while it waits")
    func abortWakesPull() async throws {
        let coordinator = LazyPullCoordinator()
        async let outcome = runPull(coordinator, transferID: 3)
        try await waitUntil { coordinator.pendingSlotCountForTesting == 1 }
        coordinator.abort(
            3,
            ClipboardStreamAbortInfo(
                transferID: 3, code: .diskFull, message: "no space",
                neededBytes: 10, availableBytes: 1))

        guard case .aborted(let info) = await outcome else {
            Issue.record("Expected .aborted")
            return
        }
        #expect(info.code == .diskFull)
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("pull times out when no outcome is delivered")
    func pullTimesOut() async throws {
        let coordinator = LazyPullCoordinator()
        let outcome = await runPull(coordinator, transferID: 5, timeout: 0.12)
        guard case .timedOut = outcome else {
            Issue.record("Expected .timedOut, got \(outcome)")
            return
        }
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("progress re-arms the inactivity window so a slow-but-live pull is not timed out")
    func progressReArmsTheBackstop() async throws {
        // Drives the window boundary through the seam instead of a real
        // wall-clock wait, so the test proves the re-arm branch fires
        // deterministically — not that a producer happens to beat a real timer
        // on a shared CI runner (#571: the prior version raced real time and
        // flaked under scheduler jitter).
        let coordinator = LazyPullCoordinator()
        async let outcome = runPull(coordinator, transferID: 11)
        try await waitUntil { coordinator.pendingSlotCountForTesting == 1 }

        coordinator.progress(11, bytesReceived: 4096, totalBytes: 1 << 20)
        // The window that saw the chunk re-arms rather than giving the pull up
        // (#500 — a slow-but-live transfer must not time out).
        coordinator.elapseBackstopWindowForTesting(11)
        #expect(coordinator.pendingSlotCountForTesting == 1)

        coordinator.deliver(11, inlineRep("slow but alive"))
        guard case .delivered(let rep) = await outcome else {
            Issue.record("Expected .delivered — progress should have prevented the timeout")
            return
        }
        #expect(rep.inMemoryData == Data("slow but alive".utf8))
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("a window that saw no chunk gives the pull up")
    func idleBackstopWindowTimesOut() async throws {
        let coordinator = LazyPullCoordinator()
        let retires = Tally()
        async let outcome = runPull(coordinator, transferID: 13, retire: { retires.bump() })
        try await waitUntil { coordinator.pendingSlotCountForTesting == 1 }

        coordinator.elapseBackstopWindowForTesting(13)

        guard case .timedOut = await outcome else {
            Issue.record("Expected .timedOut from an idle window")
            return
        }
        // Nothing will fire the awaiter now, so the slot releases it.
        #expect(retires.value == 1)
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("progress for an unknown or resolved pull is a harmless no-op")
    func progressNoOpWhenAbsent() async throws {
        let coordinator = LazyPullCoordinator()
        coordinator.progress(404, bytesReceived: 1, totalBytes: 2)  // nobody waiting
        async let outcome = runPull(coordinator, transferID: 12)
        try await waitUntil { coordinator.pendingSlotCountForTesting == 1 }
        coordinator.deliver(12, inlineRep("done"))
        // Late progress after the slot resolves must not crash or hang.
        coordinator.progress(12, bytesReceived: 1, totalBytes: 2)
        guard case .delivered = await outcome else {
            Issue.record("Expected .delivered")
            return
        }
    }

    @Test("failAll unblocks every waiting pull with .cancelled")
    func failAllCancels() async throws {
        let coordinator = LazyPullCoordinator()
        async let a = runPull(coordinator, transferID: 1)
        async let b = runPull(coordinator, transferID: 2)
        try await waitUntil { coordinator.pendingSlotCountForTesting == 2 }
        coordinator.failAll()

        let outcomes = await [a, b]
        for outcome in outcomes {
            guard case .cancelled = outcome else {
                Issue.record("Expected .cancelled, got \(outcome)")
                return
            }
        }
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("interleaved transfers resolve to their own outcomes")
    func interleavedDemux() async throws {
        let coordinator = LazyPullCoordinator()
        async let first = runPull(coordinator, transferID: 100)
        async let second = runPull(coordinator, transferID: 200)
        try await waitUntil { coordinator.pendingSlotCountForTesting == 2 }

        coordinator.deliver(100, inlineRep("first"))
        coordinator.abort(
            200,
            ClipboardStreamAbortInfo(
                transferID: 200, code: .readError, message: "x", neededBytes: nil,
                availableBytes: nil))

        guard case .delivered(let rep) = await first else {
            Issue.record("Expected .delivered for 100")
            return
        }
        #expect(rep.inMemoryData == Data("first".utf8))
        guard case .aborted(let info) = await second else {
            Issue.record("Expected .aborted for 200")
            return
        }
        #expect(info.code == .readError)
    }

    @Test("a duplicate delivery after the slot resolves is a no-op")
    func idempotentDelivery() async throws {
        let coordinator = LazyPullCoordinator()
        async let outcome = runPull(coordinator, transferID: 9)
        try await waitUntil { coordinator.pendingSlotCountForTesting == 1 }
        coordinator.deliver(9, inlineRep("once"))
        // Second delivery and a late abort must not crash or change the result.
        coordinator.deliver(9, inlineRep("twice"))
        coordinator.abort(
            9,
            ClipboardStreamAbortInfo(
                transferID: 9, code: .cancelled, message: "x", neededBytes: nil, availableBytes: nil))

        guard case .delivered(let rep) = await outcome else {
            Issue.record("Expected .delivered")
            return
        }
        #expect(rep.inMemoryData == Data("once".utf8))
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("deliver for an unknown transfer is a harmless no-op")
    func deliverUnknownTransfer() {
        let coordinator = LazyPullCoordinator()
        coordinator.deliver(42, inlineRep("nobody waiting"))
        coordinator.failAll()
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    // MARK: - Joining

    @Test("a second pull for the same id joins the first: one start, one slot, one outcome for both")
    func secondPullJoinsTheFirst() async throws {
        let coordinator = LazyPullCoordinator()
        let starts = Tally()
        let retires = Tally()
        async let first = runPull(
            coordinator, transferID: 7, retire: { retires.bump() }, start: { starts.bump() })
        try await waitUntil { coordinator.pendingSlotCountForTesting == 1 }

        async let second = runPull(
            coordinator, transferID: 7, retire: { retires.bump() }, start: { starts.bump() })
        try await waitUntil { coordinator.waiterCountForTesting(7) == 2 }
        // Two waiters, one pull: the joiner neither displaced the starter nor
        // opened a second registration.
        #expect(coordinator.pendingSlotCountForTesting == 1)

        coordinator.deliver(7, inlineRep("shared"))
        for outcome in await [first, second] {
            guard case .delivered(let rep) = outcome else {
                Issue.record("Expected .delivered for both waiters, got \(outcome)")
                return
            }
            #expect(rep.inMemoryData == Data("shared".utf8))
        }
        #expect(starts.value == 1)
        // The awaiter itself fired, so there was nothing left to deregister.
        #expect(retires.value == 0)
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("an async join and a sync pull share one pull: one outcome, both progress hooks fed")
    func asyncJoinSharesTheSyncPull() async throws {
        let coordinator = LazyPullCoordinator()
        let starts = Tally()
        let syncProgress = ProgressCounter()
        let asyncProgress = ProgressCounter()
        async let syncOutcome = runPull(
            coordinator, transferID: 21,
            onProgress: { syncProgress.bump(bytes: $0, total: $1) },
            start: { starts.bump() })
        try await waitUntil { coordinator.pendingSlotCountForTesting == 1 }

        let resolved = Box<LazyPullOutcome?>(nil)
        let joinResolved = AsyncGate()
        coordinator.join(
            transferID: 21,
            onProgress: { asyncProgress.bump(bytes: $0, total: $1) },
            retire: {}, start: { starts.bump() },
            onResolve: {
                resolved.value = $0
                joinResolved.notify()
            })
        try await waitUntil { coordinator.waiterCountForTesting(21) == 2 }

        coordinator.progress(21, bytesReceived: 64, totalBytes: 128)
        coordinator.deliver(21, inlineRep("both"))

        guard case .delivered(let syncRep) = await syncOutcome else {
            Issue.record("Expected .delivered for the synchronous waiter")
            return
        }
        try await joinResolved.wait { resolved.value != nil }
        guard case .delivered(let asyncRep) = resolved.value else {
            Issue.record("Expected .delivered for the asynchronous waiter")
            return
        }
        #expect(syncRep.inMemoryData == Data("both".utf8))
        #expect(asyncRep.inMemoryData == Data("both".utf8))
        #expect(starts.value == 1)
        // One chunk, fanned out to each waiter's own readout.
        #expect(syncProgress.value == 1)
        #expect(asyncProgress.value == 1)
        #expect(asyncProgress.lastBytesReceived == 64)
    }

    @Test("one waiter leaving keeps the pull running for the other")
    func leaveKeepsThePullForTheRemainingWaiter() async throws {
        let coordinator = LazyPullCoordinator()
        let retires = Tally()
        async let held = runPull(coordinator, transferID: 33, retire: { retires.bump() })
        try await waitUntil { coordinator.pendingSlotCountForTesting == 1 }

        let leftOutcome = Box<LazyPullOutcome?>(nil)
        let waiter = coordinator.join(
            transferID: 33, retire: { retires.bump() }, start: {},
            onResolve: { leftOutcome.value = $0 })
        try await waitUntil { coordinator.waiterCountForTesting(33) == 2 }

        #expect(coordinator.leave(waiter))
        guard case .cancelled = leftOutcome.value else {
            Issue.record("Expected the departing waiter to resolve .cancelled")
            return
        }
        // The transfer is still the other waiter's, so nothing was retired.
        #expect(coordinator.pendingSlotCountForTesting == 1)
        #expect(coordinator.waiterCountForTesting(33) == 1)
        #expect(retires.value == 0)

        coordinator.deliver(33, inlineRep("still mine"))
        guard case .delivered(let rep) = await held else {
            Issue.record("Expected the remaining waiter to be delivered")
            return
        }
        #expect(rep.inMemoryData == Data("still mine".utf8))
    }

    @Test("the last waiter leaving abandons the pull: the slot goes and retire runs once")
    func lastWaiterOutRetiresThePull() async throws {
        let coordinator = LazyPullCoordinator()
        let retires = Tally()
        let outcome = Box<LazyPullOutcome?>(nil)
        let resolved = AsyncGate()
        let waiter = coordinator.join(
            transferID: 34, retire: { retires.bump() }, start: {},
            onResolve: {
                outcome.value = $0
                resolved.notify()
            })

        #expect(coordinator.leave(waiter) == false)
        try await resolved.wait { outcome.value != nil }
        guard case .cancelled = outcome.value else {
            Issue.record("Expected .cancelled for the last waiter out")
            return
        }
        #expect(coordinator.pendingSlotCountForTesting == 0)
        #expect(retires.value == 1)

        // Leaving twice changes nothing: the pull is already over.
        #expect(coordinator.leave(waiter))
        #expect(retires.value == 1)
    }

    @Test("the backstop times every waiter of a shared pull out at once, retiring it once")
    func backstopFansOutToEveryWaiter() async throws {
        let coordinator = LazyPullCoordinator()
        let retires = Tally()
        async let first = runPull(coordinator, transferID: 41, retire: { retires.bump() })
        try await waitUntil { coordinator.pendingSlotCountForTesting == 1 }
        async let second = runPull(coordinator, transferID: 41, retire: { retires.bump() })
        try await waitUntil { coordinator.waiterCountForTesting(41) == 2 }

        coordinator.elapseBackstopWindowForTesting(41)

        for outcome in await [first, second] {
            guard case .timedOut = outcome else {
                Issue.record("Expected .timedOut for both waiters, got \(outcome)")
                return
            }
        }
        #expect(retires.value == 1)
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("failAll cancels every waiter of a shared pull and retires it once")
    func failAllCancelsEveryWaiterOfAJoinedPull() async throws {
        let coordinator = LazyPullCoordinator()
        let retires = Tally()
        async let first = runPull(coordinator, transferID: 42, retire: { retires.bump() })
        try await waitUntil { coordinator.pendingSlotCountForTesting == 1 }
        async let second = runPull(coordinator, transferID: 42, retire: { retires.bump() })
        try await waitUntil { coordinator.waiterCountForTesting(42) == 2 }

        coordinator.failAll()

        for outcome in await [first, second] {
            guard case .cancelled = outcome else {
                Issue.record("Expected .cancelled for both waiters, got \(outcome)")
                return
            }
        }
        #expect(retires.value == 1)
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("a pull for an id whose slot already resolved starts a fresh one")
    func resolvedIDStartsAFreshPull() async throws {
        let coordinator = LazyPullCoordinator()
        let starts = Tally()
        async let first = runPull(coordinator, transferID: 55, start: { starts.bump() })
        try await waitUntil { coordinator.pendingSlotCountForTesting == 1 }
        coordinator.deliver(55, inlineRep("one"))
        guard case .delivered = await first else {
            Issue.record("Expected .delivered for the first pull")
            return
        }

        async let second = runPull(coordinator, transferID: 55, start: { starts.bump() })
        try await waitUntil { coordinator.pendingSlotCountForTesting == 1 }
        coordinator.deliver(55, inlineRep("two"))
        guard case .delivered(let rep) = await second else {
            Issue.record("Expected .delivered for the fresh pull")
            return
        }
        #expect(rep.inMemoryData == Data("two".utf8))
        #expect(starts.value == 2)
    }

    @Test("a pull ended while start runs is retired only once start returns")
    func retireOwedDuringStartRunsAfterIt() async throws {
        let coordinator = LazyPullCoordinator()
        let order = OrderLog()
        let outcome = await runPull(
            coordinator, transferID: 61,
            retire: { order.record("retire") },
            start: {
                order.record("start began")
                // A channel close landing here finds no awaiter to release: the
                // one this pull owns is what `start` is on its way to register.
                coordinator.failAll()
                order.record("start ended")
            })
        guard case .cancelled = outcome else {
            Issue.record("Expected .cancelled, got \(outcome)")
            return
        }
        #expect(order.entries == ["start began", "start ended", "retire"])
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    // MARK: - Inbox wiring

    /// The plan a text pull registers, which nothing on the wire repeats.
    private func textPlan(advertising byteCount: Int = 0) -> ClipboardTransferReceiver.Plan {
        ClipboardTransferReceiver.Plan(
            uti: ClipboardContent.utf8TextUTI, advertisedByteCount: byteCount)
    }

    /// Serves `representation` for `transferID` the way the sending side does
    /// when it is the one that dials: the reply, the payload, the trailer, then
    /// the inbox adopting what arrived.
    private func serve(
        _ representation: ClipboardContent.Representation, transferID: UInt64, generation: UInt64,
        isInline: Bool = true, on harness: TransferHarness
    ) {
        let inbox = harness.inbox
        harness.outbox.serve(
            transferID: transferID, generation: generation, representation: representation,
            maxAcceptByteCount: ClipboardStreamTuning.unlimitedAcceptByteCount,
            isInline: isInline, isCurrent: { _ in true },
            link: .dial {
                try dialToPeer { far in
                    guard let reply = readTransferReply(fd: far) else {
                        ClipboardDataConnection.end(fd: far)
                        return
                    }
                    inbox.adopt(fd: far, reply: reply)
                }
            })
    }

    @Test("a pull abandoned while start runs still releases the awaiter start registered")
    func retireOwedDuringStartReleasesTheAwaiter() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }

        let coordinator = LazyPullCoordinator()
        let transferID = ClipboardTransferID.make(generation: 13, repIndex: 0, hostMinted: true)
        let inbox = harness.inbox
        let plan = textPlan()
        let outcome = await runPull(
            coordinator, transferID: transferID,
            retire: { inbox.cancelAwait(transferID) },
            start: {
                // The connection dies between the slot going up and the
                // registration going in — the one window where the release is
                // owed rather than run.
                coordinator.failAll()
                inbox.awaitTransfer(
                    transferID, plan: plan,
                    onComplete: { _ in Issue.record("the abandoned pull's awaiter must not fire") },
                    onAbort: { _ in Issue.record("the abandoned pull's awaiter must not fire") })
            })
        guard case .cancelled = outcome else {
            Issue.record("Expected .cancelled, got \(outcome)")
            return
        }

        // Nothing is registered for the id now, so a fresh pull for it registers
        // cleanly — a live awaiter left behind would trip `awaitTransfer`'s
        // double-registration assertion — and takes the transfer.
        let box = RepBox()
        let gate = AsyncGate()
        inbox.awaitTransfer(
            transferID, plan: plan,
            onComplete: {
                box.setRep($0)
                gate.notify()
            },
            onAbort: {
                box.setAbort($0)
                gate.notify()
            })
        serve(inlineRep("after the abandon"), transferID: transferID, generation: 13, on: harness)

        try await gate.wait { box.representation != nil }
        #expect(box.representation?.inMemoryData == Data("after the abandon".utf8))
    }

    @Test("an awaiter registered before the transfer opens receives its representation")
    func awaitTransferDeliversToItsAwaiter() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }

        let box = RepBox()
        let gate = AsyncGate()
        harness.inbox.awaitTransfer(
            1, plan: textPlan(),
            onComplete: { rep in
                box.setRep(rep)
                gate.notify()
            },
            onAbort: { info in
                box.setAbort(info)
                gate.notify()
            })

        let bytes = patternedBytes(count: 4096 * 3 + 11, multiplier: 13, offset: 5)
        let rep = ClipboardContent.Representation(uti: ClipboardContent.utf8TextUTI, data: bytes)
        serve(rep, transferID: 1, generation: 1, on: harness)

        try await gate.wait { box.representation != nil }
        #expect(box.representation?.inMemoryData == bytes)
    }

    @Test(
        "end-to-end: a second fetch for the same transfer id joins the streaming transfer and both complete"
    )
    func concurrentPullsForSameIDJoin() async throws {
        // Mirrors the real trigger: a second consumer asks for the same
        // representation — a sibling flavor, or the window's preview — while the
        // first pull is still parked. Exercised through the real inbox and
        // outbox, not just the coordinator in isolation.
        let harness = TransferHarness()
        defer { harness.tearDown() }

        let coordinator = LazyPullCoordinator()
        let transferID = ClipboardTransferID.make(generation: 1, repIndex: 0, hostMinted: true)
        let starts = Tally()
        // The starter registers the awaiter inside `start`, exactly like
        // `ClipboardInboundOffers.begin`.
        let inbox = harness.inbox
        let plan = textPlan()
        let start: @Sendable () -> Void = {
            starts.bump()
            inbox.awaitTransfer(
                transferID, plan: plan,
                onComplete: { rep in coordinator.deliver(transferID, rep) },
                onAbort: { info in coordinator.abort(transferID, info) })
        }

        async let firstAttempt = runPull(coordinator, transferID: transferID, start: start)
        try await waitUntil { coordinator.pendingSlotCountForTesting == 1 }

        // The second consumer: a concurrent pull for the identical id.
        async let secondAttempt = runPull(coordinator, transferID: transferID, start: start)
        try await waitUntil { coordinator.waiterCountForTesting(transferID) == 2 }

        let bytes = patternedBytes(count: 4096 * 2 + 9, multiplier: 29, offset: 3)
        let rep = ClipboardContent.Representation(uti: ClipboardContent.utf8TextUTI, data: bytes)
        serve(rep, transferID: transferID, generation: 1, on: harness)

        for outcome in await [firstAttempt, secondAttempt] {
            guard case .delivered(let received) = outcome else {
                Issue.record("Expected .delivered for both waiters, got \(outcome)")
                return
            }
            #expect(received.inMemoryData == bytes)
        }
        // One registration and one connection covered both.
        #expect(starts.value == 1)
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("awaitTransfer reports arriving bytes as they land, not once at the end")
    func awaitTransferReportsProgress() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }

        let progress = ProgressCounter()
        let box = RepBox()
        let gate = AsyncGate()
        // A payload spanning several socket reads: the cadence is one report per
        // read the receiver takes, which is what a parked pull re-arms its
        // inactivity backstop on.
        let bytes = patternedBytes(
            count: 3 * ClipboardStreamTuning.dataReadBufferBytes + 7, multiplier: 7, offset: 1)
        harness.inbox.awaitTransfer(
            1, plan: textPlan(advertising: bytes.count),
            onComplete: { rep in
                box.setRep(rep)
                gate.notify()
            },
            onAbort: { info in
                box.setAbort(info)
                gate.notify()
            },
            onProgress: { received, total in progress.bump(bytes: received, total: total) })

        let rep = ClipboardContent.Representation(uti: ClipboardContent.utf8TextUTI, data: bytes)
        serve(rep, transferID: 1, generation: 1, on: harness)

        try await gate.wait { box.representation != nil }
        #expect(box.representation?.inMemoryData == bytes)
        #expect(progress.value > 1)
        // The callback carries cumulative bytes: monotonic, constant total, final
        // == the full payload.
        #expect(progress.isMonotonic)
        #expect(progress.lastTotal == bytes.count)
        #expect(progress.lastBytesReceived == bytes.count)
    }

    @Test("a registered awaiter is woken by the abort its own transfer raised")
    func awaitTransferReceivesAbort() async throws {
        // A tiny free-space provider forces the receiver to reject the file rep
        // up front with disk.full, exercising the awaiter abort path.
        let harness = TransferHarness(freeSpaceProvider: { _ in 0 })
        defer { harness.tearDown() }

        let bytes = Data(repeating: 7, count: 4096 * 2)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: false)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let box = RepBox()
        let gate = AsyncGate()
        harness.inbox.awaitTransfer(
            2,
            plan: ClipboardTransferReceiver.Plan(
                uti: "public.data", filename: "f.bin", advertisedByteCount: bytes.count),
            onComplete: { rep in
                box.setRep(rep)
                gate.notify()
            },
            onAbort: { info in
                box.setAbort(info)
                gate.notify()
            })

        let rep = ClipboardContent.Representation(
            uti: "public.data", fileURL: source, byteCount: bytes.count, filename: "f.bin")
        serve(rep, transferID: 2, generation: 1, isInline: false, on: harness)

        try await gate.wait { box.abortInfo != nil }
        #expect(box.abortInfo?.code == .diskFull)
    }

    @Test("an awaiter is woken by a refusal that arrives before any payload byte")
    func awaitTransferAbortWithoutPayload() async throws {
        // The sender refuses a transfer the requester cannot accept with a reply
        // and no bytes at all; the awaiter — a blocked lazy pull — must still
        // wake rather than park to its timeout.
        let harness = TransferHarness()
        defer { harness.tearDown() }

        let box = RepBox()
        let gate = AsyncGate()
        let transferID = ClipboardTransferID.make(generation: 5, repIndex: 0, hostMinted: true)
        harness.inbox.awaitTransfer(
            transferID, plan: textPlan(),
            onComplete: {
                box.setRep($0)
                gate.notify()
            },
            onAbort: {
                box.setAbort($0)
                gate.notify()
            })

        let inbox = harness.inbox
        let fd = try dialToPeer { far in
            try? refuseTransfer(
                fd: far, transferID: transferID,
                code: ClipboardStreamAbortCode.diskFull.rawValue, message: "refused up front")
        }
        let reply = await offCooperativePool { readTransferReply(fd: fd) }
        inbox.adopt(fd: fd, reply: try #require(reply))

        try await gate.wait { box.abortInfo != nil }
        #expect(box.abortInfo?.code == .diskFull)
    }

    @Test("cancel(generation:) wakes an awaiter whose transfer never opened a connection")
    func cancelDrainsAwaiter() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }

        let box = RepBox()
        let gate = AsyncGate()
        let transferID = ClipboardTransferID.make(generation: 7, repIndex: 2, hostMinted: true)
        harness.inbox.awaitTransfer(
            transferID, plan: textPlan(),
            onComplete: {
                box.setRep($0)
                gate.notify()
            },
            onAbort: {
                box.setAbort($0)
                gate.notify()
            })

        harness.inbox.cancel(generation: 7)

        try await gate.wait { box.abortInfo != nil }
        #expect(box.abortInfo?.code == .cancelled)
    }

    @Test("cancelAll() wakes an awaiter whose transfer never opened a connection")
    func cancelAllDrainsAwaiter() async throws {
        let harness = TransferHarness()
        defer { harness.tearDown() }

        let box = RepBox()
        let gate = AsyncGate()
        let transferID = ClipboardTransferID.make(generation: 9, repIndex: 0, hostMinted: true)
        harness.inbox.awaitTransfer(
            transferID, plan: textPlan(),
            onComplete: {
                box.setRep($0)
                gate.notify()
            },
            onAbort: {
                box.setAbort($0)
                gate.notify()
            })

        harness.inbox.cancelAll()

        try await gate.wait { box.abortInfo != nil }
        #expect(box.abortInfo?.code == .cancelled)
    }

    @Test(
        "a straggler abort for attempt #1 lands on attempt #2's awaiter when both share an id, but leaves no orphaned state behind (#499)"
    )
    func staleAbortCollidesWithReusedAwaiterButTableStaysConsistent() async throws {
        // `ClipboardTransferID` is intentionally reproducible from
        // (generation, repIndex, direction), so a retried pull of the identical
        // offer/rep registers under the SAME id as the attempt it's retrying —
        // after that attempt's own pull retired its awaiter. A delayed connection
        // meant for #1 (one the peer opened before the local cancel reached it)
        // is keyed purely on that id, so it lands on #2 instead. This test pins
        // the CURRENT, accepted behavior — a bounded, benign collision (#2
        // observes a spurious abort it can retry from), not a crash, hang, or
        // corrupted registration table. See `ClipboardTransferID`'s doc for why
        // a per-attempt discriminator was deferred rather than implemented.
        let harness = TransferHarness()
        defer { harness.tearDown() }

        let transferID = ClipboardTransferID.make(generation: 11, repIndex: 0, hostMinted: true)
        let inbox = harness.inbox
        let plan = textPlan()

        let firstBox = RepBox()
        inbox.awaitTransfer(
            transferID, plan: plan,
            onComplete: { _ in Issue.record("attempt #1's awaiter was retired — must never fire") },
            onAbort: { firstBox.setAbort($0) })
        // Attempt #1 gives up, retiring its registration — the one live awaiter
        // per id the inbox expects.
        inbox.cancelAwait(transferID)

        let secondBox = RepBox()
        let secondGate = AsyncGate()
        inbox.awaitTransfer(
            transferID, plan: plan,
            onComplete: {
                secondBox.setRep($0)
                secondGate.notify()
            },
            onAbort: {
                secondBox.setAbort($0)
                secondGate.notify()
            })

        // The straggler: attempt #1's connection, opened before its cancel
        // landed and arriving now that attempt #2 owns the registration.
        let fd = try dialToPeer { far in
            try? abortTransfer(
                fd: far, transferID: transferID,
                code: ClipboardStreamAbortCode.cancelled.rawValue, sent: Data("par".utf8),
                declaredBytes: 32)
        }
        let reply = await offCooperativePool { readTransferReply(fd: fd) }
        inbox.adopt(fd: fd, reply: try #require(reply))

        try await secondGate.wait { secondBox.abortInfo != nil }
        #expect(secondBox.abortInfo?.code == .cancelled)
        #expect(firstBox.abortInfo == nil)  // #1's own onAbort never fired — it was already retired

        // The table is left fully consistent: a THIRD attempt reusing the
        // identical id — the normal "restart after abort is cheap, no
        // orphaned state" case (CLIPBOARD.md §9) — completes cleanly.
        let thirdBox = RepBox()
        let thirdGate = AsyncGate()
        inbox.awaitTransfer(
            transferID, plan: plan,
            onComplete: {
                thirdBox.setRep($0)
                thirdGate.notify()
            },
            onAbort: {
                thirdBox.setAbort($0)
                thirdGate.notify()
            })
        serve(inlineRep("attempt three"), transferID: transferID, generation: 11, on: harness)

        try await thirdGate.wait { thirdBox.representation != nil }
        #expect(thirdBox.representation?.inMemoryData == Data("attempt three".utf8))
    }
}
