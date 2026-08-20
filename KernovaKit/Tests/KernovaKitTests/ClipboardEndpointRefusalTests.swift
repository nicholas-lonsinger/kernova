import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// What a connection refuses and how it says so: the paste-budget gate, the
/// free-space pre-flight, the outcomes a failed pull maps to, the `Error` frame
/// a guest owes its peer, and what a stopped connection still serves.
@Suite("ClipboardEndpoint refusals", .admissionGated)
@MainActor
struct ClipboardEndpointRefusalTests {
    private let textUTI = ClipboardContent.utf8TextUTI
    private let imageUTI = "public.png"

    /// Small enough that a test states a file size against it without building
    /// one, and far under any real volume's capacity.
    private let cap = 1_000_000

    private func fileRep(_ name: String, bytes: UInt64) -> RepInfo {
        RepInfo(uti: "public.data", byteCount: bytes, filename: name, isInline: false)
    }

    // MARK: - The paste budget

    @Test("a file set over the cap is refused whole at the fire, before any request")
    func overCapFileSetIsRefused() async throws {
        let harness = try RawPeerHarness(pasteLimit: cap)
        defer { harness.tearDown() }
        try harness.send(
            makeOfferFrame(generation: 1, reps: [fileRep("big.bin", bytes: UInt64(cap) + 1)]))
        try await harness.side.recorder.waitForOffer()

        let url = await harness.side.serveFileURLOffMain(generation: 1, repIndex: 0)
        #expect(url == nil)

        let refusal = try await harness.side.recorder.waitForRefusal()
        #expect(refusal.gesture == .copy)
        #expect(refusal.failure == .tooLarge(limitBytes: cap))
        #expect(harness.recorder.requests.isEmpty)

        let budget = try #require(harness.endpoint.pasteBudget(generation: 1))
        #expect(budget.total == UInt64(cap) + 1)
        #expect(budget.limit == cap)
        #expect(budget.exceeds)
    }

    @Test("files each under the cap are refused when their sum is over it")
    func underCapFilesSummingOverAreRefused() async throws {
        let harness = try RawPeerHarness(pasteLimit: cap)
        defer { harness.tearDown() }
        let half = UInt64(cap / 2) + 1
        try harness.send(
            makeOfferFrame(
                generation: 1,
                reps: [fileRep("a.bin", bytes: half), fileRep("b.bin", bytes: half)]))
        try await harness.side.recorder.waitForOffer()

        let url = await harness.side.serveFileURLOffMain(generation: 1, repIndex: 0)
        #expect(url == nil)
        let refusal = try await harness.side.recorder.waitForRefusal()
        #expect(refusal.failure == .tooLarge(limitBytes: cap))
        #expect(harness.recorder.requests.isEmpty)
    }

    @Test("a file set exactly at the cap is within it and asks for its bytes")
    func atCapFileSetIsNotRefused() async throws {
        let harness = try RawPeerHarness(pasteLimit: cap)
        defer { harness.tearDown() }
        try harness.send(
            makeOfferFrame(generation: 1, reps: [fileRep("exact.bin", bytes: UInt64(cap))]))
        try await harness.side.recorder.waitForOffer()

        let serve = harness.side.startFileURLServe(generation: 1, repIndex: 0)
        try await harness.waitForRequest(generation: 1, repIndex: 0)
        // Nothing is going to stream; wake the fire rather than leave it parked.
        try harness.refuseTransfer(
            generation: 1, repIndex: 0, code: ClipboardStreamAbortCode.cancelled.rawValue)
        _ = await serve.value
        #expect(harness.side.recorder.refusals.isEmpty)
    }

    @Test("a folder counts against the cap by the estimate its offer declares")
    func directoryCountsByItsEstimate() async throws {
        let harness = try RawPeerHarness(pasteLimit: cap)
        defer { harness.tearDown() }
        try harness.send(
            makeOfferFrame(
                generation: 1,
                reps: [
                    RepInfo(
                        uti: ClipboardArchive.directoryUTI, byteCount: UInt64(cap) + 1,
                        filename: "Folder", isInline: false, isDirectory: true)
                ]))
        try await harness.side.recorder.waitForOffer()

        let url = await harness.side.serveFileURLOffMain(generation: 1, repIndex: 0)
        #expect(url == nil)
        let refusal = try await harness.side.recorder.waitForRefusal()
        #expect(refusal.failure == .tooLarge(limitBytes: cap))
        #expect(harness.recorder.requests.isEmpty)
    }

    @Test("an over-cap image file still serves its inline flavor")
    func overCapImageStillServesInline() async throws {
        let harness = try RawPeerHarness(pasteLimit: cap)
        defer { harness.tearDown() }
        try harness.send(
            makeOfferFrame(
                generation: 1,
                reps: [
                    RepInfo(
                        uti: imageUTI, byteCount: UInt64(cap) + 1, filename: "big.png",
                        isInline: true)
                ]))
        try await harness.side.recorder.waitForOffer()

        #expect(await harness.side.serveFileURLOffMain(generation: 1, repIndex: 0) == nil)

        // Kernova caps no inline payload, so the flavor a paste reads is served.
        let payload = Data("png bytes".utf8)
        let serve = harness.side.startDataServe(generation: 1, repIndex: 0, uti: imageUTI)
        try await harness.waitForRequest(generation: 1, repIndex: 0)
        try harness.streamInline(generation: 1, repIndex: 0, payload: payload)
        #expect(await serve.value == payload)
    }

    @Test("the ceiling is read at each fire, so raising it lets the same one through")
    func ceilingIsReadLive() async throws {
        let harness = try RawPeerHarness(pasteLimit: cap)
        defer { harness.tearDown() }
        try harness.send(
            makeOfferFrame(generation: 1, reps: [fileRep("big.bin", bytes: UInt64(cap) + 1)]))
        try await harness.side.recorder.waitForOffer()

        #expect(await harness.side.serveFileURLOffMain(generation: 1, repIndex: 0) == nil)
        try await harness.side.recorder.waitForRefusal()

        harness.side.pasteLimit.value = cap * 4
        let serve = harness.side.startFileURLServe(generation: 1, repIndex: 0)
        try await harness.waitForRequest(generation: 1, repIndex: 0)
        try harness.refuseTransfer(
            generation: 1, repIndex: 0, code: ClipboardStreamAbortCode.cancelled.rawValue)
        _ = await serve.value
    }

    @Test("declared sizes are bounded at intake, so an absurd total cannot wrap under the cap")
    func saturatingTotalsAreBoundedAtIntake() async throws {
        let harness = try RawPeerHarness(pasteLimit: cap)
        defer { harness.tearDown() }
        try harness.send(
            makeOfferFrame(
                generation: 1,
                reps: [
                    fileRep("a.bin", bytes: .max), fileRep("b.bin", bytes: .max),
                ]))
        try await harness.side.recorder.waitForOffer()

        let budget = try #require(harness.endpoint.pasteBudget(generation: 1))
        #expect(budget.total == 2 * ClipboardOfferBounds.maxDeclaredByteCount)
        #expect(budget.exceeds)
        #expect(await harness.side.serveFileURLOffMain(generation: 1, repIndex: 0) == nil)
    }

    // MARK: - Free-space pre-flight

    @Test("a volume with no room refuses a file fire before it asks for a byte")
    func fullVolumeRefusesFileFire() async throws {
        let harness = try RawPeerHarness(freeSpaceProvider: { _ in 0 })
        defer { harness.tearDown() }
        try harness.send(
            makeOfferFrame(generation: 1, reps: [fileRep("a.bin", bytes: 4096)]))
        try await harness.side.recorder.waitForOffer()

        #expect(await harness.side.serveFileURLOffMain(generation: 1, repIndex: 0) == nil)
        let refusal = try await harness.side.recorder.waitForRefusal()
        #expect(refusal.gesture == .paste)
        #expect(isDiskFull(refusal.failure))
        #expect(harness.recorder.requests.isEmpty)
    }

    @Test("the file flavor of an inline image lands on disk, so it pre-flights too")
    func fullVolumeRefusesInlineImageFileFlavor() async throws {
        let harness = try RawPeerHarness(freeSpaceProvider: { _ in 0 })
        defer { harness.tearDown() }
        try harness.send(
            makeOfferFrame(
                generation: 1,
                reps: [
                    RepInfo(uti: imageUTI, byteCount: 4096, filename: "shot.png", isInline: true)
                ]))
        try await harness.side.recorder.waitForOffer()

        #expect(await harness.side.serveFileURLOffMain(generation: 1, repIndex: 0) == nil)
        let refusal = try await harness.side.recorder.waitForRefusal()
        #expect(isDiskFull(refusal.failure))
        #expect(harness.recorder.requests.isEmpty)
    }

    @Test("an inline fire pre-flights nothing — its bytes never land on disk")
    func inlineFireRunsNoPreflight() async throws {
        let harness = try RawPeerHarness(freeSpaceProvider: { _ in 0 })
        defer { harness.tearDown() }
        try harness.send(makeTextOfferFrame(generation: 1, text: "inline"))
        try await harness.side.recorder.waitForOffer()

        let serve = harness.side.startDataServe(generation: 1, repIndex: 0, uti: textUTI)
        try await harness.waitForRequest(generation: 1, repIndex: 0)
        try harness.streamInline(generation: 1, repIndex: 0, payload: Data("inline".utf8))
        #expect(await serve.value == Data("inline".utf8))
        #expect(harness.side.recorder.refusals.isEmpty)
    }

    // MARK: - What a pull's outcome owes

    @Test("an abort mid-stream reports the failure its code names")
    func abortMidStreamReportsItsFailure() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        try harness.send(makeTextOfferFrame(generation: 1, text: "inline"))
        try await harness.side.recorder.waitForOffer()

        let serve = harness.side.startDataServe(generation: 1, repIndex: 0, uti: textUTI)
        try await harness.waitForRequest(generation: 1, repIndex: 0)
        try harness.abortTransfer(
            generation: 1, repIndex: 0, code: ClipboardStreamAbortCode.diskFull.rawValue,
            sent: Data("par".utf8), declaredBytes: 32)

        #expect(await serve.value == nil)
        let refusal = try await harness.side.recorder.waitForRefusal()
        #expect(refusal.gesture == .paste)
        #expect(isDiskFull(refusal.failure))
    }

    @Test("a retiring abort code explains itself and reports nothing")
    func retiringAbortReportsNothing() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        try harness.send(makeTextOfferFrame(generation: 1, text: "inline"))
        try await harness.side.recorder.waitForOffer()

        let serve = harness.side.startDataServe(generation: 1, repIndex: 0, uti: textUTI)
        try await harness.waitForRequest(generation: 1, repIndex: 0)
        try harness.abortTransfer(
            generation: 1, repIndex: 0, code: ClipboardStreamAbortCode.superseded.rawValue,
            sent: Data("par".utf8), declaredBytes: 32)

        #expect(await serve.value == nil)
        try await harness.side.recorder.expectNoNewRefusals(sinceCount: 0)
    }

    @Test("an abort code this build does not define is a failure, not a silent retirement")
    func undefinedAbortCodeIsAFailure() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        try harness.send(makeTextOfferFrame(generation: 1, text: "inline"))
        try await harness.side.recorder.waitForOffer()

        let serve = harness.side.startDataServe(generation: 1, repIndex: 0, uti: textUTI)
        try await harness.waitForRequest(generation: 1, repIndex: 0)
        try harness.abortTransfer(
            generation: 1, repIndex: 0, code: "some.future.code", sent: Data("par".utf8),
            declaredBytes: 32)

        #expect(await serve.value == nil)
        let refusal = try await harness.side.recorder.waitForRefusal()
        #expect(refusal.failure == .transferFailed)
    }

    @Test("a peer that never answers times the pull out and tells it to stop")
    func silentPeerTimesOutAndAborts() async throws {
        // The deadline is the behavior under test, and the fire holds a GCD
        // thread rather than the main one, so it is sized for the test.
        let harness = try RawPeerHarness(lazyPullTimeout: 0.5)
        defer { harness.tearDown() }
        try harness.send(makeTextOfferFrame(generation: 1, text: "inline"))
        try await harness.side.recorder.waitForOffer()

        #expect(await harness.side.serveDataOffMain(generation: 1, repIndex: 0, uti: textUTI) == nil)

        let refusal = try await harness.side.recorder.waitForRefusal()
        #expect(refusal.gesture == .paste)
        #expect(refusal.failure == .timedOut)
        // The pull is released rather than left registered, so a peer that
        // answers late has its connection closed instead of streaming into a
        // fire that has gone.
        #expect(try await harness.refusesTransfer(generation: 1, repIndex: 0))
    }

    @Test("a request that never leaves resolves its pull at once")
    func failedRequestSendResolvesImmediately() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        try harness.send(makeTextOfferFrame(generation: 1, text: "inline"))
        try await harness.side.recorder.waitForOffer()

        harness.side.channel.close()
        try await harness.side.recorder.waitForEnd()

        let stopwatch = BackstopStopwatch()
        #expect(await harness.side.serveDataOffMain(generation: 1, repIndex: 0, uti: textUTI) == nil)
        // The deadline *is* the assertion: no reply is coming, so a fire that
        // parks to `lazyPullTimeout` holds the pasteboard past its own budget.
        #expect(stopwatch.elapsed < 5)
        let refusal = try await harness.side.recorder.waitForRefusal()
        #expect(refusal.gesture == .paste)
    }

    // MARK: - What a refusal leaves on the readout

    @Test("a refused paste fire is not displaced by the readout of the fire that raised it")
    func refusalOutlivesItsOwnReadout() async throws {
        let harness = try RawPeerHarness(freeSpaceProvider: { _ in 0 })
        defer { harness.tearDown() }
        let reports = harness.side.reports
        // Stands in for the host adapter, whose answer to a refusal is the VM's
        // own transfer report.
        let owner = RefusalReportingDelegate(
            recorder: harness.side.recorder, reporter: reports.reporter)
        harness.endpoint.delegate = owner
        try harness.send(
            makeOfferFrame(generation: 1, reps: [fileRep("a.bin", bytes: 4096)]))
        try await harness.side.recorder.waitForOffer()

        // The fire runs on the main thread, where the pasteboard fires a promise
        // — the ordering the refusal has to survive.
        #expect(harness.endpoint.serveFileURL(generation: 1, repIndex: 0) == nil)
        await drainMainQueue()

        #expect(owner.reportedRefusals == 1)
        // What the surface is left showing is the refusal…
        #expect(reports.failure != nil)
        // …and nothing the refused fire's own readout published ever came after
        // it: a bar flashing over the refusal is what clears the collapse of the
        // sibling fires that follow.
        let failed = reports.reports.firstIndex { report in
            guard case .finished(let finish) = report else { return false }
            return finish.failure != nil
        }
        let index = try #require(failed)
        #expect(
            !reports.reports[index...].contains { report in
                if case .running = report { return true }
                return false
            })
    }

    // MARK: - Reporting a refusal to the peer

    @Test("a guest's refusal also crosses as an Error frame the host renders")
    func guestRefusalCrossesAsAnErrorFrame() async throws {
        let harness = try RawPeerHarness(role: .guest, pasteLimit: cap)
        defer { harness.tearDown() }
        try harness.send(
            makeOfferFrame(generation: 1, reps: [fileRep("big.bin", bytes: UInt64(cap) + 1)]))
        try await harness.side.recorder.waitForOffer()

        #expect(await harness.side.serveFileURLOffMain(generation: 1, repIndex: 0) == nil)

        try await harness.recorder.waitForFrames { !harness.recorder.errors.isEmpty }
        let error = try #require(harness.recorder.errors.first)
        #expect(error.code == ClipboardErrorCode.pasteTooLarge.rawValue)
        #expect(error.inReplyTo == "clipboard.request")

        let refusal = try await harness.side.recorder.waitForRefusal()
        #expect(refusal.failure == .tooLarge(limitBytes: cap))
        try await harness.side.recorder.waitForActivity(
            .pasteRefused(.pasteTooLarge, limitBytes: cap))
    }

    @Test("one paste's burst of refusals is one message, and the next paste is owed its own")
    func refusalBurstWindowCollapsesRepeats() async throws {
        let harness = try RawPeerHarness(role: .guest, pasteLimit: cap)
        defer { harness.tearDown() }
        try harness.send(
            makeOfferFrame(
                generation: 1,
                reps: [
                    fileRep("a.bin", bytes: UInt64(cap) + 1), fileRep("b.bin", bytes: 1),
                ]))
        try await harness.side.recorder.waitForOffer()

        #expect(await harness.side.serveFileURLOffMain(generation: 1, repIndex: 0) == nil)
        try await harness.recorder.waitForFrames { !harness.recorder.errors.isEmpty }
        let afterFirst = harness.recorder.count

        // The second provider fire of the same paste says nothing new.
        #expect(await harness.side.serveFileURLOffMain(generation: 1, repIndex: 1) == nil)
        try await harness.recorder.expectNoNewFrames(sinceCount: afterFirst)

        // A paste made past the window is a fresh gesture.
        harness.side.clock.advance(seconds: ClipboardEndpoint.refusalBurstWindow + 1)
        #expect(await harness.side.serveFileURLOffMain(generation: 1, repIndex: 0) == nil)
        try await harness.recorder.waitForFrames { harness.recorder.errors.count == 2 }
    }

    @Test("a peer's clipboard error becomes a refusal of the paste it made")
    func peerErrorBecomesAPeerPasteRefusal() async throws {
        let harness = try RawPeerHarness(pasteLimit: cap)
        defer { harness.tearDown() }

        try harness.send(
            makeErrorFrame(
                code: ClipboardErrorCode.pasteTooLarge.rawValue, message: "too big",
                inReplyTo: "clipboard.request"))
        let tooLarge = try await harness.side.recorder.waitForRefusal()
        #expect(tooLarge.gesture == .peerPaste)
        #expect(tooLarge.failure == .tooLarge(limitBytes: cap))

        try harness.send(
            makeErrorFrame(
                code: ClipboardErrorCode.pasteDiskFull.rawValue, message: "no room",
                inReplyTo: "clipboard.request"))
        let other = try await harness.side.recorder.waitForRefusal { $0.failure != tooLarge.failure }
        #expect(other.gesture == .peerPaste)
        #expect(other.failure == .peerReported(.pasteDiskFull))
    }

    // MARK: - Serving after the connection is over

    @Test("a materialized representation keeps serving both flavors after the connection ends")
    func materializedRepresentationSurvivesTheConnection() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }
        let bytes = patternedBytes(count: 1024, multiplier: 3, offset: 9)
        let (representation, _) = try makeFileRepresentation(
            named: "shot.png", bytes: bytes, uti: imageUTI)
        pair.host.endpoint.offer(ClipboardContent(representations: [representation]))
        try await pair.guest.recorder.waitForOffer()

        let url = await pair.guest.serveFileURLOffMain(generation: 1, repIndex: 0)
        #expect(url != nil)

        pair.guest.endpoint.stop()
        #expect(await pair.guest.serveFileURLOffMain(generation: 1, repIndex: 0) == url)
        #expect(await pair.guest.serveDataOffMain(generation: 1, repIndex: 0, uti: imageUTI) == bytes)
        try await pair.guest.recorder.expectNoNewRefusals(sinceCount: 0)
    }

    @Test("a partly materialized file set is refused whole once the connection is over")
    func partialFileSetIsRefusedWhole() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }
        let (first, _) = try makeFileRepresentation(named: "a.bin", bytes: Data("a".utf8))
        let (second, _) = try makeFileRepresentation(named: "b.bin", bytes: Data("b".utf8))
        pair.host.endpoint.offer(ClipboardContent(representations: [first, second]))
        try await pair.guest.recorder.waitForOffer()

        #expect(await pair.guest.serveFileURLOffMain(generation: 1, repIndex: 0) != nil)
        pair.guest.endpoint.stop()

        // All-or-nothing: the cached sibling is withheld too rather than landing
        // a subset of the copied files.
        #expect(await pair.guest.serveFileURLOffMain(generation: 1, repIndex: 0) == nil)
        let refusal = try await pair.guest.recorder.waitForRefusal()
        #expect(refusal.gesture == .paste)
        #expect(refusal.failure == .incompleteFileSet)
    }

    @Test("an un-materialized inline flavor serves nothing after the connection ends, silently")
    func uncachedInlineFireIsSilentAfterTheConnection() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }
        pair.host.endpoint.offer(ClipboardContent(text: "never pulled"))
        try await pair.guest.recorder.waitForOffer()

        pair.guest.endpoint.stop()
        #expect(await pair.guest.serveDataOffMain(generation: 1, repIndex: 0, uti: textUTI) == nil)
        try await pair.guest.recorder.expectNoNewRefusals(sinceCount: 0)
    }
}

/// Whether a failure is the disk-full one, whatever figures its abort carried.
private func isDiskFull(_ failure: ClipboardTransferFailure) -> Bool {
    if case .diskFull = failure { return true }
    return false
}

/// Records what the endpoint reports and puts every refusal on the transfer
/// report, as the host adapter does.
@MainActor
private final class RefusalReportingDelegate: ClipboardEndpointDelegate {
    private let recorder: EndpointRecorder
    private let reporter: ClipboardTransferReporter

    /// How many refusals reached the report.
    private(set) var reportedRefusals = 0

    init(recorder: EndpointRecorder, reporter: ClipboardTransferReporter) {
        self.recorder = recorder
        self.reporter = reporter
    }

    func endpoint(
        _ endpoint: ClipboardEndpoint, didReceiveOffer offer: ClipboardEndpoint.InboundOffer
    ) {
        recorder.endpoint(endpoint, didReceiveOffer: offer)
    }

    func endpoint(
        _ endpoint: ClipboardEndpoint, didRetractOffer generation: UInt64?,
        reason: ClipboardEndpoint.RetractReason
    ) {
        recorder.endpoint(endpoint, didRetractOffer: generation, reason: reason)
    }

    func endpoint(
        _ endpoint: ClipboardEndpoint, didRefuse gesture: ClipboardTransferGesture,
        failure: ClipboardTransferFailure
    ) {
        recorder.endpoint(endpoint, didRefuse: gesture, failure: failure)
        reportedRefusals += 1
        reporter.finish(
            ClipboardTransferFinish(
                gesture: gesture, outcome: .failed(failure), peerName: "Guest"))
    }

    func endpoint(
        _ endpoint: ClipboardEndpoint, didRecord activity: ClipboardEndpoint.Activity
    ) {
        recorder.endpoint(endpoint, didRecord: activity)
    }

    func endpointDidEnd(_ endpoint: ClipboardEndpoint) {
        recorder.endpointDidEnd(endpoint)
    }
}
