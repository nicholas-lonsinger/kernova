#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentSimulation
import KernovaPortableTestSupport
import KernovaWire
import Testing

/// A drag is one offer, whose items its take carries: the peer's DRAG_OFFER lists none, the take lists the drag
/// as its catcher sees it before its first `TARGETED`, a delivering drop names the promises and sizes every
/// item before the CAUGHT END, each fact in a MESSAGE of its own, and the offer carries the drag throughout,
/// ending only when the host releases it. What the peer says is checked as an offer is, held to the take's
/// order, and a hostile word fails the take cleanly.
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

    static func items(_ representations: [Representation]) -> [OfferedItem] {
        representations.map { SimItems.offer(1, [[$0]]).items[0] }
    }

    /// `count` plain files, each FILE representation holding only a 54-byte name.
    static func fiftyFourByteNames(_ count: Int) -> [OfferedItem] {
        (0..<count).map { index in
            var representation = Representation()
            representation.storage = .file
            representation.name = Data(padded(index, to: 54).utf8)
            var item = OfferedItem()
            item.representations = [representation]
            return item
        }
    }

    /// `index` in decimal, zero-padded to `length` characters.
    static func padded(_ index: Int, to length: Int) -> String {
        let digits = String(index)
        return String(repeating: "0", count: length - digits.count) + digits
    }

    // MARK: - Reports a hostile peer writes

    /// A real host judging by `policy`, holding the far peer's DRAG_OFFER on stream 1, and its take of it.
    static func opened(policy: ReceiverPolicy = .production) throws -> (HostileRun, DragTakeID) {
        let run = HostileRun(local: .host, seed: 1, items: true, receiverPolicy: policy)
        run.feed(
            [
                HostileItems.peerHello,
                WireFrames.open(1, .dragOffer, body: HostileItems.header(token: token, count: 0)),
                Unit.end(1),
            ], preamble: true)
        let id = try #require(run.takeDrag(token)).get()
        return (run, id)
    }

    /// The peer's `report` on take `id`.
    static func report(_ id: DragTakeID, _ report: Kernova_V2_DragTakeReport.OneOf_Report) -> Frame {
        var message = Kernova_V2_DragTakeReport()
        message.report = report
        return WireFrames.message(id.stream.rawValue, message)
    }

    /// The peer's listing of `items` on take `id`.
    static func listing(_ id: DragTakeID, _ items: [OfferedItem]) -> [Frame] {
        [report(id, .itemCount(UInt32(items.count)))] + items.map { report(id, .item($0)) }
    }

    /// The peer's naming of a drag's promises on take `id`.
    static func naming(_ id: DragTakeID, _ names: [String]) -> [Frame] {
        names.map { report(id, .promiseName(Data($0.utf8))) } + [report(id, .step(.named))]
    }

    static func reports(_ run: HostileRun) -> [DragTakeReport] {
        run.hostEvents.compactMap { if case .dragTake(.report(_, let report)) = $0 { report } else { nil } }
    }

    static func ended(_ run: HostileRun) -> [DragTakeResult] {
        run.hostEvents.compactMap { if case .dragTake(.ended(_, let result)) = $0 { result } else { nil } }
    }

    /// The code this side reset its take with, when it did.
    static func resetCode(_ run: HostileRun) -> ErrorCode? {
        guard ended(run).count == 1, case .closed(.resetLocally(let error))? = ended(run).first else { return nil }
        return error.code
    }

    // MARK: - The host holds every report to the take's order

    /// One report of a hostile peer's, on a take of a drag of a promise and a plain file.
    enum Word: CaseIterable {
        case countOfTwo, countOfNone, item, itemWithNoFile, targeted, name, nameWithAPath, nameAlikeTheFile, named,
            size, armed
    }

    /// The drag the sweep's listing lists.
    static let sweptDrag = items([named("a.heic", .file, promised: true), named("b.txt", .file, size: 3)])

    /// What the host does with a word: takes it, standing as it then does, or resets the take with a code.
    enum Next {
        case takes(Stand)
        case resets(ErrorCode)
    }

    /// Where a take stands, as the sweep's precondition table reads it.
    struct Stand {
        /// Nil until a count of two began the listing; then how many items arrived.
        var received: Int?
        var names = 0
        var nameAlikeTheFile = false
        var named = false
        var sizes = 0
        /// The reports the host owes so far.
        var reports: [DragTakeReport] = []

        var listed: Bool { received == 2 }

        /// The stand after `word`, or the code the host resets the take with. Worked by hand from the
        /// grammar: order breaks STREAM_PROTOCOL_ERROR, content MALFORMED_MESSAGE.
        func after(_ word: Word) -> Next {
            var next = self
            switch word {
            case .countOfTwo:
                guard received == nil else { return .resets(.streamProtocolError) }
                next.received = 0
            case .countOfNone:
                return .resets(received == nil ? .malformedMessage : .streamProtocolError)
            case .item:
                guard let received, received < 2 else { return .resets(.streamProtocolError) }
                next.received = received + 1
                if next.listed { next.reports.append(.listed(sweptDrag)) }
            case .itemWithNoFile:
                guard let received, received < 2 else { return .resets(.streamProtocolError) }
                return .resets(.malformedMessage)
            case .targeted:
                guard listed else { return .resets(.streamProtocolError) }
                next.reports.append(.targeted)
            case .name, .nameAlikeTheFile:
                guard listed, !named, names < 1 else { return .resets(.streamProtocolError) }
                next.names += 1
                next.nameAlikeTheFile = word == .nameAlikeTheFile
            case .nameWithAPath:
                guard listed, !named, names < 1 else { return .resets(.streamProtocolError) }
                return .resets(.malformedMessage)
            case .named:
                guard listed, !named else { return .resets(.streamProtocolError) }
                guard names == 1, !nameAlikeTheFile else { return .resets(.malformedMessage) }
                next.named = true
                next.reports.append(.named([Data("IMG.heic".utf8)]))
            case .size:
                guard named, sizes < 2 else { return .resets(.streamProtocolError) }
                next.sizes += 1
            case .armed:
                next.reports.append(.armed)
            }
            return .takes(next)
        }
    }

    /// `word`'s frame on take `id`, with `stand` saying which item is next.
    static func frame(_ word: Word, on id: DragTakeID, at stand: Stand) -> Frame {
        switch word {
        case .countOfTwo: report(id, .itemCount(2))
        case .countOfNone: report(id, .itemCount(0))
        case .item: report(id, .item(sweptDrag[min(stand.received ?? 0, 1)]))
        case .itemWithNoFile: report(id, .item(items([SimItems.representation(.inline, size: 4)])[0]))
        case .targeted: report(id, .step(.targeted))
        case .name: report(id, .promiseName(Data("IMG.heic".utf8)))
        case .nameWithAPath: report(id, .promiseName(Data("../evil.plist".utf8)))
        case .nameAlikeTheFile: report(id, .promiseName(Data("B.TXT".utf8)))
        case .named: report(id, .step(.named))
        case .size: report(id, .size(7))
        case .armed: report(id, .step(.armed))
        }
    }

    /// Every sequence of up to `depth` words the table says the host takes, each extended by every word
    /// until the table says it resets the take.
    static func sequences(from stand: Stand = Stand(), depth: Int) -> [[Word]] {
        guard depth > 0 else { return [[]] }
        return Word.allCases.flatMap { word -> [[Word]] in
            guard case .takes(let next) = stand.after(word) else { return [[word]] }
            return sequences(from: next, depth: depth - 1).map { [word] + $0 }
        }
    }

    @Test("every sequence of reports up to six long is taken, or resets the take with its code, as the table says")
    func everyReportIsHeldToTheTakesOrder() throws {
        for words in Self.sequences(depth: 6) {
            let (run, id) = try Self.opened()
            var stand = Stand()
            for word in words {
                run.feed([Self.frame(word, on: id, at: stand)])
                switch stand.after(word) {
                case .takes(let next):
                    stand = next
                    #expect(Self.ended(run).isEmpty, "\(words): the take ended at \(word): \(Self.ended(run))")
                case .resets(let code):
                    #expect(Self.resetCode(run) == code, "\(words): at \(word), \(Self.ended(run))")
                }
                #expect(Self.reports(run) == stand.reports, "\(words): after \(word)")
            }
            #expect(run.state == ConnectionState.established, "\(words)")
        }
    }

    // MARK: - What a listing holds

    @Test(
        "an item breaking an offer's item's rules or the listing's estimates resets the take MALFORMED_MESSAGE",
        arguments: [
            [named("../evil.plist", .file)],
            [named("a", .file, size: Int(Int64.max)), named("b", .file, size: 1)],
        ])
    func hostileItem(_ representations: [Representation]) throws {
        let (run, id) = try Self.opened()
        run.feed(Self.listing(id, Self.items(representations)))
        #expect(Self.resetCode(run) == .malformedMessage, "\(Self.ended(run))")
        #expect(Self.reports(run).isEmpty)
        #expect(run.readItem(Self.token, item: UInt32(representations.count - 1)) == nil, "the offer took the item")
        #expect(run.state == ConnectionState.established)
    }

    // MARK: - A delivering drop's names and sizes

    @Test("sizes summing past 2^63-1 reset the take MALFORMED_MESSAGE")
    func sizesPastTheLimit() throws {
        let (run, id) = try Self.opened()
        run.feed(
            Self.listing(id, Self.items(Self.drag)) + Self.naming(id, ["IMG.heic"])
                + [Self.report(id, .size(UInt64(Int64.max))), Self.report(id, .size(1))])
        #expect(Self.resetCode(run) == .malformedMessage)
    }

    // MARK: - Drags past one MESSAGE, between a real host and peer

    /// A run of a real host and peer: the peer offers a drag, the host takes it, and the peer's owner gives
    /// `answers` at their times.
    static func takenDrag(_ answers: [(SimTime, DragTakeAnswer)]) -> (violations: [String], world: SimWorld) {
        let scenario = Scenario(
            name: "a taken drag", seeds: 1, end: .sec(10), options: ItemFeatureScenarios.options,
            script: { world in
                ItemFeatureScenarios.dragOffered(world)
                ItemFeatureScenarios.answersByHand(world)
                world.at(.ms(700)) { world in world.takeDrag(SimItems.token(1)) }
                for (time, answer) in answers {
                    world.at(time) { world in ItemFeatureScenarios.answer(answer, world) }
                }
            })
        let run = scenario.run(seed: 1)
        return (run.violations, run.world)
    }

    @Test("a drag of 5,000 items, over four MESSAGE frames' worth and the take's window, reaches the host whole")
    func aLargeListingReachesTheHost() {
        // By hand: each item's report is 62 bytes, 2 around an Item of 2 around a 58-byte Representation, so
        // 310,000 in all, past the 262,144-byte window the take's stream opens with: the listing waits on the
        // host returning credit.
        let items = Self.fiftyFourByteNames(5_000)
        let (violations, world) = Self.takenDrag([
            (.ms(800), .report(.armed)), (.ms(850), .report(.listed(items))), (.ms(860), .report(.targeted)),
        ])
        let host = ItemFeatureScenarios.items(world, .host)
        #expect(violations.isEmpty, "\(violations)")
        #expect(host?.takeReports.map(\.report) == [.armed, .listed(items), .targeted])
        #expect(host?.takesEnded.isEmpty == true, "\(String(describing: host?.takesEnded))")
    }

    @Test(
        "seeded drags of up to 2,000 items, some promised, names up to 255 bytes, over a stalling transport, reach the host as the peer gave them"
    )
    func seededDragsReachTheHostWhole() {
        for seed in UInt64(0)..<8 {
            var rng = SplitMix64(seed: seed &* 0x9E37_79B9 &+ 17)
            let count = rng.int(in: 1...2_000)
            var promised: [Int] = []
            var representations: [Representation] = []
            var promiseNames: [Data] = []
            for index in 0..<count {
                // Each name starts with its index's digits, then letters, so none is alike another.
                let digits = String(index)
                let length = max(digits.count, rng.int(in: 1...255))
                let isPromise = rng.int(in: 0...2) == 0
                representations.append(
                    Self.named(
                        isPromise ? "Untitled.heic" : "f" + digits, .file, promised: isPromise,
                        size: rng.int(in: 0...1_000)))
                if isPromise {
                    promised.append(index)
                    promiseNames.append(Data((digits + String(repeating: "x", count: length - digits.count)).utf8))
                }
            }
            let items = Self.items(representations)
            let names = promiseNames
            let sizes = (0..<count).map { _ in UInt64(rng.int(in: 0...1_000_000_000)) }
            let capacity = rng.int(in: 512...65_536)
            let stall = SimTime.ms(800 + UInt64(rng.int(in: 0...200)))
            let scenario = Scenario(
                name: "seeded drag", seeds: 1, end: .sec(20),
                options: { options in
                    ItemFeatureScenarios.options(&options)
                    options.peerToHost.capacity = capacity
                    options.faults = [.readerStall(.host, link: 0, in: .at(stall), for: .ms(400))]
                },
                script: { world in
                    ItemFeatureScenarios.dragOffered(world)
                    ItemFeatureScenarios.answersByHand(world)
                    world.at(.ms(700)) { world in world.takeDrag(SimItems.token(1)) }
                    world.at(.ms(800)) { world in ItemFeatureScenarios.answer(.report(.armed), world) }
                    world.at(.ms(810)) { world in ItemFeatureScenarios.answer(.report(.listed(items)), world) }
                    world.at(.ms(820)) { world in ItemFeatureScenarios.answer(.report(.targeted), world) }
                    world.at(.ms(900)) { world in ItemFeatureScenarios.answer(.report(.named(names)), world) }
                    world.at(.ms(950)) { world in ItemFeatureScenarios.answer(.caught(sizes: sizes), world) }
                })
            let run = scenario.run(seed: seed)
            let host = ItemFeatureScenarios.items(run.world, .host)
            #expect(run.violations.isEmpty, "seed \(seed): \(run.violations)")
            #expect(
                host?.takeReports.map(\.report) == [.armed, .listed(items), .targeted, .named(names)],
                "seed \(seed): \(count) items")
            let delivery = DragDelivery(
                names: Dictionary(uniqueKeysWithValues: zip(promised, names)),
                sizes: Dictionary(uniqueKeysWithValues: zip(sizes.indices, sizes)))
            #expect(host?.takesEnded.map(\.result) == [.caught(delivery)], "seed \(seed)")
            #expect(run.world.links.first?.state(.host) == .established, "seed \(seed)")
        }
    }

    // MARK: - The peer

    /// A peer that offers the drag of ``token`` and was asked about the host's take of it, and the take.
    static func asked() throws -> (HostileRun, DragTakeID) {
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
        return (run, id)
    }

    /// What the peer wrote on take `id`: each MESSAGE's report, in order, and its END's outcome.
    static func written(_ run: HostileRun, on id: DragTakeID) throws -> (
        reports: [Kernova_V2_DragTakeReport.OneOf_Report?], end: Kernova_V2_DragTakeOutcome?
    ) {
        let frames = run.written.filter { $0.streamID == id.stream }
        let reports = try frames.filter { $0.type == .data }.map {
            try Kernova_V2_DragTakeReport(wire: $0.payload).report
        }
        let end = try frames.first { $0.type == .end }.map {
            try Kernova_V2_DragTakeOutcome(wire: $0.payload)
        }
        return (reports, end)
    }

    @Test("a delivering drop sizing 22,000 items, past one END body, sends each size and keeps the connection")
    func sizesPastOneEndKeepTheConnection() throws {
        // By hand: 22,000 sizes of 3,000,000, 4 bytes each, would pack 88,000 bytes into one END body.
        let (run, id) = try Self.asked()
        let items = Self.items((0..<22_000).map { Self.named("f\($0)", .file) })
        let sizes = [UInt64](repeating: 3_000_000, count: 22_000)
        run.input(.dragTake(id, .report(.listed(items))))
        run.input(.dragTake(id, .report(.targeted)))
        run.input(.dragTake(id, .report(.named([]))))
        run.input(.dragTake(id, .caught(sizes: sizes)))
        // The host returns the take's credit as it reads.
        run.feed([WireFrames.window(id.stream.rawValue, 1 << 24)])

        #expect(run.state == ConnectionState.established)
        let (reports, end) = try Self.written(run, on: id)
        #expect(reports.compactMap { if case .size(let size)? = $0 { size } else { nil } } == sizes)
        #expect(end?.kind == .caught)
    }
}
