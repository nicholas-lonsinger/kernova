import Foundation
import KernovaAgentCore
import KernovaClipboardItems
import KernovaKit
import KernovaTestSupport
import KernovaWire
import Testing

/// Every sequence of what can happen to a host's clipboard end and a guest's, to a fixed depth, each step checked
/// against a reference model of the clipboard rules: a side offers only at a trigger its gate admits, the far side
/// takes an offer only as its own gate admits it and not across an offer of the host's, an offer lives only while
/// its source holds what it offered and nothing reset either side since, what an end wrote of the far side's offer
/// stands only while that offer does, a request of the host's whose answer is not taken is refused once unless a
/// rule let it go unheard — and, once nothing is in flight, the last copy a trigger offered is written on the far
/// side unless a rule let it go.
///
/// Every read of a pasteboard lands, and every offer's open is answered, only as a step of its own, so each other
/// step can land between a read's start and its end and between an open's start and its answer; each sequence
/// ends by landing, answering and delivering everything still in flight, once in each ``DrainOrder``.
///
/// The model knows the rules, not the code: what each step permits it computes from the ends' gates, the link, the
/// copies each user made and when each end's poll started, and the offers it observes on the wire.
@Suite("ClipboardEnd sweep", .caseScoped)
@MainActor
struct ClipboardEndSweepTests {
    typealias Side = ClipboardWire.Side

    enum Action: Hashable, CustomStringConvertible {
        /// A side's user copies something new.
        case copy(Side)
        /// The host's "Copy to Guest".
        case command
        /// The host's "Copy to Mac".
        case request
        /// A side's gate flips; a change of the clipboard setting flips each side's in turn.
        case gate(Side)
        case linkDown
        case linkUp
        /// The guest's session gains or loses the console.
        case guestMayOffer(Bool)
        /// The oldest message toward a side arrives.
        case deliver(Side)
        /// The oldest message toward a side, an offer, is reset over its budget by that side's item registry.
        case overBudget(Side)
        /// Both pasteboards' watches tick.
        case poll
        /// The oldest read of a side's pasteboard lands.
        case land(Side)
        /// A side's oldest open is answered.
        case answer(Side)
        /// A side pastes its write of the far side's offer.
        case paste(Side)

        var description: String {
            switch self {
            case .copy(let side): "copy(\(side))"
            case .command: "command"
            case .request: "request"
            case .gate(let side): "gate(\(side))"
            case .linkDown: "linkDown"
            case .linkUp: "linkUp"
            case .guestMayOffer(let may): "guestMayOffer(\(may))"
            case .deliver(let side): "deliver(→\(side))"
            case .overBudget(let side): "overBudget(→\(side))"
            case .poll: "poll"
            case .land(let side): "land(\(side))"
            case .answer(let side): "answer(\(side))"
            case .paste(let side): "paste(\(side))"
            }
        }
    }

    /// Where a sweep starts: both ends under one gate and linked, each pasteboard empty or holding a copy its
    /// user made before the link came up.
    struct Start: CustomStringConvertible {
        let gate: ClipboardOfferGate
        let copiedBefore: Bool

        static let all = [ClipboardOfferGate.everyCopy, .onCommand].flatMap { gate in
            [false, true].map { Start(gate: gate, copiedBefore: $0) }
        }

        var description: String { "\(gate)\(copiedBefore ? ", each side holding a copy made before the link" : "")" }
    }

    /// The order a sequence finishes what it has in flight in, a step at a time.
    enum DrainOrder: CaseIterable, CustomStringConvertible {
        /// The host's steps before the guest's — on each side a delivery toward it, then a landing, then an answer
        /// — so the far side hears an offer before its opener knows it opened.
        case deliveriesFirst
        /// Every landing, then every answer, then every delivery: both sides offer what they read before either
        /// hears the other's, so the offers cross.
        case landingsFirst

        /// The step this order takes next among `enabled`; nil once nothing is in flight.
        func next(among enabled: [Action]) -> Action? {
            func first(_ kinds: (Action) -> Bool) -> Action? { enabled.first(where: kinds) }
            switch self {
            case .deliveriesFirst:
                return first { action in
                    switch action {
                    case .land, .answer, .deliver: true
                    default: false
                    }
                }
            case .landingsFirst:
                return first { if case .land = $0 { true } else { false } }
                    ?? first { if case .answer = $0 { true } else { false } }
                    ?? first { if case .deliver = $0 { true } else { false } }
            }
        }

        var description: String {
            switch self {
            case .deliveriesFirst: "deliveries first"
            case .landingsFirst: "landings first"
            }
        }
    }

    /// The deepest sequence the sweep runs from each start, before it lets what is in flight finish: the deepest
    /// that runs in seconds.
    static let depth = 4

    private let staging = TestStagingRoot()

    @Test(
        "Every sequence of copies, commands, requests, gate, link and console changes, deliveries, over-budget offers, polls, landings, answers and pastes keeps the rules"
    )
    func sweep() async throws {
        for start in Start.all {
            let root = try await Run.start(staging: staging.root, start, replaying: [])
            guard try await explore(root, prefix: [], from: start, depth: Self.depth) else { return }
        }
    }

    /// Explores every enabled action after `prefix`, which `run` has just stepped through, to `depth` more steps,
    /// and then lets everything in flight finish in each drain order; the last action, and the last drain order,
    /// continue on `run` itself, every other on a fresh replay of `prefix`. False once a sequence broke the rules,
    /// which it recorded.
    private func explore(_ run: Run, prefix: [Action], from start: Start, depth: Int) async throws -> Bool {
        guard depth > 0 else {
            // With nothing in flight, every order drains nothing.
            guard DrainOrder.deliveriesFirst.next(among: run.enabled) != nil else { return true }
            for (index, order) in DrainOrder.allCases.enumerated() {
                let leaf =
                    index == DrainOrder.allCases.count - 1
                    ? run : try await Run.start(staging: staging.root, start, replaying: prefix)
                guard let (drained, violation) = try await leaf.drain(order) else { continue }
                Issue.record("Starting \(start), after \(prefix + drained), drained \(order): \(violation)")
                return false
            }
            return true
        }
        let actions = run.enabled
        for (index, action) in actions.enumerated() {
            let child =
                index == actions.count - 1 ? run : try await Run.start(staging: staging.root, start, replaying: prefix)
            let sequence = prefix + [action]
            if let violation = try await child.step(action) {
                Issue.record("Starting \(start), after \(sequence): \(violation)")
                return false
            }
            guard try await explore(child, prefix: sequence, from: start, depth: depth - 1) else { return false }
        }
        return true
    }

    /// One sequence's ends and its model.
    @MainActor
    final class Run {
        let pair: ClipboardEndPair
        var model: Model

        private init(pair: ClipboardEndPair, model: Model) {
            self.pair = pair
            self.model = model
        }

        /// A run from `start`, stepped through `prefix`.
        static func start(staging: ProcessStagingRoot, _ start: Start, replaying prefix: [Action]) async throws -> Run {
            let model = Model(start)
            let copied =
                start.copiedBefore ? Dictionary(uniqueKeysWithValues: Side.allCases.map { ($0, model.name($0)) }) : [:]
            let pair = ClipboardEndPair(staging: staging, gate: start.gate, copied: copied, holdsSteps: true)
            let run = Run(pair: pair, model: model)
            try await run.pair.settle()
            for action in prefix {
                if let violation = try await run.step(action) {
                    throw TestFailure("a replay of \(prefix) departed at \(action): \(violation)")
                }
            }
            return run
        }

        var enabled: [Action] {
            var actions: [Action] = [.copy(.host), .copy(.guest)]
            // The host's user is offered its commands only while its gate is on command.
            if model.linked, model.gate[.host] == .onCommand { actions += [.command, .request] }
            actions.append(model.linked ? .linkDown : .linkUp)
            actions += [.gate(.host), .gate(.guest)]
            actions.append(.guestMayOffer(!model.mayOffer[.guest]!))
            for side in Side.allCases {
                if let next = pair.wire?.queue(toward: side).first {
                    actions.append(.deliver(side))
                    if case .opened = next { actions.append(.overBudget(side)) }
                }
                if pair.heldReads(on: side) > 0 { actions.append(.land(side)) }
                if !(pair.wire?.unansweredOpens(side).isEmpty ?? true) { actions.append(.answer(side)) }
                if case .write = pair.holding(side) { actions.append(.paste(side)) }
            }
            actions.append(.poll)
            return actions
        }

        /// Lands every read, answers every open and delivers every message, a step at a time in `order`, until
        /// nothing is in flight, checking each step: nil when every one keeps the rules, else the steps taken and the
        /// rule the last broke.
        func drain(_ order: DrainOrder) async throws -> (steps: [Action], violation: String)? {
            var steps: [Action] = []
            while let next = order.next(among: enabled) {
                steps.append(next)
                if let violation = try await step(next) { return (steps, violation) }
            }
            return nil
        }

        /// Takes `action`, waits for what it set off, and checks the result: nil when it keeps the rules.
        func step(_ action: Action) async throws -> String? {
            let requests = pair.wire?.requests.count ?? 0
            var paste: (side: Side, serves: String?, got: Data?)?
            switch action {
            case .copy(let side):
                model.copied(side)
                pair.copy(model.name(side), on: side)
            case .command:
                model.commanded(holding: pair.holding(.host))
                pair.host.offerOnCommand()
            case .request:
                pair.host.requestOffer()
            case .gate(let side):
                model.flipGate(side)
                pair.setGate(model.gate[side]!, on: side)
            case .linkDown:
                model.linkChanged(linked: false)
                pair.linkDown()
            case .linkUp:
                model.linkChanged(linked: true)
                pair.linkUp()
            case .guestMayOffer(let mayOffer):
                model.guestMayOffer(mayOffer)
                pair.setGuestMayOffer(mayOffer)
            case .deliver(let side):
                if let wire = pair.wire, let message = wire.queue(toward: side).first {
                    let crossed = side == .host && (!wire.open(.host).isEmpty || model.hostHoldsUnsentCopy(pair))
                    model.delivered(message, toward: side, crossed: crossed, holding: pair.holding(side))
                    wire.deliverNext(toward: side)
                }
            case .overBudget(let side):
                if case .opened(let header, _)? = pair.wire?.queue(toward: side).first { model.overBudget(header) }
                pair.wire?.refuseOverBudget(toward: side)
            case .poll:
                model.polled()
                pair.poll()
            case .land(let side):
                pair.landRead(on: side)
            case .answer(let side):
                pair.wire?.answerOldestOpen(of: side)
            case .paste(let side):
                let serves = pasteServes(on: side)
                paste = (side, serves, try await pair.paste(on: side))
            }
            try await pair.settle()
            if case .request = action, let token = pair.wire?.requests.dropFirst(requests).last {
                model.hostRequest = token
            }
            if let paste {
                if let got = paste.got {
                    guard case .write(let name) = pair.holding(paste.side), got == Data(name.utf8) else {
                        return "\(paste.side)'s paste got bytes its write's offer does not hold"
                    }
                    model.pasted[paste.side] = true
                } else if let serves = paste.serves {
                    return
                        "\(paste.side)'s paste of \(serves) got nothing, while its source stood and its offer was open"
                }
            }
            return check()
        }

        /// The copy a paste on `side` must get, by its name: that of the far side's offer `side` took last, while the
        /// far side holds it open and answered, its source still standing where the far side's watch has seen it;
        /// nil when the rules let the paste fail.
        private func pasteServes(on side: Side) -> String? {
            guard case .write(let name) = pair.holding(side), let wire = pair.wire, let token = model.lastTaken[side],
                model.offers[token]?.name == name, wire.open(side.far)[token] != nil,
                !wire.unansweredOpens(side.far).contains(token), model.dirty[side.far] != true,
                pair.holding(side.far) == .user(name)
            else { return nil }
            return name
        }

        /// What the rules say of the state the step left.
        private func check() -> String? {
            let refusals = (pair.events[.host] ?? []).count { if case .requestRefused = $0 { true } else { false } }
            guard refusals == model.requestRefusals else {
                return "the host heard \(refusals) refusal(s) of its requests; the rules owe \(model.requestRefusals)"
            }
            for side in Side.allCases {
                for offer in pair.wire?.opened(side).dropFirst(model.seen[side] ?? 0) ?? [] {
                    model.seen[side, default: 0] += 1
                    if let violation = permits(offer, by: side) { return violation }
                    model.record(offer, by: side)
                }
            }
            for side in Side.allCases {
                switch pair.holding(side) {
                case .user(let name) where name != model.name(side):
                    return "\(side)'s pasteboard holds \(name), not its user's last copy \(model.name(side))"
                case .data where model.pasted[side] != true:
                    return "\(side)'s pasteboard holds written data, with no paste to have read any"
                case .write(let name):
                    guard model.mayHold(name, on: side) else {
                        return
                            "\(side)'s pasteboard holds a promised write of \(name), which no live offer it took serves"
                    }
                case .user, .data, .nothing:
                    break
                }
            }
            guard let wire = pair.wire else { return nil }
            // A side's own withdrawal takes effect on its side at once, once it knows the offer opened.
            for side in Side.allCases {
                let unanswered = Set(wire.unansweredOpens(side))
                for token in wire.open(side).keys where !unanswered.contains(token) {
                    guard let offer = model.offers[token] else { return "\(side) holds an offer the model never saw" }
                    guard offer.openedAt == model.ownResets[side] else {
                        return "\(side)'s offer of \(offer.name) outlived a reset of \(side)'s offers"
                    }
                    if model.dirty[side] != true, pair.holding(side) != .user(offer.name) {
                        return "\(side) still offers \(offer.name), which its pasteboard moved on from"
                    }
                }
            }
            let inFlight = Side.allCases.contains {
                !wire.queue(toward: $0).isEmpty || pair.heldReads(on: $0) > 0 || !wire.unansweredOpens($0).isEmpty
            }
            return inFlight ? nil : checkQuiescent(wire)
        }

        /// Whether `side` may have opened `offer` now, as a trigger its gate admitted asked it to.
        private func permits(_ offer: ItemOffer, by side: Side) -> String? {
            let name = ClipboardEndPair.name(of: offer.items)
            let gate = model.gate[side]!
            guard pair.holding(side) == .user(name), name == model.name(side) else {
                return "\(side) offered \(name), which is not its user's copy on its pasteboard"
            }
            guard model.linked, model.mayOffer[side]! else { return "\(side) offered \(name) while it may not offer" }
            if !offer.request.isEmpty {
                guard side == .guest, gate == .onCommand, model.guestRequest == offer.request else {
                    return "\(side) answered a request no admitted trigger asked it to"
                }
                model.guestRequest = nil
                return nil
            }
            switch gate {
            case .onCommand:
                guard side == .host, model.pendingCommand else {
                    return "\(side) offered \(name) on command with no command to answer"
                }
                model.pendingCommand = false
            case .everyCopy:
                guard (model.copies[side] ?? 0) > (model.baseline[side] ?? 0) else {
                    return "\(side) offered \(name) at no copy its gate admits after its poll began"
                }
            }
            return nil
        }

        /// With nothing in flight: every open offer is written on the far side, every write is of an open offer, no
        /// request is left open, and the last copy each side's trigger offered is written on the far side unless a
        /// rule let it go.
        private func checkQuiescent(_ wire: ClipboardWire) -> String? {
            guard wire.openRequests.isEmpty else {
                return "the host's request is still open with nothing in flight to answer it"
            }
            for side in Side.allCases {
                for token in wire.open(side).keys {
                    guard let offer = model.offers[token] else { return "\(side) holds an offer the model never saw" }
                    if model.dirty[side.far] != true, pair.holding(side.far) != .write(offer.name) {
                        return
                            "\(side) still offers \(offer.name), which \(side.far) holds no write of: \(pair.holding(side.far))"
                    }
                }
                if case .write(let name) = pair.holding(side),
                    !wire.open(side.far).values.contains(where: { ClipboardEndPair.name(of: $0.items) == name })
                {
                    return "\(side) holds a write of \(name), which \(side.far) no longer offers"
                }
            }
            if model.hostRequest != nil { return "the host's request was never answered" }
            for side in Side.allCases {
                if let violation = owedWrite(of: side) { return violation }
            }
            return nil
        }

        /// Whether the last copy a trigger of `side`'s offered is written on the far side, when nothing the rules
        /// name let it go: a reset of either side since, a copy over it on either side, the far side's gate, the far
        /// side's item registry, or a crossing of the host's.
        private func owedWrite(of side: Side) -> String? {
            guard let owed = model.owed[side], model.linked, owed.resets == model.resets,
                owed.ownResets == model.ownResets[side], owed.copy == model.copies[side], model.dirty[side] != true,
                pair.holding(side) == .user(model.name(side))
            else { return nil }
            let name = model.name(side)
            let offered = model.offers.values.filter {
                $0.side == side && $0.name == name && $0.request == owed.request
            }
            guard let offer = offered.max(by: { $0.sequence < $1.sequence }) else {
                return "\(side)'s trigger admitted \(name) and nothing offered it"
            }
            guard let arrived = offer.arrived, arrived.taken, !offer.overBudget,
                arrived.farCopies == model.copies[side.far]
            else { return nil }
            guard pair.holding(side.far) == .write(name) else {
                return "\(side)'s \(name), offered and taken, is not written on \(side.far): \(pair.holding(side.far))"
            }
            return nil
        }
    }

    /// The clipboard rules, over what each step did.
    @MainActor
    struct Model {
        /// One offer opened on the connection now, as the rules see it.
        struct Offer {
            let side: Side
            let name: String
            let request: Data
            /// Its order among the offers the model saw.
            let sequence: Int
            /// Its side's count of resets of its own offers when it opened.
            let openedAt: Int
            /// The far side's reset count when the offer reached it, whether the rules had the far side take it,
            /// and the far side's copy count then.
            var arrived: (at: Int, taken: Bool, farCopies: Int)?
            /// Its withdrawal reached the far side.
            var withdrawn = false
            /// The far side's item registry reset it over budget, before its end heard of it.
            var overBudget = false
        }

        /// The last copy a side's admitted trigger is to offer, and the resets standing then.
        struct Owed {
            let copy: Int
            /// The host's request it answers; empty for any other trigger.
            let request: Data
            let resets: [Side: Int]
            let ownResets: Int
        }

        var linked = true
        var gate: [Side: ClipboardOfferGate]
        /// Each side's gate changes and link changes so far: each ends what the side took of the far side's.
        var resets: [Side: Int] = [.host: 0, .guest: 0]
        /// Each side's gate changes, link changes and losses of its right to offer: each ends what it offered.
        var ownResets: [Side: Int] = [.host: 0, .guest: 0]
        var mayOffer: [Side: Bool] = [.host: true, .guest: true]
        /// How many copies each side's user made.
        var copies: [Side: Int] = [.host: 0, .guest: 0]
        /// The copy count when each side's poll began: a copy after it is one passthrough offers.
        var baseline: [Side: Int] = [.host: 0, .guest: 0]
        /// A side's user copied since its pasteboard's watch last ticked, so its end cannot know yet.
        var dirty: [Side: Bool] = [.host: false, .guest: false]
        /// A side pasted its write of the far side's offer since its user last copied.
        var pasted: [Side: Bool] = [.host: false, .guest: false]
        /// The host's request a guest offer may answer, until one does or it ends unanswered.
        var hostRequest: Data?
        /// How many of the host's requests ended with their answer not taken, each heard once.
        var requestRefusals = 0
        /// The host's command, admitted, its offer not yet opened.
        var pendingCommand = false
        /// The host's request the guest admitted, its answer not yet opened.
        var guestRequest: Data?
        /// The last copy each side's admitted trigger is to offer.
        var owed: [Side: Owed] = [:]
        /// The far side's offer each side took last, by token.
        var lastTaken: [Side: Data] = [:]
        /// Every offer opened on the connection now, by token.
        var offers: [Data: Offer] = [:]
        /// How many of each side's offers on the connection now the model saw.
        var seen: [Side: Int] = [.host: 0, .guest: 0]
        private var nextSequence = 0

        init(_ start: Start) {
            gate = [.host: start.gate, .guest: start.gate]
            if start.copiedBefore {
                copies = [.host: 1, .guest: 1]
                baseline = copies
            }
        }

        /// The name of `side`'s user's latest copy.
        func name(_ side: Side) -> String { "\(side == .host ? "h" : "g")\(copies[side] ?? 0)" }

        mutating func copied(_ side: Side) {
            copies[side, default: 0] += 1
            dirty[side] = true
            pasted[side] = false
        }

        /// Both watches tick: each side offering at every copy owes the copy made since the last.
        mutating func polled() {
            for side in Side.allCases where dirty[side] == true {
                dirty[side] = false
                if linked, gate[side] == .everyCopy, mayOffer[side]!, copies[side]! > baseline[side]! {
                    owe(side, request: Data())
                }
            }
        }

        /// The host's command, with its pasteboard holding `holding`.
        mutating func commanded(holding: ClipboardEndPair.Holding) {
            guard linked, gate[.host] == .onCommand else { return }
            pendingCommand = true
            if holding == .user(name(.host)) { owe(.host, request: Data()) }
        }

        /// The far side's item registry reset the offer `header` announces over budget. An answer to the host's
        /// request among them leaves the request to end unanswered once the guest's release of it arrives.
        mutating func overBudget(_ header: ItemSetHeaderValue) {
            offers[header.token]?.overBudget = true
        }

        private mutating func owe(_ side: Side, request: Data) {
            owed[side] = Owed(copy: copies[side]!, request: request, resets: resets, ownResets: ownResets[side]!)
        }

        mutating func flipGate(_ side: Side) {
            gate[side] = gate[side] == .everyCopy ? .onCommand : .everyCopy
            resets[side, default: 0] += 1
            ownResets[side, default: 0] += 1
            baseline[side] = copies[side]
            switch side {
            case .host:
                hostRequest = nil
                pendingCommand = false
            case .guest:
                guestRequest = nil
            }
        }

        mutating func linkChanged(linked: Bool) {
            self.linked = linked
            for side in Side.allCases {
                resets[side, default: 0] += 1
                ownResets[side, default: 0] += 1
                baseline[side] = copies[side]
            }
            if hostRequest != nil { requestRefusals += 1 }
            hostRequest = nil
            pendingCommand = false
            guestRequest = nil
            offers = [:]
            seen = [.host: 0, .guest: 0]
        }

        mutating func guestMayOffer(_ mayOffer: Bool) {
            self.mayOffer[.guest] = mayOffer
            baseline[.guest] = copies[.guest]
            guard !mayOffer else { return }
            ownResets[.guest, default: 0] += 1
            guestRequest = nil
        }

        mutating func record(_ offer: ItemOffer, by side: Side) {
            offers[offer.token] = Offer(
                side: side, name: ClipboardEndPair.name(of: offer.items), request: offer.request,
                sequence: nextSequence, openedAt: ownResets[side] ?? 0)
            nextSequence += 1
        }

        /// Whether the host holds a copy passthrough is yet to offer, which a guest offer arriving now crosses.
        func hostHoldsUnsentCopy(_ pair: ClipboardEndPair) -> Bool {
            linked && gate[.host] == .everyCopy && copies[.host]! > baseline[.host]!
                && pair.holding(.host) == .user(name(.host))
                && !offers.values.contains { $0.side == .host && $0.name == name(.host) }
        }

        /// `message` reaches `side`, whose pasteboard holds `holding`; an offer reaching the host `crossed` one of
        /// the host's own that it had not seen.
        mutating func delivered(
            _ message: ClipboardWire.Message, toward side: Side, crossed: Bool, holding: ClipboardEndPair.Holding
        ) {
            switch message {
            case .requested(let token):
                guard linked, gate[.guest] == .onCommand, mayOffer[.guest]! else { return }
                guestRequest = token
                if holding == .user(name(.guest)) { owe(.guest, request: token) }
            case .opened(let header, _):
                // A guest takes every host offer: the host offers on command only by its user's command. The host
                // takes an answer only to the request it has open, and any other offer only at every copy, but
                // neither across an offer of its own the guest had not seen.
                let taken =
                    side == .guest
                    || (!crossed
                        && (header.request.isEmpty ? gate[.host] == .everyCopy : header.request == hostRequest))
                if side == .host, !header.request.isEmpty, header.request == hostRequest { hostRequest = nil }
                offers[header.token]?.arrived = (resets[side] ?? 0, taken, copies[side] ?? 0)
                if taken { lastTaken[side] = header.token }
            case .withdrawn(let token, _):
                offers[token]?.withdrawn = true
                // The host called its request off: the guest answers it with nothing.
                if side == .guest, token == guestRequest { guestRequest = nil }
                if side == .guest, owed[.guest]?.request == token { owed[.guest] = nil }
            case .refused(let token, let error):
                guard side == .host, token == hostRequest else { return }
                hostRequest = nil
                // An answer naming only what the host's clipboard holds already ends the request unheard.
                if error.code != .clipboardAlreadyHeld { requestRefusals += 1 }
            case .released(let token):
                // The guest releases the host's request once its answer opened, which arrives first: a request
                // still open here lost its answer on the way.
                guard side == .host, token == hostRequest else { return }
                hostRequest = nil
                requestRefusals += 1
            }
        }

        /// Whether `side` may hold a promised write of the far side's copy `name`: an offer of it reached `side`
        /// since `side` last reset, the rules had `side` take it, and no withdrawal of it has reached `side`.
        func mayHold(_ name: String, on side: Side) -> Bool {
            offers.values.contains { offer in
                guard offer.side == side.far, offer.name == name, !offer.withdrawn, let arrived = offer.arrived else {
                    return false
                }
                return arrived.taken && arrived.at == resets[side]
            }
        }
    }
}
