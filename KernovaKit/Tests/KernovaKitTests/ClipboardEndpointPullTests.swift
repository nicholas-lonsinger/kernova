import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// How one connection's pulls share a transfer, what a gesture retiring under
/// them means, what they leave on the readout, and how the connection ends.
@Suite("ClipboardEndpoint pulls and lifecycle", .caseScoped)
@MainActor
struct ClipboardEndpointPullTests {
    private let textUTI = ClipboardContent.utf8TextUTI

    // MARK: - Sharing one transfer

    @Test("cancelling the joined pulls leaves a transfer a paste fire is also waiting on")
    func cancelJoinedPullsLeavesAFiresTransfer() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        let payload = Data("still wanted".utf8)
        try harness.send(makeTextOfferFrame(generation: 1, text: "still wanted"))
        try await harness.side.recorder.waitForOffer()

        let fire = harness.side.startDataServe(generation: 1, repIndex: 0, uti: textUTI)
        try await harness.waitForRequest(generation: 1, repIndex: 0)
        let connection = try harness.openDataConnection()
        let id = harness.transferID(generation: 1, repIndex: 0)
        try ClipboardDataConnection.writeFrame(
            makeTransferReplyFrame(
                transferID: id, isArchive: false, isInline: true, totalBytes: payload.count),
            fd: connection)

        let endpoint = harness.endpoint
        DispatchQueue.main.async {
            MainActor.assumeIsolated { endpoint.cancelJoinedPulls(generation: 1) }
            try? writeTransferBytes(fd: connection, payload)
            try? ClipboardDataConnection.writeTrailer(
                ClipboardTransferTrailer(ending: .complete(digest: sha256(payload))),
                fd: connection)
            ClipboardDataConnection.end(fd: connection)
        }
        let operation = harness.side.makeOperation(gesture: .preview, direction: .inbound)
        let joined = await harness.endpoint.join(generation: 1, repIndex: 0, operation: operation)

        #expect(joined == nil)
        // The transfer the paste fire is also waiting on ran to completion: the
        // join left it rather than tearing it down.
        #expect(await fire.value == payload)
    }

    @Test("cancelling the last joined pull tears the transfer down on both sides")
    func cancelJoinedPullsTearsDownASolePull() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        try harness.send(makeTextOfferFrame(generation: 1, text: "abandoned"))
        try await harness.side.recorder.waitForOffer()

        let endpoint = harness.endpoint
        DispatchQueue.main.async {
            MainActor.assumeIsolated { endpoint.cancelJoinedPulls(generation: 1) }
        }
        let operation = harness.side.makeOperation(gesture: .preview, direction: .inbound)
        let joined = await harness.endpoint.join(generation: 1, repIndex: 0, operation: operation)

        #expect(joined == nil)
        // Torn down on this side too: a connection arriving for the abandoned
        // transfer is closed rather than served, which is what stops the peer.
        #expect(try await harness.refusesTransfer(generation: 1, repIndex: 0))
    }

    // MARK: - A gesture landing while a join settles

    /// Starts a preview join for `(generation, repIndex)`, answers its pull
    /// with `payload`, and returns once the join holds the delivered bytes,
    /// parked on `gate` before it settles them.
    private func joinParkedBeforeSettle(
        _ harness: RawPeerHarness, gate: GatedStep, generation: UInt64, repIndex: Int,
        payload: Data, operation: ClipboardTransferOperation
    ) async throws -> Task<ClipboardContent.Representation?, Never> {
        let endpoint = harness.endpoint
        endpoint.afterInboundPullForTesting = { try? await gate.pass() }
        let join = Task {
            await endpoint.join(generation: generation, repIndex: repIndex, operation: operation)
        }
        try await harness.waitForRequest(generation: generation, repIndex: repIndex)
        try harness.streamInline(generation: generation, repIndex: repIndex, payload: payload)
        try await gate.waitUntilEntered()
        return join
    }

    @Test("a newer offer landing while a join settles leaves the join nothing to answer")
    func supersessionUnderASettlingJoinAnswersNothing() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        try harness.send(makeTextOfferFrame(generation: 1, text: "stale"))
        try await harness.side.recorder.waitForOffer()

        let gate = GatedStep()
        let join = try await joinParkedBeforeSettle(
            harness, gate: gate, generation: 1, repIndex: 0, payload: Data("stale".utf8),
            operation: harness.side.makeOperation(gesture: .preview, direction: .inbound))
        try harness.send(
            makeOfferFrame(
                generation: 2,
                reps: [RepInfo(uti: "public.png", byteCount: 64, filename: "new.png", isInline: false)]))
        try await harness.side.recorder.waitForOffer(count: 2)
        gate.release()

        // The bytes arrived for an offer nothing shows any more, so an owner
        // republishing on what the join answers has nothing to put over the
        // newer offer's placeholder.
        #expect(await join.value == nil)
        #expect(harness.endpoint.inboundOffer?.generation == 2)
        #expect(harness.endpoint.materialized(generation: 1, repIndex: 0) == nil)
        #expect(harness.endpoint.materialized(generation: 2, repIndex: 0) == nil)
    }

    @Test("stop() landing while a join settles keeps the rep: cached, answered, and servable after")
    func stopUnderASettlingJoinKeepsTheRep() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        let payload = Data("kept".utf8)
        try harness.send(makeTextOfferFrame(generation: 1, text: "kept"))
        try await harness.side.recorder.waitForOffer()

        let gate = GatedStep()
        let join = try await joinParkedBeforeSettle(
            harness, gate: gate, generation: 1, repIndex: 0, payload: payload,
            operation: harness.side.makeOperation(gesture: .preview, direction: .inbound))
        harness.endpoint.stop()
        gate.release()

        // The session's end keeps a clipboard offer and its cache, so a rep in
        // hand by the time the VM stops lands and stays servable.
        #expect(await join.value?.inMemoryData == payload)
        #expect(harness.endpoint.inboundOffer?.generation == 1)
        #expect(harness.endpoint.materialized(generation: 1, repIndex: 0)?.inMemoryData == payload)
        #expect(
            await harness.side.serveDataOffMain(generation: 1, repIndex: 0, uti: textUTI) == payload)
    }

    @Test("a join for a rep a paste fire already pulled answers from the cache without requesting it (#656)")
    func joinAnswersARepAFirePulledFromTheCache() async throws {
        let harness = try RawPeerHarness(lazyPullTimeout: testWaitBackstop)
        defer { harness.tearDown() }
        let rtf = Data(repeating: 0x41, count: 8_192)
        try harness.send(
            makeOfferFrame(
                generation: 7,
                reps: [RepInfo(uti: "public.rtf", byteCount: UInt64(rtf.count), isInline: true)]))
        try await harness.side.recorder.waitForOffer()

        let fire = harness.side.startDataServe(generation: 7, repIndex: 0, uti: "public.rtf")
        try await harness.waitForRequest(generation: 7, repIndex: 0)
        try harness.streamInline(generation: 7, repIndex: 0, payload: rtf)
        #expect(await fire.value == rtf)

        let operation = harness.side.makeOperation(gesture: .preview, direction: .inbound)
        let joined = await harness.endpoint.join(generation: 7, repIndex: 0, operation: operation)

        #expect(joined?.inMemoryData == rtf)
        #expect(
            harness.recorder.requests.map(\.transferID)
                == [harness.transferID(generation: 7, repIndex: 0)])
    }

    // MARK: - A gesture retiring under a parked fire

    @Test("a newer offer landing under a parked fire resolves it silently")
    func supersessionResolvesAParkedFireSilently() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        try harness.send(makeTextOfferFrame(generation: 1, text: "first"))
        try await harness.side.recorder.waitForOffer()

        let fire = harness.side.startDataServe(generation: 1, repIndex: 0, uti: textUTI)
        try await harness.waitForRequest(generation: 1, repIndex: 0)
        try harness.send(makeTextOfferFrame(generation: 2, text: "second"))

        #expect(await fire.value == nil)
        // The newer offer's own publication is what explains this.
        try await harness.side.recorder.expectNoNewRefusals(sinceCount: 0)
    }

    @Test("a release landing under a parked fire resolves it silently")
    func releaseResolvesAParkedFireSilently() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        try harness.send(makeTextOfferFrame(generation: 1, text: "first"))
        try await harness.side.recorder.waitForOffer()

        let fire = harness.side.startDataServe(generation: 1, repIndex: 0, uti: textUTI)
        try await harness.waitForRequest(generation: 1, repIndex: 0)
        try harness.send(makeReleaseFrame(generation: 1))

        #expect(await fire.value == nil)
        try await harness.side.recorder.expectNoNewRefusals(sinceCount: 0)
    }

    @Test("a discarded inbound offer serves nothing to a later fire")
    func discardedOfferServesNothing() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        try harness.send(makeTextOfferFrame(generation: 1, text: "discarded"))
        try await harness.side.recorder.waitForOffer()

        harness.endpoint.discardInboundOffer()
        #expect(harness.endpoint.inboundOffer == nil)
        #expect(await harness.side.serveDataOffMain(generation: 1, repIndex: 0, uti: textUTI) == nil)
        #expect(harness.recorder.requests.isEmpty)
    }

    @Test("stopping under a parked fire explains the paste it cut short")
    func stopUnderAParkedFireReportsAnInterruption() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        try harness.send(makeTextOfferFrame(generation: 1, text: "interrupted"))
        try await harness.side.recorder.waitForOffer()

        let fire = harness.side.startDataServe(generation: 1, repIndex: 0, uti: textUTI)
        try await harness.waitForRequest(generation: 1, repIndex: 0)
        harness.endpoint.stop()

        #expect(await fire.value == nil)
        let refusal = try await harness.side.recorder.waitForRefusal()
        #expect(refusal.gesture == .paste)
        #expect(refusal.failure == .interrupted(fileCount: nil))
    }

    @Test("stopping with nothing parked refuses nothing")
    func stopWithNothingParkedIsSilent() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        try harness.send(makeTextOfferFrame(generation: 1, text: "quiet"))
        try await harness.side.recorder.waitForOffer()

        harness.endpoint.stop()
        try await harness.side.recorder.expectNoNewRefusals(sinceCount: 0)
    }

    // MARK: - Readouts

    @Test("a served request runs under the sender's peer-paste readout and completes")
    func servedRequestRunsUnderAPeerPasteReadout() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }
        pair.host.endpoint.offer(ClipboardContent(text: "readout"))
        try await pair.guest.recorder.waitForOffer()

        #expect(
            await pair.guest.serveDataOffMain(generation: 1, repIndex: 0, uti: textUTI)
                == Data("readout".utf8))

        try await pair.host.reports.wait {
            finishes(pair.host.reports).contains { $0.gesture == .peerPaste && isCompleted($0) }
        }
        #expect(runningGestures(pair.host.reports).contains(.peerPaste))
        try await pair.host.reports.wait { pair.host.reports.runningSnapshot == nil }
    }

    @Test("a paste fire runs under its own inbound readout and completes on delivery")
    func pasteFireRunsUnderItsOwnReadout() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }
        pair.host.endpoint.offer(ClipboardContent(text: "readout"))
        try await pair.guest.recorder.waitForOffer()

        #expect(
            await pair.guest.serveDataOffMain(generation: 1, repIndex: 0, uti: textUTI)
                == Data("readout".utf8))

        try await pair.guest.reports.wait {
            finishes(pair.guest.reports).contains { $0.gesture == .paste && isCompleted($0) }
        }
        #expect(runningGestures(pair.guest.reports).contains(.paste))
    }

    @Test("a refused paste abandons its readout rather than finishing it")
    func refusedPasteAbandonsItsReadout() async throws {
        let harness = try RawPeerHarness(freeSpaceProvider: { _ in 0 })
        defer { harness.tearDown() }
        try harness.send(
            makeOfferFrame(
                generation: 1,
                reps: [RepInfo(uti: "public.data", byteCount: 4096, filename: "a.bin", isInline: false)]
            ))
        try await harness.side.recorder.waitForOffer()

        #expect(await harness.side.serveFileURLOffMain(generation: 1, repIndex: 0) == nil)
        try await harness.side.recorder.waitForRefusal()

        // What the fire owed the user went to the surface that owns refusals;
        // the readout has nothing left to say.
        #expect(!finishes(harness.side.reports).contains { $0.gesture == .paste })
    }

    @Test("a fresh connection retires the report the last one left standing, on both roles")
    func startClearsTheStandingReport() async throws {
        let pair = try EndpointPair(autoStart: false)
        defer { pair.tearDown() }

        for side in [pair.host, pair.guest] {
            side.reports.reporter.finish(
                ClipboardTransferFinish(
                    gesture: .copy, outcome: .failed(.transferFailed), peerName: "peer"))
            #expect(side.reports.failure != nil)
            side.start()
            #expect(side.reports.latest == .idle)
        }
    }

    @Test("an offer retires the standing report on the side that sends it and the side that takes it")
    func offersClearTheStandingReportOnBothRoles() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        for side in [pair.host, pair.guest] {
            side.reports.reporter.finish(
                ClipboardTransferFinish(
                    gesture: .copy, outcome: .failed(.transferFailed), peerName: "peer"))
        }
        pair.host.endpoint.offer(ClipboardContent(text: "news"))
        #expect(pair.host.reports.latest == .idle)

        // The offer the peer takes retires its standing report too, ahead of the
        // retraction whose own report explains this very offer.
        try await pair.guest.reports.wait { pair.guest.reports.latest == .idle }
    }

    // MARK: - Ending the connection

    @Test("the channel closing ends both endpoints and tells both owners")
    func channelCloseEndsBothEndpoints() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        pair.host.channel.close()
        try await pair.host.recorder.waitForEnd()
        try await pair.guest.recorder.waitForEnd()

        #expect(pair.host.endpoint.hasEnded)
        #expect(pair.guest.endpoint.hasEnded)
        #expect(!pair.host.endpoint.isConnected)
        #expect(!pair.guest.endpoint.isConnected)
        await pair.host.endpoint.waitUntilEnded()
        await pair.guest.endpoint.waitUntilEnded()
    }

    @Test("stop() ends the connection without telling the owner it already decided")
    func stopDoesNotRaiseTheEndCallback() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        pair.host.endpoint.stop()
        // The consume tail queues the end notice to main before the drain's task
        // returns, so once both have run the notice has had its chance to land.
        await pair.host.endpoint.waitUntilEnded()
        await drainMainQueue()

        #expect(pair.host.endpoint.hasEnded)
        #expect(!pair.host.endpoint.isConnected)
        #expect(pair.host.recorder.endedCount == 0)
    }

    @Test("start() after the connection ended reopens nothing, however it ended")
    func startAfterEndIsANoOp() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }
        let hostTasks = pair.host.endpoint.lifecycleTasksForTesting
        let guestTasks = pair.guest.endpoint.lifecycleTasksForTesting

        // The host by its owner's stop(), the guest by its channel closing under
        // it.
        pair.host.endpoint.stop()
        try await pair.guest.recorder.waitForEnd()
        pair.host.endpoint.start()
        pair.guest.endpoint.start()

        #expect(!pair.host.endpoint.isConnected)
        #expect(!pair.guest.endpoint.isConnected)
        #expect(pair.host.endpoint.lifecycleTasksForTesting == hostTasks)
        #expect(pair.guest.endpoint.lifecycleTasksForTesting == guestTasks)
    }

    @Test("a frame the peer sent before stop() never reaches the owner")
    func framesBeforeStopNeverLand() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }

        harness.endpoint.stop()
        // The hop the consume loop makes for a frame that was already on the
        // wire, driven directly: whether the frame reached the loop before the
        // stop is a race, and the answer must not depend on it.
        harness.endpoint.handleControlFrameForTesting(
            makeTextOfferFrame(generation: 1, text: "too late"))

        #expect(harness.side.recorder.offers.isEmpty)
    }

    @Test("a frame the peer sent and then closed on still reaches the owner")
    func framesBeforeThePeerClosesStillLand() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        try harness.send(makeTextOfferFrame(generation: 1, text: "first"))
        try await harness.side.recorder.waitForOffer()

        // The peer withdraws its offer and hangs up in the same breath. Only a
        // local `stop()` drops what is queued; the channel's own end does not,
        // or a `ClipboardRelease` or `DropComplete` sent on the way out would be
        // lost.
        try harness.send(makeReleaseFrame(generation: 1))
        harness.peer.close()

        // The second retraction: taking on the offer raised the first, for
        // whatever this side had published before it.
        let retraction = try await harness.side.recorder.waitForRetraction(count: 2)
        #expect(retraction.generation == 1)
        #expect(retraction.reason == .released)
        try await harness.side.recorder.waitForEnd()
    }

    @Test("a payload from the wrong port closes the channel, whichever end reads it")
    func wrongPortPayloadClosesTheChannel() async throws {
        for role in [ClipboardEndpoint.Role.host, .guest] {
            let harness = try RawPeerHarness(role: role)
            defer { harness.tearDown() }

            var frame = Frame()
            frame.protocolVersion = 1
            frame.hello = Kernova_V1_Hello()
            try harness.send(frame)

            try await harness.recorder.waitUntilFinished()
            #expect(harness.endpoint.hasEnded)
            // The peer crossed the wires, so the owner is owed the settle a
            // channel ending under it gets — once, not once per queued frame.
            try await harness.side.recorder.waitForEnd()
            #expect(harness.side.recorder.endedCount == 1)
        }
    }
}

// MARK: - Report readers

/// Every finished report the recorder saw, in order.
@MainActor
private func finishes(_ reports: ClipboardTransferReports) -> [ClipboardTransferFinish] {
    reports.reports.compactMap {
        guard case .finished(let finish) = $0 else { return nil }
        return finish
    }
}

/// Every gesture that had a running readout, in order.
@MainActor
private func runningGestures(
    _ reports: ClipboardTransferReports
) -> [ClipboardTransferGesture] {
    reports.reports.compactMap {
        guard case .running(let snapshot, _) = $0 else { return nil }
        return snapshot.gesture
    }
}

private func isCompleted(_ finish: ClipboardTransferFinish) -> Bool {
    if case .completed = finish.outcome { return true }
    return false
}
