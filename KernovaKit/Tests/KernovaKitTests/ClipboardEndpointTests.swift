import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// What one clipboard connection does with an offer — announcing one, taking
/// the peer's, and answering the requests it draws — driven end to end through a
/// real host endpoint and a real guest endpoint over a socketpair.
@Suite("ClipboardEndpoint offers and serving")
@MainActor
struct ClipboardEndpointTests {
    private let textUTI = ClipboardContent.utf8TextUTI

    // MARK: - Announcing an offer

    @Test("an offer crosses as metadata alone and pulls nothing")
    func offerCarriesMetadataOnly() async throws {
        let harness = try RawPeerHarness(role: .guest)
        defer { harness.tearDown() }

        try harness.send(
            makeOfferFrame(
                generation: 4,
                reps: [
                    .text("hello"),
                    RepInfo(uti: "public.data", byteCount: 12, filename: "a.bin", isInline: false),
                ],
                isConcealed: true))

        let offer = try await harness.side.recorder.waitForOffer()
        #expect(offer.generation == 4)
        #expect(offer.reps.map(\.uti) == [textUTI, "public.data"])
        #expect(offer.reps.map(\.filename) == ["", "a.bin"])
        #expect(offer.isConcealed)
        #expect(offer.keptIndices == [0, 1])
        // Nothing was asked for: an offer is metadata, and the bytes cross only
        // when something consumes them.
        try await harness.recorder.expectNoNewFrames(sinceCount: 0)
    }

    @Test("generations advance per offer and seed from the configured first one")
    func offerGenerationsAdvance() async throws {
        let pair = try EndpointPair(hostFirstGeneration: 7)
        defer { pair.tearDown() }

        #expect(pair.host.endpoint.offer(ClipboardContent(text: "one")) == .sent(generation: 7))
        #expect(pair.host.endpoint.offer(ClipboardContent(text: "two")) == .sent(generation: 8))
        #expect(pair.host.endpoint.nextGeneration == 9)

        let offer = try await pair.guest.recorder.waitForOffer(count: 2)
        #expect(offer.generation == 8)
    }

    @Test("unchanged content is a duplicate until the dedup latch is reset")
    func unchangedContentDedups() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        let content = ClipboardContent(text: "same")
        #expect(pair.host.endpoint.offer(content) == .sent(generation: 1))
        #expect(pair.host.endpoint.offer(content) == .duplicate)

        pair.host.endpoint.resetOfferDedup()
        #expect(pair.host.endpoint.offer(content) == .sent(generation: 2))
    }

    @Test("an offer with nothing offerable reports it and registers nothing")
    func emptyContentOffersNothing() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        #expect(pair.host.endpoint.offer(.empty) == .nothingToOffer)
        #expect(pair.host.endpoint.nextGeneration == 1)
        #expect(pair.host.endpoint.currentOutboundContent == nil)
    }

    @Test("a send that fails registers no generation")
    func failedSendRegistersNothing() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        #expect(pair.host.endpoint.offer(ClipboardContent(text: "first")) == .sent(generation: 1))
        pair.host.channel.close()
        try await pair.host.recorder.waitForEnd()

        #expect(pair.host.endpoint.offer(ClipboardContent(text: "second")) == .sendFailed)
        // The generation is committed only once the frame is away, so the failed
        // send left nothing for the peer to request.
        #expect(pair.host.endpoint.nextGeneration == 2)
        #expect(pair.host.endpoint.outboundContent(generation: 2) == nil)
    }

    @Test("a release retracts the peer's offer and re-arms the dedup latch")
    func releaseRetractsAndReArms() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        let content = ClipboardContent(text: "released")
        #expect(pair.host.endpoint.offer(content) == .sent(generation: 1))
        try await pair.guest.recorder.waitForOffer()

        #expect(pair.host.endpoint.release())
        let retraction = try await pair.guest.recorder.waitForRetraction(count: 2)
        #expect(retraction.generation == 1)
        #expect(retraction.reason == .released)
        #expect(pair.guest.endpoint.inboundOffer == nil)

        // The latch meant "the peer already has this", which the release made
        // false.
        #expect(pair.host.endpoint.offer(content) == .sent(generation: 2))
    }

    @Test("a newer offer retires the one it supersedes before it lands")
    func newerOfferSupersedesThePrevious() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        pair.host.endpoint.offer(ClipboardContent(text: "first"))
        try await pair.guest.recorder.waitForOffer()
        pair.host.endpoint.offer(ClipboardContent(text: "second"))
        let offer = try await pair.guest.recorder.waitForOffer(count: 2)

        #expect(offer.generation == 2)
        // The first offer's own retraction carries no generation — this side held
        // none — and the second's retires generation 1 ahead of landing.
        let retractions = pair.guest.recorder.retractions
        #expect(retractions.count == 2)
        #expect(retractions[0].generation == nil)
        #expect(retractions[1].generation == 1)
        #expect(retractions[1].reason == .superseded(hasSuccessor: true))
    }

    @Test("an offer nothing survives filtering retires the previous with no successor")
    func fullyFilteredOfferHasNoSuccessor() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        pair.host.endpoint.offer(ClipboardContent(text: "keepable"))
        try await pair.guest.recorder.waitForOffer()

        let marker = ClipboardContent.Representation(
            uti: ClipboardSnapshotPolicy.concealedMarkerUTI, data: Data("x".utf8))
        pair.host.endpoint.offer(ClipboardContent(representations: [marker]))

        let retraction = try await pair.guest.recorder.waitForRetraction(count: 2)
        #expect(retraction.generation == 1)
        #expect(retraction.reason == .superseded(hasSuccessor: false))
        #expect(pair.guest.recorder.offers.count == 1)
        #expect(pair.guest.endpoint.inboundOffer == nil)
    }

    // MARK: - Serving what the peer asks for

    @Test("an inline representation is pulled once and served whole")
    func inlineRepresentationServesItsBytes() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        pair.host.endpoint.offer(ClipboardContent(text: "inline bytes"))
        try await pair.guest.recorder.waitForOffer()

        let served = await pair.guest.serveDataOffMain(generation: 1, repIndex: 0, uti: textUTI)
        #expect(served == Data("inline bytes".utf8))
        #expect(pair.host.recorder.activityCount(.transferServed) == 1)
        #expect(pair.guest.endpoint.materialized(generation: 1, repIndex: 0) != nil)
        #expect(pair.guest.endpoint.materializationEpoch(generation: 1) == 1)
    }

    @Test("a data connection accepted off the main actor adopts a reply")
    func offMainAcceptAdoptsReply() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        let payload = Data("off-main bytes".utf8)

        try harness.send(makeTextOfferFrame(generation: 1, text: "off-main bytes"))
        try await harness.side.recorder.waitForOffer()

        let serve = harness.side.startDataServe(generation: 1, repIndex: 0, uti: textUTI)
        try await harness.waitForRequest(generation: 1, repIndex: 0)

        // The listener hands a reply's connection over on the VM's queue, so
        // the accept runs off the main actor, as production drives it.
        let (peerEnd, endpointEnd) = try makeRawSocketPair()
        let endpoint = harness.endpoint
        await offCooperativePool { endpoint.acceptDataConnection(fd: endpointEnd) }
        try serveTransfer(
            fd: peerEnd, transferID: harness.transferID(generation: 1, repIndex: 0),
            payload: payload, isArchive: false, isInline: true)

        let served = await serve.value
        #expect(served == payload)
    }

    @Test("a payload past one socket read reassembles")
    func multiReadPayloadReassembles() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        let payload = patternedBytes(
            count: 3 * ClipboardStreamTuning.dataReadBufferBytes + 17, multiplier: 7, offset: 3)
        let representation = ClipboardContent.Representation(uti: "public.data", data: payload)
        pair.host.endpoint.offer(ClipboardContent(representations: [representation]))
        try await pair.guest.recorder.waitForOffer()

        let served = await pair.guest.serveDataOffMain(
            generation: 1, repIndex: 0, uti: "public.data")
        #expect(served == payload)
    }

    @Test("a file representation stages and serves a URL whose bytes match")
    func fileRepresentationStagesAndServes() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        let bytes = patternedBytes(count: 4096, multiplier: 11, offset: 5)
        let (representation, _) = try makeFileRepresentation(named: "note.bin", bytes: bytes)
        pair.host.endpoint.offer(ClipboardContent(representations: [representation]))
        try await pair.guest.recorder.waitForOffer()

        let url = await pair.guest.serveFileURLOffMain(generation: 1, repIndex: 0)
        let served = try contents(ofServed: url)
        #expect(served == bytes)
        #expect(url?.lastPathComponent == "note.bin")
    }

    @Test("a directory representation extracts to a real tree")
    func directoryRepresentationExtracts() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        let (representation, _) = try makeDirectoryRepresentation(
            named: "Folder", files: ["one.txt": Data("one".utf8), "two.txt": Data("two".utf8)])
        pair.host.endpoint.offer(ClipboardContent(representations: [representation]))
        try await pair.guest.recorder.waitForOffer()

        let served = await pair.guest.serveFileURLOffMain(generation: 1, repIndex: 0)
        let url = try #require(served)
        #expect(url.lastPathComponent == "Folder")
        let one = try Data(contentsOf: url.appendingPathComponent("one.txt"))
        let two = try Data(contentsOf: url.appendingPathComponent("two.txt"))
        #expect(one == Data("one".utf8))
        #expect(two == Data("two".utf8))
    }

    @Test("a zero-byte file representation still serves its file")
    func zeroByteFileServes() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        let (representation, _) = try makeFileRepresentation(named: "empty.bin", bytes: Data())
        pair.host.endpoint.offer(ClipboardContent(representations: [representation]))
        let offer = try await pair.guest.recorder.waitForOffer()
        #expect(offer.keptIndices == [0])

        let url = await pair.guest.serveFileURLOffMain(generation: 1, repIndex: 0)
        let served = try contents(ofServed: url)
        #expect(served.isEmpty)
    }

    @Test("an empty unnamed representation is neither kept nor promised")
    func emptyUnnamedRepresentationIsDropped() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        pair.host.endpoint.offer(
            ClipboardContent(representations: [
                ClipboardContent.Representation(uti: textUTI, data: Data("text".utf8)),
                ClipboardContent.Representation(uti: "public.data", data: Data()),
            ]))
        let offer = try await pair.guest.recorder.waitForOffer()

        #expect(offer.reps.count == 2)
        #expect(offer.keptIndices == [0])
        let plan = try #require(pair.guest.endpoint.promisePlan(generation: 1))
        let promisedIndices = plan.items.flatMap(\.types).map(\.representationIndex)
        #expect(promisedIndices == [0])
    }

    @Test("both flavors of an image file come from one pull, and its URL is stable")
    func imageFileServesBothFlavorsFromOnePull() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        // Offered from the guest and served on the host, so the staged-once rule
        // is pinned on the end that used to re-stage per fire.
        let bytes = patternedBytes(count: 2048, multiplier: 13, offset: 1)
        let (representation, _) = try makeFileRepresentation(
            named: "shot.png", bytes: bytes, uti: "public.png")
        pair.guest.endpoint.offer(ClipboardContent(representations: [representation]))
        try await pair.host.recorder.waitForOffer()

        let url = await pair.host.serveFileURLOffMain(generation: 1, repIndex: 0)
        let served = try contents(ofServed: url)
        #expect(served == bytes)
        let inline = await pair.host.serveDataOffMain(generation: 1, repIndex: 0, uti: "public.png")
        #expect(inline == bytes)
        // The sibling flavor hit the cache: one request crossed the wire.
        #expect(pair.guest.recorder.activityCount(.transferServed) == 1)

        // The inline payload is staged once and re-served, never minting a
        // second `shot (2).png`.
        let again = await pair.host.serveFileURLOffMain(generation: 1, repIndex: 0)
        #expect(again == url)
    }

    @Test("an inline flavor whose bytes landed as a file is mapped back from it")
    func inlineFlavorOfASpilledRepresentationIsMapped() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        let bytes = patternedBytes(count: 4096, multiplier: 5, offset: 2)
        let (_, sourceURL) = try makeFileRepresentation(
            named: "shot.png", bytes: bytes, uti: "public.png")
        let archive = try clipboardArchiveBytes(ofFileAt: sourceURL, named: "shot.png")

        try harness.send(
            makeOfferFrame(
                generation: 1,
                reps: [
                    RepInfo(
                        uti: "public.png", byteCount: UInt64(bytes.count), filename: "shot.png",
                        isInline: true)
                ]))
        try await harness.side.recorder.waitForOffer()

        let serve = harness.side.startDataServe(generation: 1, repIndex: 0, uti: "public.png")
        try await harness.waitForRequest(generation: 1, repIndex: 0)
        // The peer answers a representation it advertised as inline with a file.
        try harness.streamArchive(generation: 1, repIndex: 0, archive: archive, isInline: false)

        #expect(await serve.value == bytes)
        let materialized = try #require(harness.endpoint.materialized(generation: 1, repIndex: 0))
        #expect(materialized.fileURL != nil)
    }

    @Test("the promise plan shares one item for inline types and gives each file its own")
    func promisePlanGroupsItems() async throws {
        let pair = try EndpointPair()
        defer { pair.tearDown() }

        let (fileA, _) = try makeFileRepresentation(named: "a.bin", bytes: Data("a".utf8))
        let (fileB, _) = try makeFileRepresentation(named: "b.bin", bytes: Data("b".utf8))
        pair.host.endpoint.offer(
            ClipboardContent(representations: [
                ClipboardContent.Representation(uti: textUTI, data: Data("t".utf8)),
                ClipboardContent.Representation(uti: "public.rtf", data: Data("r".utf8)),
                fileA,
                fileB,
            ]))
        try await pair.guest.recorder.waitForOffer()

        let plan = try #require(pair.guest.endpoint.promisePlan(generation: 1))
        #expect(plan.items.count == 3)
        let inlineTypes = plan.items[0].types
        #expect(inlineTypes.map(\.uti) == [textUTI, "public.rtf"])
        #expect(inlineTypes.map(\.isFileURL) == [false, false])
        let firstFile = plan.items[1].types
        #expect(firstFile.map(\.representationIndex) == [2])
        #expect(firstFile.map(\.isFileURL) == [true])
        let secondFile = plan.items[2].types
        #expect(secondFile.map(\.representationIndex) == [3])
    }

    // MARK: - Refusing a request

    @Test("a request for a generation this side has moved past is refused stale")
    func staleRequestIsRefused() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        harness.endpoint.offer(ClipboardContent(text: "live"))

        let refused = try await harness.pullFromEndpoint(
            generation: 99, repIndex: 0, uti: textUTI)

        #expect(refused.reply.refusalCode == ClipboardStreamAbortCode.requestStale.rawValue)
        #expect(refused.payload.isEmpty)
        #expect(refused.trailer == nil)
    }

    @Test("a request naming a representation outside the offer is refused out of range")
    func outOfRangeRequestIsRefused() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        harness.endpoint.offer(ClipboardContent(text: "live"))

        let refused = try await harness.pullFromEndpoint(generation: 1, repIndex: 5, uti: textUTI)

        #expect(refused.reply.refusalCode == ClipboardStreamAbortCode.requestRange.rawValue)
        #expect(refused.payload.isEmpty)
    }

    @Test("a request whose UTI does not match the offered representation is refused")
    func mismatchedUTIRequestIsRefused() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        harness.endpoint.offer(ClipboardContent(text: "live"))

        let refused = try await harness.pullFromEndpoint(
            generation: 1, repIndex: 0, uti: "public.png")

        #expect(refused.reply.refusalCode == ClipboardStreamAbortCode.requestUTI.rawValue)
        #expect(refused.payload.isEmpty)
    }

    @Test("a request arriving after the user cancelled the offer's wave is refused stale")
    func requestAfterCancelIsRefusedStale() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        harness.endpoint.offer(ClipboardContent(text: "live"))
        harness.endpoint.cancelOutbound(generation: 1)

        let refused = try await harness.pullFromEndpoint(generation: 1, repIndex: 0, uti: textUTI)

        #expect(refused.reply.refusalCode == ClipboardStreamAbortCode.requestStale.rawValue)
        #expect(refused.payload.isEmpty)
    }

    @Test("the readout's Cancel stops the wave, and later requests are refused stale")
    func readoutCancelRefusesLaterRequests() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        // Larger than the connection's send buffer, so the transfer is still in
        // flight while its readout is on screen: a peer that reads the reply and
        // stops leaves the sender parked, which is the state the Cancel acts on.
        let payload = patternedBytes(count: 4 << 20, multiplier: 23, offset: 5)
        harness.endpoint.offer(
            ClipboardContent(representations: [
                ClipboardContent.Representation(uti: "public.data", data: payload)
            ]))

        // The first request opens the `.peerPaste` readout the user can cancel.
        let parked = try harness.openDataConnection()
        try ClipboardDataConnection.writeFrame(
            makeTransferRequestFrame(
                generation: 1, transferID: harness.peerTransferID(generation: 1, repIndex: 0),
                uti: "public.data"),
            fd: parked)
        try await harness.side.reports.wait { harness.side.reports.runningSnapshot != nil }

        harness.side.reports.reporter.cancelRunning()
        // The tracker hops to main to call the cancel off, and the wave stops
        // between socket writes — so the hop has to land before this side reads
        // anything back, or the payload would simply finish.
        await drainMainQueue()

        // The wave already streaming ends with the reason in its trailer rather
        // than a completion, and the connection closes.
        let stopped = await offCooperativePool { try? receiveTransfer(fd: parked) }
        #expect(try #require(stopped).abortCode == ClipboardStreamAbortCode.superseded.rawValue)

        let refused = try await harness.pullFromEndpoint(
            generation: 1, repIndex: 0, uti: "public.data")
        #expect(refused.reply.refusalCode == ClipboardStreamAbortCode.requestStale.rawValue)
    }

    // MARK: - Bounding accepted data connections

    /// A wedged or compromised guest is in scope (docs/CLIPBOARD.md §10), and
    /// each accepted connection's opening frame is read on a blocking worker —
    /// so what a peer that connects and then says nothing costs the host is a
    /// constant, not one worker per connection it opens.
    @Test("a peer that dials and says nothing parks a bounded number of header reads")
    func silentDialsAreBounded() async throws {
        let harness = try RawPeerHarness()
        defer { harness.tearDown() }
        let endpoint = harness.endpoint
        let width = ClipboardStreamTuning.maxConcurrentDataAccepts

        var peers: [Int32] = []
        for _ in 0...width { peers.append(try harness.openDataConnection()) }

        #expect(endpoint.dataAcceptsForTesting.running == width)
        #expect(endpoint.dataAcceptsForTesting.waiting == peers.count - width)

        // Closing every peer end is the end of stream each parked read is
        // waiting on, so the connection held back gets its slot as they clear.
        for fd in peers { ClipboardDataConnection.end(fd: fd) }
        // RATIONALE: no-signal predicate — nothing publishes a notification when
        // a header read finishes and frees its slot (docs/TESTING.md).
        try await waitUntil {
            endpoint.dataAcceptsForTesting.running == 0
                && endpoint.dataAcceptsForTesting.waiting == 0
        }
    }
}
