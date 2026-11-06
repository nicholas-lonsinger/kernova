#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire
import Testing

/// A drag is one offer, whose items its take carries: the peer's DRAG_OFFER lists none, the take's first
/// `TARGETED` lists the drag as its catcher sees it, a delivering drop's `STEP_NAMED` names the promises and the
/// CAUGHT END sizes every item, and the offer carries the drag throughout, ending only when the host releases
/// it. What the peer says is checked as an offer is, and a hostile word fails the take cleanly.
@Suite("DragDelivery")
struct DragDeliveryTests {
    static let token = SimItems.token(1)

    static func named(_ name: String, _ storage: Representation.Storage, promised: Bool = false, size: Int = 0)
        -> Representation
    {
        var representation = SimItems.representation(storage, size: size)
        representation.name = Data(name.utf8)
        representation.promised = promised
        return representation
    }

    /// A promise, a plain file and a folder.
    static let drag = [
        named("Untitled.heic", .file, promised: true), named("a.txt", .file, size: 2048), named("Folder", .folder),
    ]

    /// A real host holding the far peer's DRAG_OFFER on stream 1, its take of it, and the take's first
    /// `TARGETED` listing `items`.
    static func taking(_ items: [Representation] = drag) throws -> (HostileRun, DragTakeID) {
        let (run, id) = try opened()
        run.feed([targeted(id, items)])
        try #require(targets(run).count == 1, "the TARGETED was refused: \(ended(run))")
        return (run, id)
    }

    /// A real host holding the far peer's DRAG_OFFER on stream 1, and its take of it.
    static func opened() throws -> (HostileRun, DragTakeID) {
        let run = HostileRun(local: .host, seed: 1, items: true)
        run.feed(
            [
                HostileItems.peerHello,
                WireFrames.open(1, .dragOffer, body: HostileItems.header(token: token, count: 0)),
                Unit.end(1),
            ], preamble: true)
        let id = try #require(run.takeDrag(token)).get()
        return (run, id)
    }

    static func items(_ representations: [Representation]) -> [OfferedItem] {
        representations.map { SimItems.offer(1, [[$0]]).items[0] }
    }

    /// The peer's `TARGETED` on take `id`, listing `items`.
    static func targeted(_ id: DragTakeID, _ items: [Representation]) -> Frame {
        var report = Kernova_V2_DragTakeReport()
        report.step = .targeted
        report.items = Self.items(items)
        return WireFrames.message(id.stream.rawValue, report)
    }

    static func targets(_ run: HostileRun) -> [[OfferedItem]] {
        run.hostEvents.compactMap { if case .dragTake(.report(_, .targeted(let items))) = $0 { items } else { nil } }
    }

    /// The peer's `STEP_NAMED` on take `id`.
    static func naming(_ id: DragTakeID, _ names: [String]) -> Frame {
        var report = Kernova_V2_DragTakeReport()
        report.step = .named
        report.promiseNames = names.map { Data($0.utf8) }
        return WireFrames.message(id.stream.rawValue, report)
    }

    /// The peer's CAUGHT END on take `id`, sizing its items.
    static func caught(_ id: DragTakeID, _ sizes: [UInt64] = []) -> Frame {
        var outcome = Kernova_V2_DragTakeOutcome()
        outcome.kind = .caught
        outcome.sizes = sizes
        return Unit.end(id.stream.rawValue, Unit.encode(outcome))
    }

    static func ended(_ run: HostileRun) -> [DragTakeResult] {
        run.hostEvents.compactMap { if case .dragTake(.ended(_, let result)) = $0 { result } else { nil } }
    }

    static func namings(_ run: HostileRun) -> [[Data]] {
        run.hostEvents.compactMap { if case .dragTake(.report(_, .named(let names))) = $0 { names } else { nil } }
    }

    static func offerEnded(_ run: HostileRun) -> Bool {
        run.itemOutputs.contains { if case .event(.offerEnded) = $0 { true } else { false } }
    }

    /// Whether the take ended reset `MALFORMED_MESSAGE` by this side.
    static func resetMalformed(_ run: HostileRun) -> Bool {
        ended(run).count == 1
            && ended(run).allSatisfy {
                if case .closed(.resetLocally(let error)) = $0 { error.code == .malformedMessage } else { false }
            }
    }

    // MARK: - Delivered

    @Test("the first TARGETED gives the drag offer its items, which pull from it; a later one lists the same")
    func targetedCarriesTheItems() throws {
        let (run, id) = try Self.opened()
        #expect(run.pullItem(SimItems.request(1)).map { (try? $0.get()) == nil } == true, "pulled an empty offer")
        run.feed([Self.targeted(id, Self.drag)])
        #expect(Self.targets(run) == [Self.items(Self.drag)])
        for item in 0..<3 {
            #expect(run.readItem(Self.token, item: UInt32(item)) == Self.items(Self.drag)[item])
        }
        run.feed([Self.targeted(id, [])])
        #expect(Self.targets(run) == [Self.items(Self.drag), Self.items(Self.drag)])
        #expect(run.pullItem(SimItems.request(1, item: 2)).map { (try? $0.get()) != nil } == true)
        #expect(run.state == ConnectionState.established)
    }

    @Test("STEP_NAMED names the promises, the END sizes every item, and every item pulls from the taken offer")
    func delivered() throws {
        let (run, id) = try Self.taking()
        run.feed([Self.naming(id, ["IMG_0042.heic"])])
        #expect(Self.namings(run) == [[Data("IMG_0042.heic".utf8)]])
        #expect(Self.ended(run).isEmpty)

        run.feed([Self.caught(id, [8192, 2048, 4096])])
        #expect(
            Self.ended(run) == [
                .caught(DragDelivery(names: [0: Data("IMG_0042.heic".utf8)], sizes: [0: 8192, 1: 2048, 2: 4096]))
            ])
        for item in 0..<3 {
            #expect(
                run.pullItem(SimItems.request(1, item: UInt32(item))).map { (try? $0.get()) != nil } == true,
                "item \(item) did not pull")
        }
        #expect(!Self.offerEnded(run), "the taken offer ended before the host released it")
        #expect(run.state == ConnectionState.established)
    }

    @Test("a CAUGHT with no STEP_NAMED delivered nothing, whatever sizes it names")
    func undelivered() throws {
        let (plain, id) = try Self.taking()
        plain.feed([Self.caught(id)])
        #expect(Self.ended(plain) == [.caught(nil)])

        let (sized, other) = try Self.taking()
        sized.feed([Self.caught(other, [4096])])
        #expect(Self.ended(sized) == [.caught(nil)])
        #expect(sized.state == ConnectionState.established)
    }

    @Test("a drag with no promises is named by an empty STEP_NAMED")
    func noPromises() throws {
        let (run, id) = try Self.taking([Self.named("Folder", .folder)])
        run.feed([Self.naming(id, []), Self.caught(id, [10])])
        #expect(Self.ended(run) == [.caught(DragDelivery(names: [:], sizes: [0: 10]))])
    }

    // MARK: - A hostile STEP_NAMED

    static let hostileNames: [(label: String, names: [String])] = [
        ("too few names", []),
        ("too many names", ["a.heic", "b.heic"]),
        ("a name with a path", ["../evil.plist"]),
        ("an empty name", [""]),
        ("a name alike an unpromised item's, ignoring case", ["A.TXT"]),
    ]

    // MARK: - A hostile TARGETED

    static let hostileTargets: [(label: String, items: [Representation])] = [
        ("no items", []),
        ("an item with no FILE or FOLDER", [SimItems.representation(.inline, size: 4)]),
        ("an item named with a path", [named("../evil.plist", .file)]),
        ("estimates past 2^63-1", [named("a", .file, size: Int(Int64.max)), named("b", .file, size: 1)]),
    ]

    @Test(
        "a first TARGETED its offer cannot carry resets the take MALFORMED_MESSAGE", arguments: hostileTargets.indices)
    func hostileTarget(_ index: Int) throws {
        let (run, id) = try Self.opened()
        run.feed([Self.targeted(id, Self.hostileTargets[index].items)])
        #expect(Self.resetMalformed(run), "\(Self.hostileTargets[index].label): \(Self.ended(run))")
        #expect(Self.targets(run).isEmpty)
        #expect(run.readItem(Self.token) == nil, "the offer took items")
        #expect(run.state == ConnectionState.established)
    }

    @Test("a later TARGETED listing items resets the take MALFORMED_MESSAGE")
    func laterTargetListingItems() throws {
        let (run, id) = try Self.taking()
        run.feed([Self.targeted(id, Self.drag)])
        #expect(Self.resetMalformed(run))
    }

    @Test("a STEP_NAMED before the first TARGETED resets the take MALFORMED_MESSAGE")
    func namedBeforeTargeted() throws {
        let (run, id) = try Self.opened()
        run.feed([Self.naming(id, [])])
        #expect(Self.resetMalformed(run))
    }

    @Test("a DRAG_OFFER listing items is reset MALFORMED_MESSAGE, and a peer offers none")
    func dragOfferListsNoItems() throws {
        let run = HostileRun(local: .host, seed: 1, items: true)
        run.feed(
            [
                HostileItems.peerHello,
                WireFrames.open(1, .dragOffer, body: HostileItems.header(token: Self.token, count: 1)),
            ], preamble: true)
        #expect(run.streamResets.map(\.code) == [.malformedMessage])

        let peer = HostileRun(local: .peer, seed: 1, items: true)
        peer.feed(
            [WireFrames.hello(role: .host, items: true), WireFrames.session { $0.policy = HostileItems.policy }],
            preamble: true)
        #expect(peer.offerItems(SimItems.offer(1, [[Self.drag[1]]]), feature: .drag) != nil)
        #expect(peer.offerItems(SimItems.offer(1, []), feature: .drag) == nil)
    }

    @Test("a STEP_NAMED its taken offer cannot take resets the take MALFORMED_MESSAGE", arguments: hostileNames.indices)
    func hostileNaming(_ index: Int) throws {
        let (run, id) = try Self.taking()
        run.feed([Self.naming(id, Self.hostileNames[index].names)])
        #expect(Self.resetMalformed(run), "\(Self.hostileNames[index].label): \(Self.ended(run))")
        #expect(Self.namings(run).isEmpty)
        #expect(!Self.offerEnded(run))
        #expect(run.state == ConnectionState.established)
    }

    @Test("two promises named alike, ignoring case, reset the take MALFORMED_MESSAGE")
    func duplicateNames() throws {
        let (run, id) = try Self.taking([
            Self.named("Untitled.heic", .file, promised: true), Self.named("Untitled.heic", .file, promised: true),
        ])
        run.feed([Self.naming(id, ["IMG.heic", "img.HEIC"])])
        #expect(Self.resetMalformed(run))
    }

    @Test("a second STEP_NAMED resets the take MALFORMED_MESSAGE")
    func namedTwice() throws {
        let (run, id) = try Self.taking()
        run.feed([Self.naming(id, ["IMG.heic"]), Self.naming(id, ["IMG.heic"])])
        #expect(Self.namings(run).count == 1)
        #expect(Self.resetMalformed(run))
    }

    // MARK: - A hostile END

    @Test(
        "sizes its taken offer cannot take end the take CAUGHT undelivered",
        arguments: [[], [1, 2], [1, 2, 3, 4], [UInt64.max, 0, 0], [UInt64(Int64.max), 1, 0]] as [[UInt64]])
    func hostileSizes(_ sizes: [UInt64]) throws {
        let (run, id) = try Self.taking()
        run.feed([Self.naming(id, ["IMG.heic"]), Self.caught(id, sizes)])
        #expect(Self.ended(run) == [.caught(nil)])
        #expect(!Self.offerEnded(run))
        #expect(run.state == ConnectionState.established)
    }

    // MARK: - The peer

    @Test(
        "the peer carries the drag on its take, its writer stalled: TARGETED's items, STEP_NAMED, then the CAUGHT END; it resets nothing, and only the host's release ends the taken offer"
    )
    func peerDeliversOnTheTake() throws {
        let run = HostileRun(local: .peer, seed: 1, items: true)
        run.feed(
            [WireFrames.hello(role: .host, items: true), WireFrames.session { $0.policy = HostileItems.policy }],
            preamble: true)
        #expect(run.offerItems(SimItems.offer(1, []), feature: .drag) == nil)
        run.feed([WireFrames.open(2, .dragTake, body: HostileItems.take(Self.token))])
        let id = try #require(
            run.peerEvents.compactMap { event -> DragTakeID? in
                if case .dragTake(.requested(let id, _)) = event { return id }
                return nil
            }.first)
        run.writerStalled = true
        run.input(.dragTake(id, .report(.targeted(Self.items(Self.drag)))))
        run.input(.dragTake(id, .report(.targeted(Self.items(Self.drag)))))
        run.input(.dragTake(id, .report(.named([Data("IMG.heic".utf8)]))))
        run.input(.dragTake(id, .caught(sizes: [8192, 2048, 4096])))
        run.writerStalled = false
        run.drain()

        #expect(!run.written.contains { $0.type == .reset }, "the peer reset a stream: \(run.written)")
        let onTake = run.written.filter { $0.streamID == id.stream }
        let reports = onTake.filter { $0.type == .data }.compactMap {
            try? Kernova_V2_DragTakeReport(serializedBytes: $0.payload)
        }
        #expect(reports.map(\.step) == [.targeted, .targeted, .named])
        #expect(reports.map(\.items.count) == [3, 0, 0], "only the first TARGETED lists the items")
        #expect(reports.last?.promiseNames == [Data("IMG.heic".utf8)])
        let end = try #require(onTake.last.flatMap { $0.type == .end ? $0 : nil })
        #expect(try Kernova_V2_DragTakeOutcome(serializedBytes: end.payload).sizes == [8192, 2048, 4096])

        let takenEnded = {
            run.peerEvents.contains {
                if case .items(.offerEnded(_, .local, let token, _)) = $0 { token == Self.token } else { false }
            }
        }
        #expect(!takenEnded(), "the taken offer ended before the host released it")
        let offerStream = try #require(
            run.written.first { frame in
                guard frame.type == .open, let open = try? Kernova_V2_Open(serializedBytes: frame.payload) else {
                    return false
                }
                return (try? Kernova_V2_ItemSetHeader(serializedBytes: open.body))?.token == Self.token
            }?.streamID)
        run.feed([Unit.end(offerStream.rawValue)])
        #expect(takenEnded(), "the host's release did not end the taken offer")
    }
}
