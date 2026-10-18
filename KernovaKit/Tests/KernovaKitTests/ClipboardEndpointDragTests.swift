import Foundation
import KernovaTestSupport
import Testing
import UniformTypeIdentifiers

@testable import KernovaKit

/// The drop channel's guest→host direction: a drag the guest offers as
/// metadata, the hand-off frames that move it to the host, the host's pulls the
/// guest serves, and the frames that retire it.
@Suite("ClipboardEndpoint drags", .caseScoped)
@MainActor
struct ClipboardEndpointDragTests {
    private func dragged(_ name: String, _ bytes: Data) throws -> ClipboardContent.Representation {
        try makeFileRepresentation(named: name, bytes: bytes).representation
    }

    // MARK: - Offering a drag

    @Test("a guest drag reaches the host as a drag, never as a drop or a clipboard offer")
    func dragReachesTheHost() async throws {
        let pair = try EndpointPair(kind: .drop)
        defer { pair.tearDown() }

        let content = ClipboardContent(representations: [
            try dragged("one.bin", Data("one".utf8)), try dragged("two.bin", Data("two".utf8)),
        ])
        #expect(pair.guest.endpoint.offer(content) == .sent(generation: 1))

        let drag = try await pair.host.recorder.waitForDrag()
        #expect(drag.generation == 1)
        #expect(drag.items.map(\.filename) == ["one.bin", "two.bin"])
        #expect(drag.items.map(\.repIndex) == [0, 1])
        #expect(drag.items.allSatisfy { $0.type.identifier == "public.data" && !$0.isDirectory })
        #expect(pair.host.recorder.offers.isEmpty)
        #expect(pair.host.endpoint.hasLiveInboundOffer(generation: 1))
    }

    @Test("a drag opens no readout and arms no deadline until the host pulls")
    func dragOfferLeavesNoTraceInTheGuest() async throws {
        let pair = try EndpointPair(kind: .drop)
        defer { pair.tearDown() }

        pair.guest.endpoint.offer(
            ClipboardContent(representations: [try dragged("one.bin", Data("one".utf8))]))
        try await pair.host.recorder.waitForDrag()

        // A drag that stays inside the guest must not surface: no running
        // readout, no queued one, and no claim deadline waiting to fail it.
        #expect(pair.guest.reports.reports.isEmpty)
        #expect(pair.guest.clock.requestedSeconds.isEmpty)
    }

    @Test("several drags stay live at once, and the same files dragged twice are two drags")
    func dragsAreIndependent() async throws {
        let pair = try EndpointPair(kind: .drop)
        defer { pair.tearDown() }

        let content = ClipboardContent(representations: [try dragged("one.bin", Data("one".utf8))])
        #expect(pair.guest.endpoint.offer(content) == .sent(generation: 1))
        #expect(pair.guest.endpoint.offer(content) == .sent(generation: 2))

        try await pair.host.recorder.waitForDrag(count: 2)
        #expect(pair.guest.endpoint.outboundContent(generation: 1) != nil)
        #expect(pair.host.endpoint.hasLiveInboundOffer(generation: 1))
        #expect(pair.host.endpoint.hasLiveInboundOffer(generation: 2))
    }

    // MARK: - Pulling a drag

    @Test("the host pulls each item over the drop data port under a drag-out readout")
    func hostPullsWhatTheGuestServes() async throws {
        let pair = try EndpointPair(kind: .drop)
        defer { pair.tearDown() }

        let payloads = [Data("first".utf8), Data("second".utf8)]
        pair.guest.endpoint.offer(
            ClipboardContent(representations: [
                try dragged("one.bin", payloads[0]), try dragged("two.bin", payloads[1]),
            ]))
        try await pair.host.recorder.waitForDrag()

        let operation = pair.host.makeOperation(gesture: .dragOut, direction: .inbound)
        for index in payloads.indices.reversed() {
            let outcome = await pair.host.startPull(
                generation: 1, repIndex: index, operation: operation
            ).value
            guard case .delivered(let representation) = outcome else {
                Issue.record("Item \(index) was not delivered: \(outcome)")
                return
            }
            #expect(try Data(contentsOf: try #require(representation.fileURL)) == payloads[index])
        }
        // The guest's readout of the pulls it served names the gesture, so its
        // headline reads as a copy to the Mac rather than as a paste.
        try await pair.guest.reports.wait {
            pair.guest.reports.lastRunningSnapshot(gesture: .dragOut) != nil
        }
        #expect(pair.guest.recorder.activityCount(.transferServed) == 2)
    }

    /// Has the guest under `harness` serve the host's pull of `generation`'s
    /// first item, returning the peer end of the connection it dials — which a
    /// test that never reads it leaves parked once the socket buffer fills.
    private func servePull(_ harness: RawPeerHarness, generation: UInt64) async throws -> Int32 {
        try harness.send(
            makeRequestFrame(
                generation: generation,
                transferID: harness.peerTransferID(generation: generation, repIndex: 0),
                uti: "public.data"))
        return try await harness.nextDialledConnection()
    }

    /// Larger than a connection's send buffer, so a serve the peer does not
    /// read stays in flight with its readout on screen.
    private static let parkingPayload = patternedBytes(count: 4 << 20, multiplier: 23, offset: 5)

    @Test("two drags the host pulls at once each keep a drag-out readout of their own")
    func concurrentDragPullsKeepTheirReadouts() async throws {
        let harness = try RawPeerHarness(role: .guest, kind: .drop)
        defer { harness.tearDown() }
        for name in ["one.bin", "two.bin"] {
            harness.endpoint.offer(
                ClipboardContent(representations: [try dragged(name, Self.parkingPayload)]))
        }

        _ = try await servePull(harness, generation: 1)
        _ = try await servePull(harness, generation: 2)

        // One readout shows and the other counts behind it; a shared slot would
        // have finished the first when the second opened.
        try await harness.side.reports.wait {
            guard let shown = harness.side.reports.runningSnapshot else { return false }
            return shown.gesture == .dragOut && shown.pendingBehind == 1
        }
        #expect(harness.side.reports.finalSnapshots.isEmpty)
    }

    @Test("the guest's Cancel on a drag-out readout retires the drag and tells the host")
    func cancellingAServedDragRetiresIt() async throws {
        let harness = try RawPeerHarness(role: .guest, kind: .drop)
        defer { harness.tearDown() }
        harness.endpoint.offer(
            ClipboardContent(representations: [try dragged("one.bin", Self.parkingPayload)]))
        let parked = try await servePull(harness, generation: 1)
        let reply = try #require(await offCooperativePool { readTransferReply(fd: parked) })
        #expect(reply.refusalCode.isEmpty)
        try await harness.side.reports.wait {
            harness.side.reports.runningSnapshot?.gesture == .dragOut
        }

        #expect(harness.side.reports.cancelShownTransfer())

        try await harness.recorder.waitForFrames {
            harness.recorder.frames.contains {
                if case .dragRelease(let release) = $0.payload { return release.generation == 1 }
                return false
            }
        }
        #expect(harness.endpoint.outboundContent(generation: 1) == nil)
        // The serve in flight stops short rather than completing.
        let stopped = await offCooperativePool { try? receiveTransfer(fd: parked, after: reply) }
        #expect(try #require(stopped).abortCode != nil)
    }

    // MARK: - Ending a served drag's readout

    /// Has the guest under `harness` serve `generation`'s first item to its end,
    /// reading the whole transfer off the connection it dials.
    private func serveWholePull(_ harness: RawPeerHarness, generation: UInt64) async throws {
        let fd = try await servePull(harness, generation: generation)
        let received = await offCooperativePool { try? receiveTransfer(fd: fd) }
        #expect(try #require(received).isComplete)
    }

    /// How many drag-out readouts in `reports` finished as completed.
    private func completedDragOuts(_ reports: ClipboardTransferReports) -> Int {
        reports.reports.filter { report in
            guard case .finished(let finish) = report, finish.gesture == .dragOut,
                case .completed = finish.outcome
            else { return false }
            return true
        }.count
    }

    /// An idle gap no test outlasts, so only the host's `DragComplete` can end
    /// a served drag's readout.
    private static let unreachedIdleGap = TimeInterval.infinity

    @Test("a served drag-out item's readout completes once its transfer has")
    func servedDragReadoutCompletes() async throws {
        let harness = try RawPeerHarness(role: .guest, kind: .drop)
        defer { harness.tearDown() }
        harness.endpoint.offer(
            ClipboardContent(representations: [try dragged("one.bin", Data("one".utf8))]))

        try await serveWholePull(harness, generation: 1)

        let reports = harness.side.reports
        try await reports.wait { completedDragOuts(reports) == 1 && reports.latest == .idle }
    }

    @Test("the host's DragComplete after a served transfer leaves no live or pending readout")
    func dragCompleteEndsTheServedReadout() async throws {
        let harness = try RawPeerHarness(
            role: .guest, kind: .drop, progressIdleGap: Self.unreachedIdleGap)
        defer { harness.tearDown() }
        harness.endpoint.offer(
            ClipboardContent(representations: [try dragged("one.bin", Data("one".utf8))]))
        try await serveWholePull(harness, generation: 1)
        let reports = harness.side.reports
        try await reports.wait { reports.lastRunningSnapshot(gesture: .dragOut) != nil }

        try harness.send(.dragComplete(generation: 1))

        try await reports.wait { completedDragOuts(reports) == 1 && reports.latest == .idle }
        #expect(harness.endpoint.outboundContent(generation: 1) == nil)
    }

    @Test("two drags served and completed in turn leave nothing pending behind either")
    func successiveDragsLeaveNothingPending() async throws {
        let harness = try RawPeerHarness(
            role: .guest, kind: .drop, progressIdleGap: Self.unreachedIdleGap)
        defer { harness.tearDown() }
        let reports = harness.side.reports
        for generation in UInt64(1)...2 {
            harness.endpoint.offer(
                ClipboardContent(representations: [try dragged("one.bin", Data("one".utf8))]))
            try await serveWholePull(harness, generation: generation)
            try harness.send(.dragComplete(generation: generation))
            try await reports.wait {
                completedDragOuts(reports) == Int(generation) && reports.latest == .idle
            }
        }

        let running = reports.reports.compactMap { report -> ClipboardProgressSnapshot? in
            guard case .running(let snapshot, _) = report else { return nil }
            return snapshot
        }
        #expect(!running.isEmpty)
        #expect(running.allSatisfy { $0.pendingBehind == 0 })
    }

    @Test("a folder dragged out arrives as its tree")
    func folderArrivesWhole() async throws {
        let pair = try EndpointPair(kind: .drop)
        defer { pair.tearDown() }

        let folder = try makeDirectoryRepresentation(
            named: "Tree", files: ["a.txt": Data("alpha".utf8), "b.txt": Data("beta".utf8)])
        pair.guest.endpoint.offer(ClipboardContent(representations: [folder.representation]))
        let drag = try await pair.host.recorder.waitForDrag()
        #expect(drag.items.first?.isDirectory == true)
        #expect(drag.items.first?.type.identifier == "public.folder")

        let operation = pair.host.makeOperation(gesture: .dragOut, direction: .inbound)
        let outcome = await pair.host.startPull(generation: 1, repIndex: 0, operation: operation)
            .value
        guard case .delivered(let representation) = outcome else {
            Issue.record("The folder was not delivered: \(outcome)")
            return
        }
        let tree = try #require(representation.fileURL)
        #expect(try Data(contentsOf: tree.appendingPathComponent("a.txt")) == Data("alpha".utf8))
        #expect(try Data(contentsOf: tree.appendingPathComponent("b.txt")) == Data("beta".utf8))
    }

    // MARK: - Retiring a drag

    @Test("the host's completion retires the drag on both ends and reaches the guest's owner")
    func completeDragRetiresIt() async throws {
        let pair = try EndpointPair(kind: .drop)
        defer { pair.tearDown() }
        pair.guest.endpoint.offer(
            ClipboardContent(representations: [try dragged("one.bin", Data("one".utf8))]))
        try await pair.host.recorder.waitForDrag()

        pair.host.endpoint.completeDrag(generation: 1)

        #expect(!pair.host.endpoint.hasLiveInboundOffer(generation: 1))
        try await pair.guest.recorder.wait { pair.guest.recorder.completedDrags == [1] }
        #expect(pair.guest.endpoint.outboundContent(generation: 1) == nil)
    }

    @Test("the guest's withdrawal retires the drag and reaches the host's owner as a release")
    func withdrawRetiresIt() async throws {
        let pair = try EndpointPair(kind: .drop)
        defer { pair.tearDown() }
        pair.guest.endpoint.offer(
            ClipboardContent(representations: [try dragged("one.bin", Data("one".utf8))]))
        try await pair.host.recorder.waitForDrag()

        #expect(pair.guest.endpoint.withdraw(generation: 1))
        #expect(!pair.guest.endpoint.withdraw(generation: 1))

        let retraction = try await pair.host.recorder.waitForRetraction()
        #expect(retraction.generation == 1)
        #expect(retraction.reason == .released)
        #expect(!pair.host.endpoint.hasLiveInboundOffer(generation: 1))
        #expect(pair.guest.endpoint.outboundContent(generation: 1) == nil)
    }

    @Test("a release under a parked host pull wakes it with a retiring abort")
    func releaseWakesAParkedHostPull() async throws {
        let harness = try RawPeerHarness(role: .host, kind: .drop)
        defer { harness.tearDown() }
        try harness.send(
            .dragOffer(
                generation: 1,
                reps: [RepInfo(uti: "public.data", byteCount: 8, filename: "a.bin", isInline: false).wire]
            ))
        try await harness.side.recorder.waitForDrag()

        let operation = harness.side.makeOperation(gesture: .dragOut, direction: .inbound)
        let pull = harness.side.startPull(generation: 1, repIndex: 0, operation: operation)
        // The host cannot dial, so its pull is a request on the control channel.
        try await harness.waitForRequest(generation: 1, repIndex: 0)

        try harness.send(.dragRelease(generation: 1))

        guard case .aborted(let info) = await pull.value, info.isRetiring else {
            Issue.record("Expected the parked pull to wake with a retiring abort")
            return
        }
        #expect(!harness.endpoint.hasLiveInboundOffer(generation: 1))
    }

    @Test("completing a drag under a parked host pull wakes it cancelled and tells the guest")
    func completeDragWakesAParkedHostPull() async throws {
        let harness = try RawPeerHarness(role: .host, kind: .drop)
        defer { harness.tearDown() }
        try harness.send(
            .dragOffer(
                generation: 1,
                reps: [RepInfo(uti: "public.data", byteCount: 8, filename: "a.bin", isInline: false).wire]
            ))
        try await harness.side.recorder.waitForDrag()
        let operation = harness.side.makeOperation(gesture: .dragOut, direction: .inbound)
        let pull = harness.side.startPull(generation: 1, repIndex: 0, operation: operation)
        try await harness.waitForRequest(generation: 1, repIndex: 0)

        harness.endpoint.completeDrag(generation: 1)

        guard case .aborted(let info) = await pull.value, info.code == .cancelled else {
            Issue.record("Expected the parked pull to wake cancelled")
            return
        }
        try await harness.recorder.waitForFrames {
            harness.recorder.frames.contains {
                if case .dragComplete(let complete) = $0.payload { return complete.generation == 1 }
                return false
            }
        }
    }

    @Test("a guest drag the host has not pulled is gone once the channel ends")
    func channelEndRetiresTheHostsDrags() async throws {
        let harness = try RawPeerHarness(role: .host, kind: .drop)
        defer { harness.tearDown() }
        try harness.send(
            .dragOffer(
                generation: 1,
                reps: [RepInfo(uti: "public.data", byteCount: 8, filename: "a.bin", isInline: false).wire]
            ))
        try await harness.side.recorder.waitForDrag()

        harness.peer.close()

        try await harness.side.recorder.waitForEnd()
        // The retirement runs on a main turn after the session's own end.
        await drainMainQueue()
        #expect(!harness.endpoint.hasLiveInboundOffer(generation: 1))
    }

    // MARK: - Host intake

    @Test("the host makes every guest-supplied name and type safe at intake")
    func intakeSanitizesNamesAndTypes() async throws {
        let harness = try RawPeerHarness(role: .host, kind: .drop)
        defer { harness.tearDown() }
        try harness.send(
            .dragOffer(
                generation: 1,
                reps: [
                    RepInfo(uti: "public.png", byteCount: 1, filename: "../escape.png", isInline: false),
                    RepInfo(uti: "public.folder", byteCount: 1, filename: "a/b", isInline: true),
                    RepInfo(uti: "evil", byteCount: 1, filename: "", isInline: false),
                    RepInfo(
                        uti: "public.jpeg", byteCount: 1, filename: "..", isInline: false,
                        isDirectory: true),
                    RepInfo(
                        uti: "com.apple.application-bundle", byteCount: 1, filename: "Tool.app",
                        isInline: false, isDirectory: true),
                ].map(\.wire)))

        let drag = try await harness.side.recorder.waitForDrag()
        #expect(drag.items.map(\.filename) == ["escape.png", "b", "File", "Folder", "Tool.app"])
        #expect(
            drag.items.map(\.type.identifier) == [
                "public.png", "public.data", "public.data", "public.folder",
                "com.apple.application-bundle",
            ])
    }

    @Test("a pull echoes the type the guest declared, whatever the host made of it")
    func pullEchoesTheDeclaredType() async throws {
        let harness = try RawPeerHarness(role: .host, kind: .drop)
        defer { harness.tearDown() }
        try harness.send(
            .dragOffer(
                generation: 1,
                reps: [RepInfo(uti: "evil", byteCount: 8, filename: "a.bin", isInline: false).wire]))
        try await harness.side.recorder.waitForDrag()

        let operation = harness.side.makeOperation(gesture: .dragOut, direction: .inbound)
        let pull = harness.side.startPull(generation: 1, repIndex: 0, operation: operation)
        let request = try await harness.waitForRequest(generation: 1, repIndex: 0)

        // The guest matches a request against its own offer, so the declared
        // type is what goes back — the usable one is for the Mac side alone.
        #expect(request.uti == "evil")
        harness.endpoint.completeDrag(generation: 1)
        _ = await pull.value
    }

    @Test("an empty drag is answered as done rather than taken on")
    func emptyDragIsCompleted() async throws {
        let harness = try RawPeerHarness(role: .host, kind: .drop)
        defer { harness.tearDown() }

        try harness.send(.dragOffer(generation: 4, reps: []))

        try await harness.recorder.waitForFrames {
            harness.recorder.frames.contains {
                if case .dragComplete(let complete) = $0.payload { return complete.generation == 4 }
                return false
            }
        }
        #expect(harness.side.recorder.drags.isEmpty)
    }

    // MARK: - Hand-off frames

    @Test("a take reaches the guest's owner, and each hand-off step the host's")
    func handOffFramesReachTheOwners() async throws {
        let pair = try EndpointPair(kind: .drop)
        defer { pair.tearDown() }

        pair.host.endpoint.sendDragTake(generation: 7)
        try await pair.guest.recorder.wait { pair.guest.recorder.takes == [7] }

        let steps: [ClipboardDragHandOffStep] = [
            .armed, .targeted, .caught, .failed(.dragTakeRefused, message: "no copy"),
        ]
        for step in steps {
            pair.guest.endpoint.sendDragHandOff(generation: 7, step: step)
        }
        try await pair.host.recorder.wait { pair.host.recorder.handOffs.count == steps.count }
        #expect(pair.host.recorder.handOffs.map(\.step) == steps)
        #expect(pair.host.recorder.handOffs.allSatisfy { $0.generation == 7 })
    }

    @Test("a hand-off sender on the wrong end sends nothing")
    func handOffSendersAreRoleBound() async throws {
        let harness = try RawPeerHarness(role: .host, kind: .drop)
        defer { harness.tearDown() }

        harness.endpoint.sendDragHandOff(generation: 1, step: .targeted)
        harness.endpoint.sendDragTake(generation: 1)

        // The take is the only frame a host sends of the two.
        try await harness.recorder.waitForFrameCount(1)
        guard case .dragTake = harness.recorder.frames.first?.payload else {
            Issue.record("Expected only the take to go out")
            return
        }
        try await harness.recorder.expectNoNewFrames(sinceCount: 1)
    }

    // MARK: - Direction guards

    @Test(
        "a drop-channel frame arriving the wrong way closes the channel",
        arguments: [
            WrongWay("DropOffer", at: .host, .dropOffer(generation: 1, reps: [])),
            WrongWay("DropRelease", at: .host, .dropRelease(generation: 1)),
            WrongWay("DragComplete", at: .host, .dragComplete(generation: 1)),
            WrongWay("DragTake", at: .host, .dragTake(generation: 1)),
            WrongWay(
                "ClipboardRequest", at: .host,
                .clipboardRequest(
                    generation: 1, transferID: 1, uti: "public.data", maxAcceptByteCount: 0)),
            WrongWay("DropComplete", at: .guest, .dropComplete(generation: 1, outcome: .completed)),
            WrongWay("DragOffer", at: .guest, .dragOffer(generation: 1, reps: [])),
            WrongWay("DragRelease", at: .guest, .dragRelease(generation: 1)),
            WrongWay("DragHandOff", at: .guest, .dragHandOff(generation: 1, step: .targeted)),
        ])
    func wrongWayClosesTheChannel(_ wrongWay: WrongWay) async throws {
        let harness = try RawPeerHarness(role: wrongWay.role, kind: .drop)
        defer { harness.tearDown() }

        try harness.send(wrongWay.frame)

        try await harness.side.recorder.waitForEnd()
        #expect(harness.endpoint.hasEnded)
        #expect(harness.side.recorder.drags.isEmpty)
        #expect(harness.side.recorder.offers.isEmpty)
        #expect(harness.side.recorder.takes.isEmpty)
        #expect(harness.side.recorder.handOffs.isEmpty)
    }

    @Test(
        "a drag frame on the clipboard channel closes it, whichever end reads it",
        arguments: [ClipboardEndpoint.Role.host, .guest])
    func dragFrameOnTheClipboardChannelCloses(role: ClipboardEndpoint.Role) async throws {
        let harness = try RawPeerHarness(role: role, kind: .clipboard)
        defer { harness.tearDown() }

        try harness.send(
            role == .host ? .dragOffer(generation: 1, reps: []) : .dragTake(generation: 1))

        try await harness.side.recorder.waitForEnd()
        #expect(harness.endpoint.hasEnded)
    }
}

/// One frame and the end that must never accept it.
struct WrongWay: Sendable, CustomTestStringConvertible {
    let name: String
    let role: ClipboardEndpoint.Role
    let frame: Frame

    init(_ name: String, at role: ClipboardEndpoint.Role, _ frame: Frame) {
        self.name = name
        self.role = role
        self.frame = frame
    }

    var testDescription: String { "\(name) at the \(role)" }
}
