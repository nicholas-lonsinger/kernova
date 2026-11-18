import Foundation
import KernovaAgentCore
import KernovaClipboardItems
import KernovaKit
import KernovaTestSupport
import KernovaWire
import Testing

/// Every sequence of what can happen to a host's clipboard end and a guest's, to a fixed depth, each step checked
/// against a reference model of the clipboard rules: a side offers only at a trigger its gate admits, the far side
/// takes an offer only as its own gate admits it, an offer lives only while its source holds what it offered and
/// nothing reset either side since, and what an end wrote of the far side's offer stands only while that offer
/// does.
///
/// The model knows the rules, not the code: what each step permits it computes from the ends' gates, the link, the
/// copies each user made and when each end's poll started; it reads the system only for what the rules leave
/// open — whether an end took an offer the rules let it refuse — and the offers it observes on the wire.
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
        /// The gate of each side named flips.
        case gate(Set<Side>)
        case linkDown
        case linkUp
        /// The oldest message toward a side arrives.
        case deliver(Side)
        /// Both pasteboards' watches tick.
        case poll

        var description: String {
            switch self {
            case .copy(let side): "copy(\(side))"
            case .command: "command"
            case .request: "request"
            case .gate(let sides): "gate(\(sides.count == 2 ? "both" : "\(sides.first!)"))"
            case .linkDown: "linkDown"
            case .linkUp: "linkUp"
            case .deliver(let side): "deliver(→\(side))"
            case .poll: "poll"
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

    /// The deepest sequence the sweep runs from each start: the deepest that runs in a few seconds.
    static let depth = 4

    private let staging = TestStagingRoot()

    @Test(
        "Every sequence of copies, commands, requests, gate changes, link changes, deliveries and polls keeps the rules"
    )
    func sweep() async throws {
        for start in Start.all {
            let root = try await Run.start(staging: staging.root, start, replaying: [])
            guard try await explore(root, prefix: [], from: start, depth: Self.depth) else { return }
        }
    }

    /// Explores every enabled action after `prefix`, which `run` has just stepped through, to `depth` more steps;
    /// the last action continues on `run` itself, every other on a fresh replay of `prefix`. False once a sequence
    /// broke the rules, which it recorded.
    private func explore(_ run: Run, prefix: [Action], from start: Start, depth: Int) async throws -> Bool {
        guard depth > 0 else { return true }
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
            let run = Run(pair: ClipboardEndPair(staging: staging, gate: start.gate, copied: copied), model: model)
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
            actions += model.linked ? [.command, .request, .linkDown] : [.linkUp]
            actions += [.gate([.host, .guest]), .gate([.host]), .gate([.guest])]
            for side in Side.allCases where !(pair.wire?.queue(toward: side).isEmpty ?? true) {
                actions.append(.deliver(side))
            }
            actions.append(.poll)
            return actions
        }

        /// Takes `action`, waits for what it set off, and checks the result: nil when it keeps the rules.
        func step(_ action: Action) async throws -> String? {
            let opened = Dictionary(uniqueKeysWithValues: Side.allCases.map { ($0, pair.wire?.opened($0).count ?? 0) })
            let requests = pair.wire?.requests.count ?? 0
            var delivered: ClipboardWire.Message?
            switch action {
            case .copy(let side):
                model.copies[side, default: 0] += 1
                model.dirty[side] = true
                pair.copy(model.name(side), on: side)
            case .command:
                pair.host.offerOnCommand()
            case .request:
                pair.host.requestOffer()
            case .gate(let sides):
                for side in sides.sorted(by: { $0 == .host && $1 == .guest }) {
                    model.flipGate(side)
                    pair.setGate(model.gate[side]!, on: side)
                }
            case .linkDown:
                model.linkChanged(linked: false)
                pair.linkDown()
            case .linkUp:
                model.linkChanged(linked: true)
                pair.linkUp()
            case .deliver(let side):
                delivered = pair.wire?.queue(toward: side).first
                if let delivered { model.delivered(delivered, toward: side) }
                pair.wire?.deliverNext(toward: side)
            case .poll:
                model.dirty = [.host: false, .guest: false]
                pair.poll()
            }
            try await pair.settle()
            if case .request = action, let token = pair.wire?.requests.dropFirst(requests).last {
                model.hostRequest = token
            }
            return check(after: action, delivered: delivered, opened: opened)
        }

        /// What the rules say of the state `action` left, given how many offers each side had opened before it.
        private func check(after action: Action, delivered: ClipboardWire.Message?, opened: [Side: Int]) -> String? {
            for side in Side.allCases {
                for offer in pair.wire?.opened(side).dropFirst(opened[side] ?? 0) ?? [] {
                    if let violation = permits(offer, by: side, after: action, delivered: delivered) {
                        return violation
                    }
                    model.offers[offer.token] = Model.Offer(
                        side: side, name: ClipboardEndPair.name(of: offer.items), request: offer.request,
                        openedAt: model.resets[side] ?? 0)
                }
            }
            for side in Side.allCases {
                switch pair.holding(side) {
                case .user(let name) where name != model.name(side):
                    return "\(side)'s pasteboard holds \(name), not its user's last copy \(model.name(side))"
                case .data:
                    return "\(side)'s pasteboard holds written data, with no paste to have read any"
                case .write(let name):
                    guard model.mayHold(name, on: side) else {
                        return
                            "\(side)'s pasteboard holds a promised write of \(name), which no live offer it took serves"
                    }
                case .user, .nothing:
                    break
                }
            }
            guard let wire = pair.wire else { return nil }
            // A side's own withdrawal takes effect on its side at once, so what it offers is checked at every step.
            for side in Side.allCases {
                for (token, open) in wire.open(side) where !open.header.isOfferRequest {
                    guard let offer = model.offers[token] else { return "\(side) holds an offer the model never saw" }
                    guard offer.openedAt == model.resets[side] else {
                        return "\(side)'s offer of \(offer.name) outlived a reset of \(side)"
                    }
                    if model.dirty[side] != true, pair.holding(side) != .user(offer.name) {
                        return "\(side) still offers \(offer.name), which its pasteboard moved on from"
                    }
                }
            }
            guard Side.allCases.allSatisfy({ wire.queue(toward: $0).isEmpty }) else { return nil }
            return checkQuiescent(wire)
        }

        /// Whether `side` may have opened `offer` in the step `action` took.
        private func permits(
            _ offer: ItemOffer, by side: Side, after action: Action, delivered: ClipboardWire.Message?
        ) -> String? {
            let name = ClipboardEndPair.name(of: offer.items)
            let gate = model.gate[side]!
            guard pair.holding(side) == .user(name), name == model.name(side) else {
                return "\(side) offered \(name), which is not its user's copy on its pasteboard"
            }
            if !offer.request.isEmpty {
                guard side == .guest, case .opened(let header, _)? = delivered, header.isOfferRequest,
                    header.token == offer.request, gate == .onCommand
                else { return "\(side) answered a request no admitted trigger asked it to" }
                return nil
            }
            if side == .host, case .command = action {
                return gate == .onCommand ? nil : "the host offered at a command under \(gate)"
            }
            guard model.linked, gate == .everyCopy, (model.copies[side] ?? 0) > (model.baseline[side] ?? 0) else {
                return "\(side) offered \(name) at no copy its gate admits after its poll began"
            }
            return nil
        }

        /// With nothing in flight: every open offer is written on the far side, every write is of an open offer,
        /// and no request is left open.
        private func checkQuiescent(_ wire: ClipboardWire) -> String? {
            for side in Side.allCases {
                for (token, open) in wire.open(side) {
                    guard !open.header.isOfferRequest else {
                        return "the host's request is still open with nothing in flight to answer it"
                    }
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
            return nil
        }
    }

    /// The clipboard rules, over what each step did.
    struct Model {
        /// One offer opened on the connection now, as the rules see it.
        struct Offer {
            let side: Side
            let name: String
            let request: Data
            /// Its side's reset count when it opened.
            let openedAt: Int
            /// The far side's reset count when the offer reached it, and whether its gate took it then.
            var arrived: (at: Int, taken: Bool)?
            /// Its withdrawal reached the far side.
            var withdrawn = false
        }

        var linked = true
        var gate: [Side: ClipboardOfferGate]
        /// Each side's gate changes and link changes so far.
        var resets: [Side: Int] = [.host: 0, .guest: 0]
        /// How many copies each side's user made.
        var copies: [Side: Int] = [.host: 0, .guest: 0]
        /// The copy count when each side's poll began: a copy after it is one passthrough offers.
        var baseline: [Side: Int] = [.host: 0, .guest: 0]
        /// A side's user copied since its pasteboard's watch last ticked, so its end cannot know yet.
        var dirty: [Side: Bool] = [.host: false, .guest: false]
        /// The host's request a guest offer may answer, until one does or it ends.
        var hostRequest: Data?
        /// Every offer opened on the connection now, by token.
        var offers: [Data: Offer] = [:]

        init(_ start: Start) {
            gate = [.host: start.gate, .guest: start.gate]
            if start.copiedBefore {
                copies = [.host: 1, .guest: 1]
                baseline = copies
            }
        }

        /// The name of `side`'s user's latest copy.
        func name(_ side: Side) -> String { "\(side == .host ? "h" : "g")\(copies[side] ?? 0)" }

        mutating func flipGate(_ side: Side) {
            gate[side] = gate[side] == .everyCopy ? .onCommand : .everyCopy
            resets[side, default: 0] += 1
            baseline[side] = copies[side]
            if side == .host { hostRequest = nil }
        }

        mutating func linkChanged(linked: Bool) {
            self.linked = linked
            for side in Side.allCases {
                resets[side, default: 0] += 1
                baseline[side] = copies[side]
            }
            hostRequest = nil
            offers = [:]
        }

        /// `message` reaches `side`.
        mutating func delivered(_ message: ClipboardWire.Message, toward side: Side) {
            switch message {
            case .opened(let header, _) where header.isOfferRequest:
                break
            case .opened(let header, _):
                // A guest takes every host offer: the host offers on command only by its user's command. The host
                // takes an answer only to the request it has open, and any other offer only at every copy.
                let taken =
                    side == .guest
                    || (header.request.isEmpty ? gate[.host] == .everyCopy : header.request == hostRequest)
                if side == .host, taken, !header.request.isEmpty { hostRequest = nil }
                offers[header.token]?.arrived = (resets[side] ?? 0, taken)
            case .withdrawn(let token, _):
                offers[token]?.withdrawn = true
            case .released(let token), .refused(let token, _):
                if side == .host, token == hostRequest { hostRequest = nil }
            }
        }

        /// Whether `side` may hold a promised write of the far side's copy `name`: an offer of it reached `side`
        /// since `side` last reset, its gate took it, and no withdrawal of it has reached `side`.
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
