import Foundation
import Testing

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

    /// A `Sendable` tally for counting off-actor `onProgress` callbacks.
    private final class ProgressCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
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
        let coordinator = LazyPullCoordinator()
        // A short window: an absolute deadline would fire long before delivery.
        async let outcome = runPull(coordinator, transferID: 11, timeout: .milliseconds(300))
        try await pollUntil { coordinator.pendingSlotCountForTesting == 1 }
        // Beat far faster than the window for well over a window's worth of
        // wall-clock, so an un-reset (absolute) backstop would have fired by now.
        for _ in 0..<24 {
            try await Task.sleep(for: .milliseconds(25))
            coordinator.heartbeat(11)
        }
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
            onProgress: { progress.bump() })

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
}
