import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// The drop channel: independent jobs rather than a supersession chain, a
/// send-only host end, and a verdict that crosses back as a `DropComplete`.
@Suite("ClipboardEndpoint drops")
@MainActor
struct ClipboardEndpointDropTests {
    private func dropRep(_ name: String, _ bytes: Data) throws
        -> ClipboardContent.Representation
    {
        try makeFileRepresentation(named: name, bytes: bytes).representation
    }

    // MARK: - Offering a drop

    @Test("a drop crosses as its own job and reaches the guest as an offer")
    func dropOfferReachesTheGuest() async throws {
        let pair = try EndpointPair(kind: .drop)
        defer { pair.tearDown() }

        let content = ClipboardContent(representations: [
            try dropRep("one.bin", Data("one".utf8)), try dropRep("two.bin", Data("two".utf8)),
        ])
        #expect(pair.host.endpoint.offer(content) == .sent(generation: 1))

        let offer = try await pair.guest.recorder.waitForOffer()
        #expect(offer.generation == 1)
        #expect(offer.reps.map(\.filename) == ["one.bin", "two.bin"])
    }

    @Test("the same files dropped twice are two jobs, never a duplicate")
    func repeatedDropIsANewJob() async throws {
        let pair = try EndpointPair(kind: .drop)
        defer { pair.tearDown() }

        let content = ClipboardContent(representations: [try dropRep("one.bin", Data("one".utf8))])
        #expect(pair.host.endpoint.offer(content) == .sent(generation: 1))
        #expect(pair.host.endpoint.offer(content) == .sent(generation: 2))

        let offer = try await pair.guest.recorder.waitForOffer(count: 2)
        #expect(offer.generation == 2)
        #expect(pair.host.endpoint.outboundContent(generation: 1) != nil)
    }

    // MARK: - Pulling a drop

    @Test("each dropped item is pulled under one readout, one request apiece")
    func eachItemIsPulledInTurn() async throws {
        let pair = try EndpointPair(kind: .drop)
        defer { pair.tearDown() }

        let payloads = [Data("first".utf8), Data("second".utf8)]
        let content = ClipboardContent(representations: [
            try dropRep("one.bin", payloads[0]), try dropRep("two.bin", payloads[1]),
        ])
        pair.host.endpoint.offer(content)
        try await pair.guest.recorder.waitForOffer()

        let operation = pair.guest.makeOperation(gesture: .drop, direction: .inbound)
        for index in payloads.indices {
            let outcome = await pair.guest.startPull(
                generation: 1, repIndex: index, operation: operation
            ).value
            guard case .delivered(let representation) = outcome else {
                Issue.record("Item \(index) was not delivered: \(outcome)")
                return
            }
            #expect(representation.filename == (index == 0 ? "one.bin" : "two.bin"))
            let url = try #require(representation.fileURL)
            let landed = try Data(contentsOf: url)
            #expect(landed == payloads[index])
        }
        #expect(pair.host.recorder.activityCount(.transferServed) == 2)
    }

    @Test("the guest's verdict finishes the drop the host is measuring")
    func dropCompleteFinishesTheHostReadout() async throws {
        let pair = try EndpointPair(kind: .drop)
        defer { pair.tearDown() }

        pair.host.endpoint.offer(
            ClipboardContent(representations: [try dropRep("one.bin", Data("one".utf8))]))
        try await pair.guest.recorder.waitForOffer()

        let operation = pair.guest.makeOperation(gesture: .drop, direction: .inbound)
        _ = await pair.guest.startPull(generation: 1, repIndex: 0, operation: operation).value
        pair.guest.endpoint.retireInbound(generation: 1)
        pair.guest.endpoint.sendDropComplete(generation: 1, outcome: .completed)

        try await pair.host.reports.wait {
            dropFinishes(pair.host.reports).contains { isCompletedFinish($0) }
        }
        #expect(!pair.guest.endpoint.hasLiveInboundOffer(generation: 1))
    }

    @Test("a failed verdict is rendered from its code, not the peer's sentence")
    func failedDropCompleteReportsThePeersCode() async throws {
        let harness = try RawPeerHarness(kind: .drop, receives: false)
        defer { harness.tearDown() }
        harness.endpoint.offer(
            ClipboardContent(representations: [try dropRep("one.bin", Data("one".utf8))]))

        try harness.send(
            makeDropCompleteFrame(
                generation: 1, outcome: .failed, code: .dropDiskFull,
                message: "whatever the guest said"))

        try await harness.side.reports.wait {
            dropFinishes(harness.side.reports).contains {
                $0.outcome == .failed(.peerReported(.dropDiskFull))
            }
        }
    }

    @Test("an empty drop is answered with a failure rather than taken on")
    func emptyDropOfferIsRefused() async throws {
        let harness = try RawPeerHarness(role: .guest, kind: .drop)
        defer { harness.tearDown() }

        try harness.send(makeDropOfferFrame(generation: 1, reps: []))

        try await harness.recorder.waitForFrames {
            harness.recorder.frames.contains {
                if case .dropComplete = $0.payload { return true }
                return false
            }
        }
        let frame = try #require(
            harness.recorder.first {
                if case .dropComplete = $0.payload { return true }
                return false
            })
        guard case .dropComplete(let complete) = frame.payload else {
            Issue.record("Expected a DropComplete")
            return
        }
        #expect(complete.outcome == .failed)
        #expect(complete.code == ClipboardErrorCode.dropFailed.rawValue)
        #expect(harness.side.recorder.offers.isEmpty)
    }

    // MARK: - Calling a drop off

    @Test("cancelling the drop releases it to the peer and stops its readout")
    func hostCancelReleasesTheDrop() async throws {
        let harness = try RawPeerHarness(kind: .drop, receives: false)
        defer { harness.tearDown() }
        harness.endpoint.offer(
            ClipboardContent(representations: [try dropRep("one.bin", Data("one".utf8))]))

        // The guest asks for the first item, which is what puts the drop's
        // readout on screen for the user to cancel.
        try harness.send(
            makeRequestFrame(
                generation: 1, transferID: harness.peerTransferID(generation: 1, repIndex: 0),
                uti: "public.data"))
        try await harness.side.reports.wait { harness.side.reports.runningSnapshot != nil }

        harness.endpoint.cancelOutbound(generation: 1)

        try await harness.recorder.waitForFrames {
            harness.recorder.frames.contains {
                if case .dropRelease = $0.payload { return true }
                return false
            }
        }
        try await harness.side.reports.wait {
            dropFinishes(harness.side.reports).contains { isCancelledFinish($0) }
        }
        #expect(harness.endpoint.outboundContent(generation: 1) == nil)
    }

    @Test("a release under a parked pull retracts the job and wakes it cancelled")
    func releaseWakesAParkedDropPull() async throws {
        let harness = try RawPeerHarness(role: .guest, kind: .drop)
        defer { harness.tearDown() }
        try harness.send(
            makeDropOfferFrame(
                generation: 1,
                reps: [RepInfo(uti: "public.data", byteCount: 8, filename: "a.bin", isInline: false)]
            ))
        try await harness.side.recorder.waitForOffer()

        let operation = harness.side.makeOperation(gesture: .drop, direction: .inbound)
        let pull = harness.side.startPull(generation: 1, repIndex: 0, operation: operation)
        try await harness.waitForRequest(generation: 1, repIndex: 0)

        var release = Frame()
        release.protocolVersion = 1
        var dropRelease = Kernova_V1_DropRelease()
        dropRelease.generation = 1
        release.dropRelease = dropRelease
        try harness.send(release)

        // The wake carries a retiring abort code rather than a bare
        // cancellation, so the caller can tell it from a transfer that failed.
        guard case .aborted(let info) = await pull.value, info.isRetiring else {
            Issue.record("Expected the parked pull to wake with a retiring abort")
            return
        }
        let retraction = try await harness.side.recorder.waitForRetraction()
        #expect(retraction.generation == 1)
        #expect(retraction.reason == .released)
    }

    @Test("cancelling inbound tells the peer to stop and wakes the pull")
    func guestCancelInboundAbortsTheTransfer() async throws {
        let harness = try RawPeerHarness(role: .guest, kind: .drop)
        defer { harness.tearDown() }
        try harness.send(
            makeDropOfferFrame(
                generation: 1,
                reps: [RepInfo(uti: "public.data", byteCount: 8, filename: "a.bin", isInline: false)]
            ))
        try await harness.side.recorder.waitForOffer()

        let operation = harness.side.makeOperation(gesture: .drop, direction: .inbound)
        let pull = harness.side.startPull(generation: 1, repIndex: 0, operation: operation)
        try await harness.waitForRequest(generation: 1, repIndex: 0)
        harness.endpoint.cancelInbound(generation: 1)

        guard case .aborted(let info) = await pull.value, info.code == .cancelled else {
            Issue.record("Expected the cancelled pull to wake with a cancelled abort")
            return
        }
        try await harness.recorder.waitForFrames {
            harness.recorder.aborts.contains {
                $0.code == ClipboardStreamAbortCode.userCancelled.rawValue
            }
        }
    }

    @Test("an abort that retires the transfer stays retiring at the caller")
    func retiringAbortReachesTheDropCaller() async throws {
        let harness = try RawPeerHarness(role: .guest, kind: .drop)
        defer { harness.tearDown() }
        try harness.send(
            makeDropOfferFrame(
                generation: 1,
                reps: [RepInfo(uti: "public.data", byteCount: 8, filename: "a.bin", isInline: false)]
            ))
        try await harness.side.recorder.waitForOffer()

        let operation = harness.side.makeOperation(gesture: .drop, direction: .inbound)
        let pull = harness.side.startPull(generation: 1, repIndex: 0, operation: operation)
        try await harness.waitForRequest(generation: 1, repIndex: 0)
        try harness.send(
            makeAbortFrame(
                transferID: harness.transferID(generation: 1, repIndex: 0),
                code: ClipboardStreamAbortCode.cancelled.rawValue, message: "torn down"))

        guard case .aborted(let info) = await pull.value else {
            Issue.record("Expected the pull to report the abort")
            return
        }
        #expect(info.code == .cancelled)
        #expect(info.isRetiring)
        // The caller maps a retiring code itself; nothing was refused here.
        try await harness.side.recorder.expectNoNewRefusals(sinceCount: 0)
    }

    @Test("a session ending under live drops owes each job its own file count")
    func endingTheSessionInterruptsEachJobSeparately() async throws {
        let harness = try RawPeerHarness(kind: .drop, receives: false)
        defer { harness.tearDown() }

        harness.endpoint.offer(
            ClipboardContent(representations: [
                try dropRep("one.bin", Data("one".utf8)), try dropRep("two.bin", Data("two".utf8)),
            ]))
        harness.endpoint.offer(
            ClipboardContent(representations: [try dropRep("three.bin", Data("three".utf8))]))

        harness.endpoint.stop()

        try await harness.side.reports.wait {
            let failures = dropFinishes(harness.side.reports).compactMap(\.failure)
            return failures.contains(.interrupted(fileCount: 2))
                && failures.contains(.interrupted(fileCount: 1))
        }
    }
}

// MARK: - Report readers

@MainActor
private func dropFinishes(
    _ reports: ClipboardTransferReports
) -> [ClipboardTransferFinish] {
    reports.reports.compactMap {
        guard case .finished(let finish) = $0, finish.gesture == .drop else { return nil }
        return finish
    }
}

private func isCompletedFinish(_ finish: ClipboardTransferFinish) -> Bool {
    if case .completed = finish.outcome { return true }
    return false
}

private func isCancelledFinish(_ finish: ClipboardTransferFinish) -> Bool {
    if case .cancelled = finish.outcome { return true }
    return false
}
