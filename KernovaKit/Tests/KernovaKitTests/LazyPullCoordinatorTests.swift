import Foundation
import Testing
import KernovaTestSupport

@testable import KernovaKit

@Suite("LazyPullCoordinator")
struct LazyPullCoordinatorTests {
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

    /// Runs the blocking `pull` on a global queue so the test's cooperative
    /// thread stays free to deliver/abort/failAll and `await` the outcome.
    private func runPull(
        _ coordinator: LazyPullCoordinator,
        transferID: UInt64,
        timeout: Duration,
        send: @escaping @Sendable () -> Void = {}
    ) async -> LazyPullOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<LazyPullOutcome, Never>) in
            DispatchQueue.global().async {
                cont.resume(
                    returning: coordinator.pull(
                        transferID: transferID, timeout: timeout, send: send))
            }
        }
    }

    private func inlineRep(_ text: String) -> ClipboardContent.Representation {
        ClipboardContent.Representation(uti: ClipboardContent.utf8TextUTI, data: Data(text.utf8))
    }

    // MARK: - Slot machinery

    // RATIONALE: The `pollUntil` waits in this section read the SUT's own
    // `pendingSlotCountForTesting`, a DEBUG getter over an NSLock-guarded dict on
    // `LazyPullCoordinator` (not @Observable), registered inside `pull()` running on
    // a background `DispatchQueue`. There is no test-owned signal to await: the
    // file's `AsyncGate` gates the harness receiver's onComplete/onAbort closures,
    // not slot registration, and wiring a gate into production `pull()` is out of
    // scope. Polling the coordinator's own state is correct here. See docs/TESTING.md
    // "Async waits in tests".

    @Test("pull blocks until deliver wakes it with the representation")
    func deliverWakesPull() async throws {
        let coordinator = LazyPullCoordinator()
        async let outcome = runPull(coordinator, transferID: 7, timeout: .seconds(5))
        try await pollUntil { coordinator.pendingSlotCountForTesting == 1 }
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
        async let outcome = runPull(coordinator, transferID: 3, timeout: .seconds(5))
        try await pollUntil { coordinator.pendingSlotCountForTesting == 1 }
        coordinator.abort(
            3,
            ClipboardStreamAbortInfo(
                transferID: 3, code: "disk.full", message: "no space",
                neededBytes: 10, availableBytes: 1))

        guard case .aborted(let info) = await outcome else {
            Issue.record("Expected .aborted")
            return
        }
        #expect(info.code == "disk.full")
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("pull times out when no outcome is delivered")
    func pullTimesOut() async throws {
        let coordinator = LazyPullCoordinator()
        let outcome = await runPull(coordinator, transferID: 5, timeout: .milliseconds(120))
        guard case .timedOut = outcome else {
            Issue.record("Expected .timedOut, got \(outcome)")
            return
        }
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("heartbeats re-arm the inactivity window so a slow-but-live pull is not timed out")
    func heartbeatExtendsTimeout() async throws {
        // Drives the window boundary via `windowWaitForTesting` instead of a
        // real wall-clock wait, so the test proves the re-arm branch in `pull`
        // fires deterministically — not that a `Task.sleep` producer happens
        // to beat a real semaphore timeout on a shared CI runner (#571: the
        // prior version raced real time and flaked under scheduler jitter).
        let coordinator = LazyPullCoordinator()
        let window1Entered = AsyncGate()
        let window2Entered = AsyncGate()
        let releaseWindow1 = DispatchSemaphore(value: 0)
        let windowCallCount = Box(0)

        coordinator.windowWaitForTesting = { semaphore, timeout in
            let call = windowCallCount.value
            windowCallCount.value = call + 1
            if call == 0 {
                // First boundary: park here (instead of a real timed wait)
                // until the test has delivered a heartbeat, so `progressed`
                // is guaranteed set before `pull` evaluates this boundary.
                window1Entered.notify()
                releaseWindow1.wait()
            } else {
                // Second boundary reached: the first window re-armed rather
                // than resolving `.timedOut` — the invariant under test
                // (#500 — a slow-but-live transfer must not time out). Wait
                // for real so `deliver`'s signal wakes it as usual.
                window2Entered.notify()
                _ = semaphore.wait(timeout: .now() + timeout.timeInterval)
            }
        }
        // The window value itself is moot here — `windowWaitForTesting`
        // controls boundary timing directly — but 300 ms documents the real
        // production window this test stands in for.
        async let outcome = runPull(coordinator, transferID: 11, timeout: .milliseconds(300))
        try await window1Entered.wait { windowCallCount.value >= 1 }
        coordinator.heartbeat(11)
        releaseWindow1.signal()
        try await window2Entered.wait { windowCallCount.value >= 2 }
        coordinator.deliver(11, inlineRep("slow but alive"))

        guard case .delivered(let rep) = await outcome else {
            Issue.record("Expected .delivered — heartbeats should have prevented the timeout")
            return
        }
        #expect(rep.inMemoryData == Data("slow but alive".utf8))
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("a heartbeat for an unknown or resolved pull is a harmless no-op")
    func heartbeatNoOpWhenAbsent() async throws {
        let coordinator = LazyPullCoordinator()
        coordinator.heartbeat(404)  // nobody waiting
        async let outcome = runPull(coordinator, transferID: 12, timeout: .seconds(5))
        try await pollUntil { coordinator.pendingSlotCountForTesting == 1 }
        coordinator.deliver(12, inlineRep("done"))
        // A late heartbeat after the slot resolves must not crash or hang.
        coordinator.heartbeat(12)
        guard case .delivered = await outcome else {
            Issue.record("Expected .delivered")
            return
        }
    }

    @Test("failAll unblocks every waiting pull with .cancelled")
    func failAllCancels() async throws {
        let coordinator = LazyPullCoordinator()
        async let a = runPull(coordinator, transferID: 1, timeout: .seconds(5))
        async let b = runPull(coordinator, transferID: 2, timeout: .seconds(5))
        try await pollUntil { coordinator.pendingSlotCountForTesting == 2 }
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
        async let first = runPull(coordinator, transferID: 100, timeout: .seconds(5))
        async let second = runPull(coordinator, transferID: 200, timeout: .seconds(5))
        try await pollUntil { coordinator.pendingSlotCountForTesting == 2 }

        coordinator.deliver(100, inlineRep("first"))
        coordinator.abort(
            200,
            ClipboardStreamAbortInfo(
                transferID: 200, code: "peer.error", message: "x", neededBytes: nil,
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
        #expect(info.code == "peer.error")
    }

    @Test("a duplicate delivery after the slot resolves is a no-op")
    func idempotentDelivery() async throws {
        let coordinator = LazyPullCoordinator()
        async let outcome = runPull(coordinator, transferID: 9, timeout: .seconds(5))
        try await pollUntil { coordinator.pendingSlotCountForTesting == 1 }
        coordinator.deliver(9, inlineRep("once"))
        // Second delivery and a late abort must not crash or change the result.
        coordinator.deliver(9, inlineRep("twice"))
        coordinator.abort(
            9,
            ClipboardStreamAbortInfo(
                transferID: 9, code: "late", message: "x", neededBytes: nil, availableBytes: nil))

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

    @Test(
        "a second pull for the same id supersedes the first, waking it immediately instead of parking it to its own timeout (#500)"
    )
    func pullSupersedesInFlightPullForSameID() async throws {
        let coordinator = LazyPullCoordinator()
        async let first = runPull(coordinator, transferID: 7, timeout: .seconds(5))
        try await pollUntil { coordinator.pendingSlotCountForTesting == 1 }

        async let second = runPull(coordinator, transferID: 7, timeout: .seconds(5))
        // The registration itself resolves the displaced pull — no need to
        // wait for a timeout window (CLIPBOARD.md §9: wake immediately).
        guard case .superseded = await first else {
            Issue.record("Expected .superseded for the displaced first pull")
            return
        }
        // The dict still holds exactly one entry for the id — the
        // successor's, not the displaced one's.
        #expect(coordinator.pendingSlotCountForTesting == 1)

        coordinator.deliver(7, inlineRep("from the retry"))
        guard case .delivered(let rep) = await second else {
            Issue.record("Expected .delivered for the surviving second pull")
            return
        }
        #expect(rep.inMemoryData == Data("from the retry".utf8))
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("a chain of supersessions never evicts the final survivor's registration (#500)")
    func supersededPullCleanupDoesNotEvictSuccessor() async throws {
        // Regression guard for the identity-checked removal: without it, each
        // displaced pull's own wait-loop cleanup (`slots[transferID] = nil`)
        // would unconditionally evict whatever slot currently occupies that
        // key — including a later successor's — leaving `deliver` unable to
        // reach anyone.
        let coordinator = LazyPullCoordinator()
        async let first = runPull(coordinator, transferID: 7, timeout: .seconds(5))
        try await pollUntil { coordinator.pendingSlotCountForTesting == 1 }

        async let second = runPull(coordinator, transferID: 7, timeout: .seconds(5))
        guard case .superseded = await first else {
            Issue.record("Expected .superseded for the first pull")
            return
        }

        async let third = runPull(coordinator, transferID: 7, timeout: .seconds(5))
        guard case .superseded = await second else {
            Issue.record("Expected .superseded for the second pull")
            return
        }
        // Two supersessions have each run their own identity-checked cleanup;
        // the dict must still hold exactly the third (surviving) slot.
        #expect(coordinator.pendingSlotCountForTesting == 1)

        coordinator.deliver(7, inlineRep("the survivor"))
        guard case .delivered(let rep) = await third else {
            Issue.record("Expected .delivered for the surviving third pull")
            return
        }
        #expect(rep.inMemoryData == Data("the survivor".utf8))
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    // MARK: - Receiver wiring

    @Test("a registered awaiter receives the transfer instead of the channel-wide onComplete")
    func awaitTransferBypassesChannelWide() async throws {
        let harness = try StreamHarness(
            chunkSize: 4096, windowBytes: 16384,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let box = RepBox()
        let gate = AsyncGate()
        harness.receiver.awaitTransfer(
            1,
            onComplete: { rep in
                box.setRep(rep)
                gate.notify()
            },
            onAbort: { info in
                box.setAbort(info)
                gate.notify()
            })

        var bytes = Data()
        for i in 0..<(4096 * 3 + 11) { bytes.append(UInt8((i * 13 + 5) & 0xFF)) }
        let rep = ClipboardContent.Representation(uti: ClipboardContent.utf8TextUTI, data: bytes)
        harness.sender.startTransfer(
            transferID: 1, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })

        try await gate.wait { box.representation != nil }
        #expect(box.representation?.inMemoryData == bytes)
        // The channel-wide collector must NOT have been invoked for an awaited
        // transfer.
        #expect(harness.collector.representation(1) == nil)
        #expect(harness.collector.completedCount == 0)
    }

    @Test(
        "end-to-end: a retried fetch for the same transfer id supersedes the original attempt and streams to completion (#500)"
    )
    func concurrentPullsForSameIDSupersedeCleanly() async throws {
        // Mirrors the real #500 trigger: `FileProviderRelayService.fetchFile`'s
        // `.concurrent` pullQueue lets a retry (the extension re-dispatching
        // `fetchContents` after its owner connection dropped mid-pull) run a
        // second `awaitTransfer` + `pull` for the identical id while the first
        // attempt is still parked — exercised here through the real receiver
        // and sender, not just the coordinator in isolation.
        let harness = try StreamHarness(
            chunkSize: 4096, windowBytes: 16384,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let coordinator = LazyPullCoordinator()
        let transferID = ClipboardTransferID.make(generation: 1, repIndex: 0, hostMinted: true)

        // Both attempts' awaiters simply forward to the coordinator, exactly
        // like `VsockGuestClipboardAgent.pullRepresentation` /
        // `VsockClipboardService.performBlockingPull`.
        harness.receiver.awaitTransfer(
            transferID,
            onComplete: { rep in coordinator.deliver(transferID, rep) },
            onAbort: { info in coordinator.abort(transferID, info) })

        async let firstAttempt = runPull(coordinator, transferID: transferID, timeout: .seconds(5))
        try await pollUntil { coordinator.pendingSlotCountForTesting == 1 }

        // The retry: a second concurrent pull for the identical id.
        async let secondAttempt = runPull(coordinator, transferID: transferID, timeout: .seconds(5))
        guard case .superseded = await firstAttempt else {
            Issue.record("Expected .superseded for the displaced first attempt")
            return
        }

        // Only now does the stream actually run — the retry is the sole live
        // pull, and its awaiter (still registered under the same id) delivers
        // the real transfer to the coordinator.
        var bytes = Data()
        for i in 0..<(4096 * 2 + 9) { bytes.append(UInt8((i * 29 + 3) & 0xFF)) }
        let rep = ClipboardContent.Representation(uti: ClipboardContent.utf8TextUTI, data: bytes)
        harness.sender.startTransfer(
            transferID: transferID, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })

        guard case .delivered(let received) = await secondAttempt else {
            Issue.record("Expected .delivered for the surviving second attempt")
            return
        }
        #expect(received.inMemoryData == bytes)
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("awaitTransfer fires onProgress once per durably-written chunk")
    func awaitTransferReportsProgress() async throws {
        let harness = try StreamHarness(
            chunkSize: 4096, windowBytes: 1 << 20,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let progress = ProgressCounter()
        let box = RepBox()
        let gate = AsyncGate()
        harness.receiver.awaitTransfer(
            1,
            onComplete: { rep in
                box.setRep(rep)
                gate.notify()
            },
            onAbort: { info in
                box.setAbort(info)
                gate.notify()
            },
            onProgress: { bytes, total in progress.bump(bytes: bytes, total: total) })

        // 3 full chunks + a partial → 4 chunks → 4 progress callbacks, all of
        // which precede onComplete on the transfer's serial queue.
        var bytes = Data()
        for i in 0..<(4096 * 3 + 7) { bytes.append(UInt8((i * 7 + 1) & 0xFF)) }
        let rep = ClipboardContent.Representation(uti: ClipboardContent.utf8TextUTI, data: bytes)
        harness.sender.startTransfer(
            transferID: 1, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })

        try await gate.wait { box.representation != nil }
        #expect(box.representation?.inMemoryData == bytes)
        #expect(progress.value == 4)
        // The callback carries cumulative bytes: monotonic, constant total, final
        // == the full payload.
        #expect(progress.isMonotonic)
        #expect(progress.lastTotal == bytes.count)
        #expect(progress.lastBytesReceived == bytes.count)
    }

    @Test("a registered awaiter receives a peer abort instead of the channel-wide onAbort")
    func awaitTransferReceivesAbort() async throws {
        // A tiny free-space provider forces the receiver to reject the file rep
        // up front with disk.full, exercising the awaiter abort path.
        let harness = try StreamHarness(
            chunkSize: 4096, windowBytes: 16384,
            freeSpaceProvider: { _ in 0 })
        defer { harness.tearDown() }

        let box = RepBox()
        let gate = AsyncGate()
        harness.receiver.awaitTransfer(
            2,
            onComplete: { rep in
                box.setRep(rep)
                gate.notify()
            },
            onAbort: { info in
                box.setAbort(info)
                gate.notify()
            })

        let bytes = Data(repeating: 7, count: 4096 * 2)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: false)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let rep = ClipboardContent.Representation(
            uti: "public.data", fileURL: source, byteCount: bytes.count, filename: "f.bin")
        harness.sender.startTransfer(
            transferID: 2, generation: 1, representation: rep, maxAcceptByteCount: .max,
            isInline: false, isCurrent: { _ in true })

        try await gate.wait { box.abortInfo != nil }
        #expect(box.abortInfo?.code == "disk.full")
        #expect(harness.collector.abortCount == 0)
    }

    @Test("an awaiter is woken by an abort that arrives with no preceding Begin")
    func awaitTransferAbortWithoutBegin() async throws {
        // The sender refuses a transfer that exceeds max_accept by sending an
        // Abort BEFORE any Begin; the awaiter (a blocked lazy pull) must still
        // wake rather than park to its timeout.
        let harness = try StreamHarness(
            chunkSize: 4096, windowBytes: 16384,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let box = RepBox()
        let gate = AsyncGate()
        let transferID = ClipboardTransferID.make(generation: 5, repIndex: 0, hostMinted: true)
        harness.receiver.awaitTransfer(
            transferID,
            onComplete: {
                box.setRep($0)
                gate.notify()
            },
            onAbort: {
                box.setAbort($0)
                gate.notify()
            })

        harness.receiver.handleAbort(
            .with {
                $0.transferID = transferID
                $0.code = "disk.full"
                $0.message = "refused before begin"
            })

        try await gate.wait { box.abortInfo != nil }
        #expect(box.abortInfo?.code == "disk.full")
    }

    @Test("cancel(generation:) wakes an awaiter whose transfer never produced a Begin")
    func cancelDrainsAwaiter() async throws {
        let harness = try StreamHarness(
            chunkSize: 4096, windowBytes: 16384,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let box = RepBox()
        let gate = AsyncGate()
        let transferID = ClipboardTransferID.make(generation: 7, repIndex: 2, hostMinted: true)
        harness.receiver.awaitTransfer(
            transferID,
            onComplete: {
                box.setRep($0)
                gate.notify()
            },
            onAbort: {
                box.setAbort($0)
                gate.notify()
            })

        harness.receiver.cancel(generation: 7)

        try await gate.wait { box.abortInfo != nil }
        #expect(box.abortInfo?.code == "cancelled")
    }

    @Test("cancelAll() wakes an awaiter whose transfer never produced a Begin")
    func cancelAllDrainsAwaiter() async throws {
        let harness = try StreamHarness(
            chunkSize: 4096, windowBytes: 16384,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let box = RepBox()
        let gate = AsyncGate()
        let transferID = ClipboardTransferID.make(generation: 9, repIndex: 0, hostMinted: true)
        harness.receiver.awaitTransfer(
            transferID,
            onComplete: {
                box.setRep($0)
                gate.notify()
            },
            onAbort: {
                box.setAbort($0)
                gate.notify()
            })

        harness.receiver.cancelAll()

        try await gate.wait { box.abortInfo != nil }
        #expect(box.abortInfo?.code == "cancelled")
    }

    @Test("cancel(transferID:) wakes an awaiter whose transfer never produced a Begin (#464)")
    func cancelTransferIDDrainsAwaiter() async throws {
        let harness = try StreamHarness(
            chunkSize: 4096, windowBytes: 16384,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let box = RepBox()
        let gate = AsyncGate()
        let transferID = ClipboardTransferID.make(generation: 3, repIndex: 1, hostMinted: true)
        harness.receiver.awaitTransfer(
            transferID,
            onComplete: {
                box.setRep($0)
                gate.notify()
            },
            onAbort: {
                box.setAbort($0)
                gate.notify()
            })

        // A per-transfer cancel — unlike `cancel(generation:)`/`cancelAll()` — is
        // scoped to one id, so it must still wake an awaiter that has no
        // `transfers` entry yet (never produced a Begin), same as the
        // generation/channel-wide paths above.
        harness.receiver.cancel(transferID: transferID)

        try await gate.wait { box.abortInfo != nil }
        #expect(box.abortInfo?.code == "cancelled")
    }

    @Test(
        "a straggler abort for attempt #1 lands on attempt #2's awaiter when both share an id, but leaves no orphaned state behind (#499)"
    )
    func staleAbortCollidesWithReusedAwaiterButTableStaysConsistent() async throws {
        // `ClipboardTransferID` is intentionally reproducible from
        // (generation, repIndex, direction), so a retried pull of the identical
        // offer/rep registers under the SAME id as the attempt it's retrying.
        // `awaitTransfer` has no existence guard, so attempt #2's registration
        // silently overwrites attempt #1's — and a delayed abort meant for #1
        // (a reordered wire frame, or a local cancel that raced the retry) is
        // keyed purely on that id, so it lands on #2 instead. This test pins
        // the CURRENT, accepted behavior — a bounded, benign collision (#2
        // observes a spurious abort it can retry from), not a crash, hang, or
        // corrupted registration table. See `ClipboardTransferID`'s doc for why
        // a per-attempt discriminator was deferred rather than implemented.
        let harness = try StreamHarness(
            chunkSize: 4096, windowBytes: 16384,
            freeSpaceProvider: { _ in 100 * 1024 * 1024 * 1024 })
        defer { harness.tearDown() }

        let transferID = ClipboardTransferID.make(generation: 11, repIndex: 0, hostMinted: true)

        let firstBox = RepBox()
        harness.receiver.awaitTransfer(
            transferID,
            onComplete: { _ in Issue.record("attempt #1's awaiter was overwritten — must never fire") },
            onAbort: { firstBox.setAbort($0) })

        let secondBox = RepBox()
        let secondGate = AsyncGate()
        harness.receiver.awaitTransfer(
            transferID,
            onComplete: {
                secondBox.setRep($0)
                secondGate.notify()
            },
            onAbort: {
                secondBox.setAbort($0)
                secondGate.notify()
            })

        // The straggler: attempt #1's delayed cancel/abort signal, arriving now
        // that attempt #2 owns the registration for this id.
        harness.receiver.handleAbort(
            .with {
                $0.transferID = transferID
                $0.code = "cancelled"
                $0.message = "stale abort from attempt #1"
            })

        try await secondGate.wait { secondBox.abortInfo != nil }
        #expect(secondBox.abortInfo?.code == "cancelled")
        #expect(firstBox.abortInfo == nil)  // #1's own onAbort never fired — it was already overwritten

        // The table is left fully consistent: a THIRD attempt reusing the
        // identical id — the normal "restart after abort is cheap, no
        // orphaned state" case (CLIPBOARD.md §9) — completes cleanly.
        let thirdBox = RepBox()
        let thirdGate = AsyncGate()
        harness.receiver.awaitTransfer(
            transferID,
            onComplete: {
                thirdBox.setRep($0)
                thirdGate.notify()
            },
            onAbort: {
                thirdBox.setAbort($0)
                thirdGate.notify()
            })
        let rep = inlineRep("attempt three")
        harness.sender.startTransfer(
            transferID: transferID, generation: 11, representation: rep, maxAcceptByteCount: .max,
            isInline: true, isCurrent: { _ in true })

        try await thirdGate.wait { thirdBox.representation != nil }
        #expect(thirdBox.representation?.inMemoryData == Data("attempt three".utf8))
    }

    // MARK: - cancelBeforeStart (#464 review fix)

    @Test(
        "cancelBeforeStart marks a transferID so pull() resolves .cancelled without ever calling send"
    )
    func cancelBeforeStartPreventsSend() async throws {
        // Closes the race a review found: a consumer cancel (#464) that arrives
        // before the owner's `pull` call has even registered a slot — because
        // the fetch is dispatched onto a concurrent queue and hasn't started
        // yet — used to be silently lost, so the request went out over vsock
        // regardless. This proves it no longer does.
        let coordinator = LazyPullCoordinator()
        let sendCalled = Box(false)

        coordinator.cancelBeforeStart(42)
        #expect(coordinator.preCancelledCountForTesting == 1)

        let outcome = await runPull(coordinator, transferID: 42, timeout: .seconds(5)) {
            sendCalled.value = true
        }

        guard case .cancelled = outcome else {
            Issue.record("expected .cancelled, got \(outcome)")
            return
        }
        #expect(sendCalled.value == false)
        // One-shot: the mark is consumed, not left to leak or double-apply to a
        // later, unrelated pull that reuses the same transferID.
        #expect(coordinator.preCancelledCountForTesting == 0)
        #expect(coordinator.pendingSlotCountForTesting == 0)
    }

    @Test("cancelBeforeStart resolves an already-registered slot immediately with .cancelled")
    func cancelBeforeStartResolvesParkedPull() async throws {
        let coordinator = LazyPullCoordinator()
        let sendRan = Box(false)
        let gate = AsyncGate()

        let pullTask = Task {
            await runPull(coordinator, transferID: 7, timeout: .seconds(5)) {
                sendRan.value = true
                gate.notify()
            }
        }

        // `send` only runs after the slot is registered, so this proves the
        // pull is genuinely parked before cancelling it.
        try await gate.wait { sendRan.value }
        #expect(coordinator.pendingSlotCountForTesting == 1)

        coordinator.cancelBeforeStart(7)

        let outcome = await pullTask.value
        guard case .cancelled = outcome else {
            Issue.record("expected .cancelled, got \(outcome)")
            return
        }
        #expect(coordinator.pendingSlotCountForTesting == 0)
        #expect(coordinator.preCancelledCountForTesting == 0)
    }

    @Test("cancelBeforeStart for an unrelated transferID does not affect a different in-flight pull")
    func cancelBeforeStartIsScopedToItsOwnTransferID() async throws {
        let coordinator = LazyPullCoordinator()

        coordinator.cancelBeforeStart(999)

        let outcome = await runPull(coordinator, transferID: 1, timeout: .seconds(5)) {
            coordinator.deliver(1, ClipboardContent.Representation(uti: "public.data", data: Data()))
        }

        guard case .delivered = outcome else {
            Issue.record("expected the unrelated transfer to deliver normally, got \(outcome)")
            return
        }
        #expect(coordinator.preCancelledCountForTesting == 1)  // still pending for id 999
    }
}
