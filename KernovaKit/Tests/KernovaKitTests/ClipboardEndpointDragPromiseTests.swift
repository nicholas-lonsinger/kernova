import Foundation
import KernovaSynchronization
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// File-promise items in a guest drag: offered as their type alone, named by
/// the guest once the host has them called in, and pulled one at a time as the
/// guest says each is written.
@Suite("ClipboardEndpoint drag promises", .caseScoped)
@MainActor
struct ClipboardEndpointDragPromiseTests {
    /// The longest a test parks the main thread: far below `testWaitBackstop`,
    /// so a lost wakeup fails this test alone rather than freezing every
    /// concurrent test's main-actor work.
    private static let mainHoldWindow: TimeInterval = 5

    private static let file = RepInfo(
        uti: "public.data", byteCount: 8, filename: "a.bin", isInline: false)
    /// A promise whose guest also sent a name and a size, which intake drops.
    private static let promisedImage = RepInfo(
        uti: "public.jpeg", byteCount: 99, filename: "sneaky.jpg", isInline: true)
    private static let promisedFolder = RepInfo(
        uti: "public.folder", byteCount: 0, isInline: false, isDirectory: true)

    /// A host drop channel holding drag 1: a plain file at 0, a promised
    /// image at 1 and a promised folder at 2.
    private func hostHoldingPromises() async throws -> RawPeerHarness {
        let harness = try RawPeerHarness(role: .host, kind: .drop)
        try harness.send(
            .dragOffer(
                generation: 1,
                reps: [Self.file.wire, Self.promisedImage.wire, Self.promisedFolder.wire],
                promised: [1, 2, 7]))
        try await harness.side.recorder.waitForDrag()
        return harness
    }

    private nonisolated static func isResolve(_ frame: Frame) -> Bool {
        if case .dragResolve(let resolve) = frame.payload { return resolve.generation == 1 }
        return false
    }

    /// Answers the host's `DragResolve` from off the main thread, so it lands
    /// while the main thread is parked waiting for it.
    private func answerResolve(
        on harness: RawPeerHarness, with answer: @escaping @Sendable (VsockChannel) throws -> Void
    ) -> Task<Void, any Error> {
        let recorder = harness.recorder
        let peer = harness.peer
        return Task.detached {
            try await recorder.waitForFrames { recorder.frames.contains(where: Self.isResolve) }
            try answer(peer)
        }
    }

    private func resolveCount(_ harness: RawPeerHarness) -> Int {
        harness.recorder.frames.filter(Self.isResolve).count
    }

    // MARK: - Host intake

    @Test("a promised item reaches the host promised and unnamed, its declared name and size dropped")
    func promisedIntake() async throws {
        let harness = try await hostHoldingPromises()
        defer { harness.tearDown() }

        let drag = try #require(harness.side.recorder.drags.last)
        #expect(drag.items.map(\.isPromised) == [false, true, true])
        #expect(drag.items.map(\.filename) == ["a.bin", nil, nil])
        #expect(drag.items.map(\.type.identifier) == ["public.data", "public.jpeg", "public.folder"])
        #expect(drag.items.map(\.isDirectory) == [false, false, true])
        // A promise has no size until the guest writes it.
        #expect(harness.endpoint.inboundByteCount(generation: 1) == 8)
        #expect(harness.endpoint.resolvedDragNames(generation: 1) == nil)
    }

    // MARK: - Naming, the main thread parked

    @Test("the names reach a resolve parked on the main thread, which releases the guest's button on it")
    func resolveWhileTheMainThreadIsParked() async throws {
        let harness = try await hostHoldingPromises()
        defer { harness.tearDown() }
        harness.endpoint.setDragNamingEventLoopWaitForTesting { nil }
        let answered = answerResolve(on: harness) { peer in
            try peer.send(.dragHandOff(generation: 1, step: .resolving))
        }
        let peer = harness.peer
        let releases = Locked<[Bool]>([])

        let result = harness.endpoint.resolveDragNames(
            generation: 1, deadline: .now() + Self.mainHoldWindow
        ) {
            releases.withLock { $0.append(Thread.isMainThread) }
            // The names follow the guest's drop, which this release causes.
            try? peer.send(
                .dragNames(
                    generation: 1,
                    filenames: [1: "../IMG_0001.jpeg", 2: "Album", 0: "not-promised.bin"]))
        }

        try await answered.value
        #expect(result == .success([1: "IMG_0001.jpeg", 2: "Album"]))
        #expect(releases.withLock { $0 } == [true])
        #expect(harness.endpoint.resolvedDragNames(generation: 1) == [1: "IMG_0001.jpeg", 2: "Album"])

        // A second ask is answered from what the first settled: nothing is
        // sent and nothing released again.
        let before = harness.recorder.count
        let again = harness.endpoint.resolveDragNames(
            generation: 1, deadline: .now() + Self.mainHoldWindow
        ) { releases.withLock { $0.append(Thread.isMainThread) } }
        #expect(again == result)
        #expect(releases.withLock { $0 }.count == 1)
        try await harness.recorder.expectNoNewFrames(
            sinceCount: before, aheadOfMarkerOn: harness.side.channel)
        #expect(resolveCount(harness) == 1)
    }

    @Test("the guest's STAGE_FAILED fails a parked resolve, with nothing released")
    func handOffFailureFailsTheResolve() async throws {
        let harness = try await hostHoldingPromises()
        defer { harness.tearDown() }
        harness.endpoint.setDragNamingEventLoopWaitForTesting { nil }
        let answered = answerResolve(on: harness) { peer in
            try peer.send(
                .dragHandOff(generation: 1, step: .failed(.dragTakeRefused, message: "no catcher")))
        }
        let releases = Locked(0)

        let result = harness.endpoint.resolveDragNames(
            generation: 1, deadline: .now() + Self.mainHoldWindow
        ) { releases.withLock { $0 += 1 } }

        try await answered.value
        #expect(result == .failure(.handOffFailed(.dragTakeRefused)))
        #expect(releases.withLock { $0 } == 0)
        // The step still reaches the owner, as every hand-off step does.
        try await harness.side.recorder.wait { !harness.side.recorder.handOffs.isEmpty }
    }

    @Test("the guest withdrawing the drag fails a parked resolve")
    func withdrawalFailsTheResolve() async throws {
        let harness = try await hostHoldingPromises()
        defer { harness.tearDown() }
        harness.endpoint.setDragNamingEventLoopWaitForTesting { nil }
        let answered = answerResolve(on: harness) { peer in
            try peer.send(.dragRelease(generation: 1))
        }

        let result = harness.endpoint.resolveDragNames(
            generation: 1, deadline: .now() + Self.mainHoldWindow
        ) {}

        try await answered.value
        #expect(result == .failure(.dragNotLive))
    }

    @Test("the session ending fails a parked resolve, and every later one")
    func sessionEndFailsTheResolve() async throws {
        let harness = try await hostHoldingPromises()
        defer { harness.tearDown() }
        harness.endpoint.setDragNamingEventLoopWaitForTesting { nil }
        let answered = answerResolve(on: harness) { peer in peer.close() }

        let result = harness.endpoint.resolveDragNames(
            generation: 1, deadline: .now() + Self.mainHoldWindow
        ) {}

        try await answered.value
        #expect(result == .failure(.sessionEnded))
        #expect(
            harness.endpoint.resolveDragNames(generation: 1, deadline: .now()) {}
                == .failure(.sessionEnded))
    }

    @Test("the deadline fails a resolve the guest never answers, and that failure stands")
    func deadlineFailsTheResolve() async throws {
        let harness = try await hostHoldingPromises()
        defer { harness.tearDown() }
        harness.endpoint.setDragNamingEventLoopWaitForTesting { nil }
        let releases = Locked(0)

        // The deadline is the behavior under test.
        let result = harness.endpoint.resolveDragNames(generation: 1, deadline: .now() + 0.2) {
            releases.withLock { $0 += 1 }
        }

        #expect(result == .failure(.timedOut))
        // A later ask does not wait out a deadline of its own, nor ask again.
        #expect(
            harness.endpoint.resolveDragNames(
                generation: 1, deadline: .now() + Self.mainHoldWindow
            ) { releases.withLock { $0 += 1 } } == .failure(.timedOut))
        #expect(releases.withLock { $0 } == 0)
        try await harness.recorder.waitForFrames { resolveCount(harness) == 1 }
        try await harness.recorder.expectNoNewFrames(
            sinceCount: harness.recorder.count, aheadOfMarkerOn: harness.side.channel)
        #expect(resolveCount(harness) == 1)
    }

    // MARK: - Naming off the main thread

    @Test("retiring the drag fails a resolve waiting off the main thread")
    func retirementFailsTheResolve() async throws {
        let harness = try await hostHoldingPromises()
        defer { harness.tearDown() }
        let endpoint = harness.endpoint
        let resolution = Task {
            await offCooperativePool {
                endpoint.resolveDragNames(generation: 1, deadline: .now() + testWaitBackstop) {}
            }
        }
        try await harness.recorder.waitForFrames { resolveCount(harness) == 1 }

        endpoint.completeDrag(generation: 1)

        #expect(await resolution.value == .failure(.dragNotLive))
        #expect(
            endpoint.resolveDragNames(generation: 1, deadline: .now()) {} == .failure(.dragNotLive))
    }

    @Test("a resolve asked while one is in flight joins it: one ask, one release, the same names")
    func aSecondResolveJoinsTheFirst() async throws {
        let harness = try await hostHoldingPromises()
        defer { harness.tearDown() }
        let endpoint = harness.endpoint
        let releases = Locked(0)
        let released = AsyncGate()
        let first = Task {
            await offCooperativePool {
                endpoint.resolveDragNames(generation: 1, deadline: .now() + testWaitBackstop) {
                    releases.withLock { $0 += 1 }
                    released.notify()
                }
            }
        }
        try await harness.recorder.waitForFrames { resolveCount(harness) == 1 }
        let second = Task {
            await offCooperativePool {
                endpoint.resolveDragNames(generation: 1, deadline: .now() + testWaitBackstop) {
                    releases.withLock { $0 += 1 }
                }
            }
        }

        try harness.send(.dragHandOff(generation: 1, step: .resolving))
        try await released.wait { releases.withLock { $0 } == 1 }
        try harness.send(.dragNames(generation: 1, filenames: [1: "IMG_0002.jpeg"]))

        #expect(await first.value == .success([1: "IMG_0002.jpeg"]))
        #expect(await second.value == .success([1: "IMG_0002.jpeg"]))
        #expect(releases.withLock { $0 } == 1)
        #expect(resolveCount(harness) == 1)
    }

    @Test("a drag with no promised items is named at once, with nothing asked")
    func aDragWithoutPromisesNeedsNoNames() async throws {
        let harness = try RawPeerHarness(role: .host, kind: .drop)
        defer { harness.tearDown() }
        try harness.send(.dragOffer(generation: 1, reps: [Self.file.wire]))
        try await harness.side.recorder.waitForDrag()
        let before = harness.recorder.count

        let result = harness.endpoint.resolveDragNames(generation: 1, deadline: .now()) {
            Issue.record("Nothing is promised, so nothing is released")
        }

        #expect(result == .success([:]))
        try await harness.recorder.expectNoNewFrames(
            sinceCount: before, aheadOfMarkerOn: harness.side.channel)
    }

    // MARK: - Per-item readiness

    /// Counts the pulls that have started waiting for a drag item's size.
    private final class SizeWaits: Sendable {
        let gate = AsyncGate()
        private let count = Locked(0)

        @MainActor
        init(on endpoint: ClipboardEndpoint) {
            endpoint.onInboundSizeWaitForTesting { [count, gate] in
                count.withLock { $0 += 1 }
                gate.notify()
            }
        }

        func wait(for started: Int) async throws {
            try await gate.wait { self.count.withLock { $0 } == started }
        }
    }

    @Test("each DragSizes releases only the pulls of the items it lists, and refuses the unavailable ones")
    func sizesReleaseOnlyTheirItems() async throws {
        let harness = try await hostHoldingPromises()
        defer { harness.tearDown() }
        let waits = SizeWaits(on: harness.endpoint)
        let operation = harness.side.makeOperation(gesture: .dragOut, direction: .inbound)
        let image = harness.side.startPull(generation: 1, repIndex: 1, operation: operation)
        let folder = harness.side.startPull(generation: 1, repIndex: 2, operation: operation)
        try await waits.wait(for: 2)

        try harness.send(.dragSizes(generation: 1, byteCounts: [1: 4]))

        try await harness.waitForRequest(generation: 1, repIndex: 1)
        #expect(harness.endpoint.inboundByteCount(generation: 1) == 12)
        let folderID = harness.transferID(generation: 1, repIndex: 2)
        #expect(!harness.recorder.requests.contains { $0.transferID == folderID })

        try harness.send(.dragSizes(generation: 1, byteCounts: [:], unavailable: [2]))

        guard case .unavailable = await folder.value else {
            Issue.record("Expected the unavailable item's pull to be refused as unavailable")
            return
        }
        // Asked again, it is refused at once, without waiting.
        guard
            case .unavailable = await harness.side.startPull(
                generation: 1, repIndex: 2, operation: operation
            ).value
        else {
            Issue.record("Expected a later pull of the unavailable item to be refused too")
            return
        }
        #expect(!harness.recorder.requests.contains { $0.transferID == folderID })
        harness.endpoint.completeDrag(generation: 1)
        _ = await image.value
    }

    // MARK: - Guest side

    /// A guest drop channel that has offered drag 1: a file at 0 and a promised
    /// image at 1.
    private func guestOfferingAPromise() throws -> RawPeerHarness {
        let harness = try RawPeerHarness(role: .guest, kind: .drop)
        let file = try makeFileRepresentation(named: "one.bin", bytes: Data("one".utf8))
        #expect(
            harness.endpoint.offerDrag([
                .file(file.representation), .promise(uti: "public.jpeg", isDirectory: false),
            ]) == .sent(generation: 1))
        return harness
    }

    private func sentSizes(_ harness: RawPeerHarness) -> [Kernova_V1_DragSizes] {
        harness.recorder.frames.compactMap { frame in
            if case .dragSizes(let sizes) = frame.payload { return sizes }
            return nil
        }
    }

    /// Asks the guest under `harness` for item `repIndex` of drag 1, as the
    /// host does, returning the peer end of the connection it dials.
    private func requestItem(_ harness: RawPeerHarness, repIndex: Int, uti: String) async throws
        -> Int32
    {
        try harness.send(
            makeRequestFrame(
                generation: 1, transferID: harness.peerTransferID(generation: 1, repIndex: repIndex),
                uti: uti))
        return try await harness.nextDialledConnection()
    }

    @Test("the guest offers a promise as its type alone, at the index it names as promised")
    func guestOffersAPromise() async throws {
        let harness = try guestOfferingAPromise()
        defer { harness.tearDown() }

        try await harness.recorder.waitForFrames { !harness.recorder.frames.isEmpty }
        guard case .dragOffer(let offer) = harness.recorder.frames.first?.payload else {
            Issue.record("Expected the drag offer")
            return
        }
        #expect(offer.promised == [1])
        let promise = offer.repInfo[1]
        #expect(promise.uti == "public.jpeg")
        #expect(promise.filename.isEmpty)
        #expect(promise.byteCount == 0)
        #expect(!promise.isInline)
        #expect(!promise.isDirectory)
        #expect(offer.repInfo[0].filename == "one.bin")
    }

    @Test("a promise is refused until its file lands, then served, and its size goes to the host")
    func guestServesAPromiseOnceResolved() async throws {
        let harness = try guestOfferingAPromise()
        defer { harness.tearDown() }

        let early = try await requestItem(harness, repIndex: 1, uti: "public.jpeg")
        let refusal = try #require(await offCooperativePool { readTransferReply(fd: early) })
        ClipboardDataConnection.end(fd: early)
        #expect(refusal.refusalCode == ClipboardStreamAbortCode.readError.rawValue)

        let payload = Data("jpeg bytes".utf8)
        let landed = try makeFileRepresentation(named: "IMG_0001.jpeg", bytes: payload)
        #expect(
            harness.endpoint.resolvePromisedDragItem(
                generation: 1, repIndex: 1, fileURL: landed.url, byteCount: payload.count))
        // Once only: the item is no longer a pending promise.
        #expect(
            !harness.endpoint.resolvePromisedDragItem(
                generation: 1, repIndex: 1, fileURL: landed.url, byteCount: payload.count))

        try await harness.recorder.waitForFrames { !sentSizes(harness).isEmpty }
        #expect(sentSizes(harness).map(\.byteCounts) == [[1: UInt64(payload.count)]])
        let content = try #require(harness.endpoint.outboundContent(generation: 1))
        #expect(content.representations[1].filename == "IMG_0001.jpeg")
        #expect(content.representations[1].uti == "public.jpeg")

        let served = try await requestItem(harness, repIndex: 1, uti: "public.jpeg")
        let received = await offCooperativePool { try? receiveTransfer(fd: served) }
        #expect(try #require(received).isComplete)
    }

    @Test("the guest sends the promised items' names, dropping any other index, and none for a drag gone")
    func guestSendsNames() async throws {
        let harness = try guestOfferingAPromise()
        defer { harness.tearDown() }

        #expect(
            harness.endpoint.sendDragNames(
                generation: 1, filenames: [1: "IMG_0001.jpeg", 0: "one.bin"]))
        #expect(!harness.endpoint.sendDragNames(generation: 9, filenames: [1: "x"]))

        try await harness.recorder.waitForFrames {
            harness.recorder.frames.contains { if case .dragNames = $0.payload { true } else { false } }
        }
        let sent = harness.recorder.frames.compactMap { frame -> Kernova_V1_DragNames? in
            if case .dragNames(let names) = frame.payload { return names }
            return nil
        }
        #expect(sent.map(\.generation) == [1])
        #expect(sent.first?.filenames == [1: "IMG_0001.jpeg"])
    }

    @Test("a promise its source failed is sent as unavailable once, and never served")
    func guestMarksAPromiseUnavailable() async throws {
        let harness = try guestOfferingAPromise()
        defer { harness.tearDown() }

        #expect(harness.endpoint.markPromisedDragItemsUnavailable(generation: 1, repIndices: [0, 1]))
        #expect(!harness.endpoint.markPromisedDragItemsUnavailable(generation: 1, repIndices: [1]))
        let landed = try makeFileRepresentation(named: "late.jpeg", bytes: Data("late".utf8))
        #expect(
            !harness.endpoint.resolvePromisedDragItem(
                generation: 1, repIndex: 1, fileURL: landed.url, byteCount: 4))

        try await harness.recorder.waitForFrames { !sentSizes(harness).isEmpty }
        #expect(sentSizes(harness).map(\.unavailable) == [[1]])
        #expect(sentSizes(harness).first?.byteCounts.isEmpty == true)

        let fd = try await requestItem(harness, repIndex: 1, uti: "public.jpeg")
        let refusal = try #require(await offCooperativePool { readTransferReply(fd: fd) })
        ClipboardDataConnection.end(fd: fd)
        #expect(refusal.refusalCode == ClipboardStreamAbortCode.readError.rawValue)
    }

    @Test("the host's DragResolve reaches the guest's owner")
    func resolveReachesTheGuestsOwner() async throws {
        let harness = try guestOfferingAPromise()
        defer { harness.tearDown() }

        try harness.send(.dragResolve(generation: 1))

        try await harness.side.recorder.wait { harness.side.recorder.resolves == [1] }
    }

    @Test("the promise senders on the host's end send nothing, and naming on the guest's names nothing")
    func promiseSendersAreRoleBound() async throws {
        let host = try RawPeerHarness(role: .host, kind: .drop)
        defer { host.tearDown() }
        #expect(host.endpoint.offerDrag([.promise(uti: "public.jpeg", isDirectory: false)]) == .sendFailed)
        #expect(!host.endpoint.sendDragNames(generation: 1, filenames: [0: "a"]))
        #expect(!host.endpoint.markPromisedDragItemsUnavailable(generation: 1, repIndices: [0]))
        try await host.recorder.expectNoNewFrames(sinceCount: 0, aheadOfMarkerOn: host.side.channel)

        let guest = try guestOfferingAPromise()
        defer { guest.tearDown() }
        #expect(guest.endpoint.resolveDragNames(generation: 1, deadline: .now()) {} == .failure(.dragNotLive))
        #expect(guest.endpoint.resolvedDragNames(generation: 1) == nil)
    }

    // MARK: - End to end

    @Test("a promise named, written and pulled end to end lands under the name the guest gave it")
    func promiseEndToEnd() async throws {
        let pair = try EndpointPair(kind: .drop)
        defer { pair.tearDown() }
        let file = try makeFileRepresentation(named: "one.bin", bytes: Data("one".utf8))
        #expect(
            pair.guest.endpoint.offerDrag([
                .file(file.representation), .promise(uti: "public.jpeg", isDirectory: false),
            ]) == .sent(generation: 1))
        let drag = try await pair.host.recorder.waitForDrag()
        #expect(drag.items.map(\.isPromised) == [false, true])

        let host = pair.host.endpoint
        let released = AsyncGate()
        let releases = Locked(0)
        let resolution = Task {
            await offCooperativePool {
                host.resolveDragNames(generation: 1, deadline: .now() + testWaitBackstop) {
                    releases.withLock { $0 += 1 }
                    released.notify()
                }
            }
        }
        try await pair.guest.recorder.wait { pair.guest.recorder.resolves == [1] }
        pair.guest.endpoint.sendDragHandOff(generation: 1, step: .resolving)
        try await released.wait { releases.withLock { $0 } == 1 }
        #expect(pair.guest.endpoint.sendDragNames(generation: 1, filenames: [1: "IMG_0001.jpeg"]))
        #expect(await resolution.value == .success([1: "IMG_0001.jpeg"]))

        let operation = pair.host.makeOperation(gesture: .dragOut, direction: .inbound)
        let pull = pair.host.startPull(generation: 1, repIndex: 1, operation: operation)
        let payload = Data("jpeg bytes".utf8)
        let landed = try makeFileRepresentation(named: "IMG_0001.jpeg", bytes: payload)
        #expect(
            pair.guest.endpoint.resolvePromisedDragItem(
                generation: 1, repIndex: 1, fileURL: landed.url, byteCount: payload.count))

        guard case .delivered(let representation) = await pull.value else {
            Issue.record("Expected the promised item to be delivered")
            return
        }
        let url = try #require(representation.fileURL)
        #expect(url.lastPathComponent == "IMG_0001.jpeg")
        #expect(try Data(contentsOf: url) == payload)
        #expect(pair.host.endpoint.inboundByteCount(generation: 1) == UInt64(3 + payload.count))
    }
}
