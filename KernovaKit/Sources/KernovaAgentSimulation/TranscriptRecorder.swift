#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// One scripted input of a transcript, in its `in` line's text form.
package enum TranscriptInput: Sendable, Equatable {
    case host(HostCommand)
    case peer(PeerInput)
    /// The peer's installer reports on the pull the peer has open. The runner
    /// addresses it to the stream of the UPDATE_PULL OPEN it saw, so a script
    /// never names a stream id the current side chooses.
    case pull(PullReport)
    /// The peer's logger emits `count` records into the ring.
    case peerLogs(Int)
    /// A side offers the fixture offer of this name as the feature's offer.
    case offer(SimSide, FeatureID, String)
    /// A side pulls from the far side's offer.
    case itemPull(SimSide, PullRequest)
    /// A side withdraws its offer of the token.
    case withdraw(SimSide, Data)
    /// A side releases the far side's offer of the token.
    case release(SimSide, Data)
    /// The host takes the peer's drag offer of the token.
    case takeDrag(Data)
    /// The host tells the peer this on the take it opened last.
    case controlTake(DragTakeControl)
    /// The host calls off the take it opened last.
    case cancelTake
    /// The peer answers the take it was asked about last. The runner addresses it to that take, so a
    /// script never names a stream id the current side chooses.
    case answerTake(DragTakeAnswer)
    /// The peer reports the first `TARGETED` on the take it was asked about last, listing the items of the
    /// fixture offer of this name.
    case targetTake(String)

    /// An installer's report on a pull.
    package enum PullReport: Sendable, Equatable {
        case installed
        case rejected(ErrorCode)

        func input(_ id: UpdatePullID) -> PeerInput {
            switch self {
            case .installed: .update(.installed(id))
            case .rejected(let code): .update(.rejected(id, WireError(code)))
            }
        }
    }

    static let generation = ConnectionGeneration(rawValue: 1)

    var side: SimSide {
        switch self {
        case .host, .takeDrag, .controlTake, .cancelTake: .host
        case .peer, .pull, .peerLogs, .answerTake, .targetTake: .peer
        case .offer(let side, _, _), .itemPull(let side, _), .withdraw(let side, _), .release(let side, _): side
        }
    }

    package var text: String {
        switch self {
        case .host(let command):
            switch command {
            case .requestPower(let id, let action):
                return "host requestPower id=\(id.rawValue) action=\(action.rawValue)"
            case .cancelPower(let id): return "host cancelPower id=\(id.rawValue)"
            case .close(let code, let retry):
                return "host close code=\(code.rawValue) retry=\(retry?.milliseconds ?? 0)"
            case .setBundles(let bundles):
                return "host setBundles fixture=\(bundles.isEmpty ? "none" : "stale-pax")"
            default: return "host unsupported"
            }
        case .peer(let input):
            switch input {
            case .power(let power):
                switch power {
                case .accepted(let id): return "peer power accepted id=\(id.rawValue)"
                case .refused(let id, let error):
                    return "peer power refused id=\(id.rawValue) code=\(error.code.rawValue)"
                case .cancelled(let id): return "peer power cancelled id=\(id.rawValue)"
                case .unconfirmed(let id): return "peer power unconfirmed id=\(id.rawValue)"
                case .askingApps(let id): return "peer power askingApps id=\(id.rawValue)"
                case .waitingOnApps(let id, let apps):
                    return "peer power waitingOnApps id=\(id.rawValue) apps=\(Self.names(apps))"
                case .handedOff(let id): return "peer power handedOff id=\(id.rawValue)"
                case .blocked(let id, let apps): return "peer power blocked id=\(id.rawValue) apps=\(Self.names(apps))"
                case .cancelledInGuest(let id): return "peer power cancelledInGuest id=\(id.rawValue)"
                case .failed(let id, let error):
                    return "peer power failed id=\(id.rawValue) code=\(error.code.rawValue)"
                case .availability(.absent(let reason, _)): return "peer power absent reason=\(reason.rawValue)"
                case .availability(.available(let offer)):
                    return "peer power offer actions=\(offer.actions.map { "\($0.rawValue)" }.joined(separator: ","))"
                }
            case .peerState(let state):
                return "peer state console=\(state.console.rawValue) session=\(state.sessionID) user=\(state.userName)"
            default: return "peer unsupported"
            }
        case .pull(.installed):
            return "peer update installed"
        case .pull(.rejected(let code)):
            return "peer update rejected code=\(code.rawValue)"
        case .peerLogs(let count):
            return "peer logs records=\(count)"
        case .offer(let side, let feature, let name):
            return "\(Self.name(side)) offer feature=\(feature.rawValue) fixture=\(name)"
        case .itemPull(let side, let request):
            return
                "\(Self.name(side)) pull token=\(FrozenFields.hex(request.token)) item=\(request.item) representation=\(request.representation) ceiling=\(request.byteCeiling)"
        case .withdraw(let side, let token):
            return "\(Self.name(side)) withdraw token=\(FrozenFields.hex(token))"
        case .release(let side, let token):
            return "\(Self.name(side)) release token=\(FrozenFields.hex(token))"
        case .takeDrag(let token):
            return "host take token=\(FrozenFields.hex(token))"
        case .controlTake(.catcher(let shown)):
            return "host takeControl catcher shown=\(shown ? 1 : 0)"
        case .controlTake(.deliver):
            return "host takeControl deliver"
        case .cancelTake:
            return "host takeCancel"
        case .answerTake(.report(.named(let names))):
            return "peer take named names=\(TranscriptEvents.list(names))"
        case .targetTake(let fixture):
            return "peer take targeted fixture=\(fixture)"
        case .answerTake(.report(let report)):
            return "peer take report \(TranscriptEvents.name(report))"
        case .answerTake(.caught(let folderSizes)):
            return "peer take caught" + (folderSizes.map { " folderSizes=\(TranscriptEvents.list($0))" } ?? "")
        case .answerTake(.returned):
            return "peer take returned"
        case .answerTake(.refused(let error)):
            return "peer take refused code=\(error.code.rawValue)"
        }
    }

    static func name(_ side: SimSide) -> String {
        side == .host ? "host" : "peer"
    }

    static func names(_ apps: [AppValue]) -> String {
        apps.map(\.displayName).joined(separator: ",")
    }

    /// Parses an `in` line's text.
    package init?(text: String) {
        let words = text.split(separator: " ")
        guard words.count >= 2 else { return nil }
        var fields: [String: String] = [:]
        for word in words.dropFirst(2) {
            let parts = word.split(separator: "=", maxSplits: 1)
            if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
        }
        func number(_ key: String) -> Int { fields[key].flatMap(Int.init) ?? 0 }
        func code(_ key: String) -> ErrorCode { ErrorCode(rawValue: number(key)) ?? .UNRECOGNIZED(number(key)) }
        let powerID = PowerRequestID(generation: Self.generation, rawValue: UInt64(number("id")))
        let apps = (fields["apps"] ?? "").split(separator: ",").map { AppValue(displayName: String($0)) }
        let token = fields["token"].flatMap { FrozenFields.unhex(Substring($0)) }
        switch (words[0], words[1]) {
        case ("host", "requestPower"):
            self = .host(.requestPower(powerID, PowerAction(rawValue: number("action")) ?? .unspecified))
        case ("host", "cancelPower"): self = .host(.cancelPower(powerID))
        case ("host", "close"):
            let retry = number("retry")
            self = .host(.close(code("code"), retryAfter: retry > 0 ? .milliseconds(Int64(retry)) : nil))
        case ("host", "setBundles"):
            guard let bundles = TranscriptFixture.bundles(fields["fixture"] ?? "") else { return nil }
            self = .host(.setBundles(bundles))
        case ("peer", "power"):
            guard words.count >= 3 else { return nil }
            let input: PowerInput
            switch words[2] {
            case "accepted": input = .accepted(powerID)
            case "refused": input = .refused(powerID, WireError(code("code")))
            case "cancelled": input = .cancelled(powerID)
            case "unconfirmed": input = .unconfirmed(powerID)
            case "askingApps": input = .askingApps(powerID)
            case "waitingOnApps": input = .waitingOnApps(powerID, apps)
            case "handedOff": input = .handedOff(powerID)
            case "blocked": input = .blocked(powerID, apps)
            case "cancelledInGuest": input = .cancelledInGuest(powerID)
            case "failed": input = .failed(powerID, WireError(code("code")))
            case "absent":
                input = .availability(
                    .absent(AbsenceReason(rawValue: number("reason")) ?? .unspecified, debugDetail: ""))
            case "offer":
                let actions = (fields["actions"] ?? "").split(separator: ",").compactMap {
                    Int($0).flatMap(PowerAction.init(rawValue:))
                }
                input = .availability(.available(PowerOffer(actions: actions, asksAppsToQuit: true)))
            default: return nil
            }
            self = .peer(.power(input))
        case ("peer", "update"):
            guard words.count >= 3 else { return nil }
            switch words[2] {
            case "installed": self = .pull(.installed)
            case "rejected": self = .pull(.rejected(code("code")))
            default: return nil
            }
        case ("peer", "state"):
            self = .peer(
                .peerState(
                    PeerSessionState(
                        console: ConsoleState(rawValue: number("console")) ?? .unknown,
                        sessionID: fields["session"] ?? "",
                        userName: fields["user"] ?? "")))
        case ("peer", "logs"):
            self = .peerLogs(number("records"))
        case ("peer", "take"):
            guard words.count >= 3 else { return nil }
            switch words[2] {
            case "report":
                guard words.count >= 4, let report = TranscriptEvents.report(named: String(words[3])) else {
                    return nil
                }
                self = .answerTake(.report(report))
            case "targeted":
                guard let name = fields["fixture"], TranscriptFixture.offer(name) != nil else { return nil }
                self = .targetTake(name)
            case "named":
                guard let names = fields["names"].flatMap(TranscriptEvents.names) else { return nil }
                self = .answerTake(.report(.named(names)))
            case "caught":
                self = .answerTake(.caught(folderSizes: fields["folderSizes"].flatMap(TranscriptEvents.sizes)))
            case "returned": self = .answerTake(.returned)
            case "refused": self = .answerTake(.refused(WireError(code("code"))))
            default: return nil
            }
        case ("host", "take"):
            guard let token else { return nil }
            self = .takeDrag(token)
        case ("host", "takeControl"):
            guard words.count >= 3 else { return nil }
            switch words[2] {
            case "catcher": self = .controlTake(.catcher(shown: number("shown") != 0))
            case "deliver": self = .controlTake(.deliver)
            default: return nil
            }
        case ("host", "takeCancel"):
            self = .cancelTake
        case (let side, let verb) where side == "host" || side == "peer":
            let side: SimSide = side == "host" ? .host : .peer
            switch verb {
            case "offer":
                guard let name = fields["fixture"], TranscriptFixture.offer(name) != nil,
                    let feature = FeatureID(rawValue: number("feature"))
                else { return nil }
                self = .offer(side, feature, name)
            case "pull":
                guard let token else { return nil }
                var request = PullRequest()
                request.token = token
                request.item = UInt32(number("item"))
                request.representation = UInt32(number("representation"))
                request.byteCeiling = UInt64(number("ceiling"))
                self = .itemPull(side, request)
            case "withdraw":
                guard let token else { return nil }
                self = .withdraw(side, token)
            case "release":
                guard let token else { return nil }
                self = .release(side, token)
            default:
                return nil
            }
        default:
            return nil
        }
    }
}

/// One frozen or current exchange.
package struct Exchange: Sendable {
    package var id: String
    package var title: String
    package var hostFixture: String
    package var peerFixture: String
    package var script: [(time: UInt64, input: TranscriptInput)]
    package var end: UInt64
    /// The side whose Hello gains an unknown feature, followed by an `extension` and an unknown session case (F11).
    package var extrasFrom: SimSide?
    /// Which sides get a frozen transcript; F12 and F13 only the host.
    package var pinnable: [SimSide] = [.host, .peer]

    static func power(_ action: PowerAction) -> TranscriptInput {
        .host(.requestPower(PowerRequestID(generation: TranscriptInput.generation, rawValue: 1), action))
    }

    static func peerPower(_ make: (PowerRequestID) -> PowerInput) -> TranscriptInput {
        .peer(.power(make(PowerRequestID(generation: TranscriptInput.generation, rawValue: 2))))
    }

    static let f05Script: [(time: UInt64, input: TranscriptInput)] = [
        (1000, power(.shutdown)), (1250, peerPower { .accepted($0) }), (1400, peerPower { .askingApps($0) }),
        (1600, peerPower { .handedOff($0) }),
    ]

    package static let frozen: [Exchange] = [
        Exchange(
            id: "F01", title: "handshake: host + Linux session peer, PolicyUpdate, UpdateAvailable (none offered)",
            hostFixture: "host-default", peerFixture: "linux-session-v1", script: [], end: 2000),
        Exchange(
            id: "F02", title: "handshake: host + macOS system peer, UpdateAvailable with a PAX_TREE manifest",
            hostFixture: "host-pax-system", peerFixture: "macos-system-v1", script: [], end: 2000),
        Exchange(
            id: "F03",
            title: "handshake with a PeerState change and a CapabilityUpdate withdrawing POWER (NOT_ON_CONSOLE)",
            hostFixture: "host-default", peerFixture: "linux-session-v1",
            script: [
                (500, .peer(.peerState(PeerSessionState(console: .off, sessionID: "c2", userName: "ada")))),
                (500, .peer(.power(.availability(.absent(.notOnConsole, debugDetail: ""))))),
            ], end: 2000),
        Exchange(
            id: "F04", title: "PINGs at least every 5 s over 20 s of idle", hostFixture: "host-default",
            peerFixture: "linux-session-v1", script: [], end: 20_000),
        Exchange(
            id: "F05", title: "power: shutdown accepted → asking apps → handed off", hostFixture: "host-default",
            peerFixture: "linux-session-v1", script: f05Script, end: 2500),
        Exchange(
            id: "F06", title: "power: restart refused POWER_NOT_ON_CONSOLE", hostFixture: "host-default",
            peerFixture: "linux-session-v1",
            script: [(1000, power(.restart)), (1100, peerPower { .refused($0, WireError(.powerNotOnConsole)) })],
            end: 2000),
        Exchange(
            id: "F07", title: "power: accepted → waiting on apps → blocked, two apps", hostFixture: "host-default",
            peerFixture: "linux-session-v1",
            script: [
                (1000, power(.shutdown)), (1200, peerPower { .accepted($0) }),
                (
                    1400,
                    peerPower { .waitingOnApps($0, [AppValue(displayName: "Editor"), AppValue(displayName: "Mail")]) }
                ),
                (1800, peerPower { .blocked($0, [AppValue(displayName: "Editor"), AppValue(displayName: "Mail")]) }),
            ], end: 2500),
        Exchange(
            id: "F08", title: "power: peer deadline → confirmed cancel → refused TIMEOUT", hostFixture: "host-default",
            peerFixture: "linux-session-v1",
            script: [(1000, power(.shutdown)), (12_500, peerPower { .cancelled($0) })], end: 14_000),
        Exchange(
            id: "F09", title: "update pull, 2.5 MiB EXECUTABLE payload → STAGED", hostFixture: "host-exec-2.5m",
            peerFixture: "linux-session-v1",
            script: [(1000, .pull(.installed))], end: 1500),
        Exchange(
            id: "F10", title: "update pull of a stale hash → RESET UPDATE_STALE", hostFixture: "host-stale",
            peerFixture: "linux-session-v1",
            script: [(2, .host(.setBundles(TranscriptFixture.bundles("stale-pax") ?? [])))], end: 1000),
        Exchange(
            id: "F11",
            title:
                "protocol mismatch: protocol_version 2, an unknown FeatureId, an extension, an unknown SessionMessage case; LOGS absent; F05 still completes",
            hostFixture: "host-default", peerFixture: "linux-session-proto2", script: f05Script, end: 2500,
            extrasFrom: .peer, pinnable: [.peer]),
        Exchange(
            id: "F11", title: "protocol mismatch, host at protocol_version 2: the frozen subset still completes F05",
            hostFixture: "host-proto2", peerFixture: "linux-session-v1", script: f05Script, end: 2500,
            extrasFrom: .host, pinnable: [.host]),
        Exchange(
            id: "F12", title: "identity conflict → RESET(0) DUPLICATE_PEER with retry_after_ms",
            hostFixture: "host-default",
            peerFixture: "linux-session-v1",
            script: [(5, .host(.close(.duplicatePeer, retryAfter: .milliseconds(20_000))))],
            end: 1000, pinnable: [.host]),
        Exchange(
            id: "F13", title: "identity conflict → RESET(0) SUPERSEDED", hostFixture: "host-default",
            peerFixture: "linux-session-v1", script: [(5, .host(.close(.superseded, retryAfter: nil)))], end: 1000,
            pinnable: [.host]),
    ]

    /// Non-frozen exchanges, replayed duet and changed with their feature.
    package static let current: [Exchange] = [
        Exchange(
            id: "C01", title: "logs: forwarding two bursts of records", hostFixture: "host-default",
            peerFixture: "linux-session-v1", script: [(500, .peerLogs(3)), (900, .peerLogs(70))], end: 1500),
        Exchange(
            id: "C02", title: "clipboard: the host pulls the FILE of a peer's clipboard offer → LANDED",
            hostFixture: "host-items", peerFixture: "linux-session-items",
            script: [
                (500, .offer(.peer, .clipboard, "file-2k")),
                (600, .itemPull(.host, SimItems.request(1, ceiling: 1 << 20))),
            ], end: 1000),
        Exchange(
            id: "C03",
            title:
                "clipboard: the peer's second offer withdraws its first; the host pulls the second's INLINE and releases it",
            hostFixture: "host-items", peerFixture: "linux-session-items",
            script: [
                (500, .offer(.peer, .clipboard, "file-2k")), (600, .offer(.peer, .clipboard, "text-64")),
                (700, .itemPull(.host, SimItems.request(2, ceiling: 1 << 20))),
                (800, .release(.host, SimItems.token(2))),
            ], end: 1000),
        Exchange(
            id: "C04", title: "drop: the peer pulls the FOLDER of the host's drop offer → LANDED, then releases it",
            hostFixture: "host-items", peerFixture: "linux-session-items",
            script: [
                (500, .offer(.host, .drop, "folder-4k")),
                (600, .itemPull(.peer, SimItems.request(3, ceiling: 1 << 20))),
                (700, .release(.peer, SimItems.token(3))),
            ], end: 1000),
        Exchange(
            id: "C05",
            title:
                "drag: the host takes the peer's drag → ARMED, TARGETED, then CAUGHT; it pulls the FILE → LANDED and releases it",
            hostFixture: "host-items", peerFixture: "linux-session-items",
            script: [
                (500, .offer(.peer, .drag, "drag-1")), (600, .takeDrag(SimItems.token(1))),
                (620, .answerTake(.report(.armed))), (630, .targetTake("file-2k")),
                (650, .answerTake(.caught(folderSizes: nil))),
                (700, .itemPull(.host, SimItems.request(1, ceiling: 1 << 20))),
                (800, .release(.host, SimItems.token(1))),
            ], end: 1000),
        Exchange(
            id: "C06", title: "drag: the peer refuses a take DRAG_PRESS_OVER, then withdraws its drag",
            hostFixture: "host-items", peerFixture: "linux-session-items",
            script: [
                (500, .offer(.peer, .drag, "drag-1")), (600, .takeDrag(SimItems.token(1))),
                (650, .answerTake(.refused(WireError(.dragPressOver)))), (700, .withdraw(.peer, SimItems.token(1))),
            ], end: 1000),
        Exchange(
            id: "C07",
            title:
                "drag: the catcher stands down → STOOD_DOWN and shows again; a delivering drop names the promise, ENDs CAUGHT sizing the folder, and the host pulls the promise from the taken offer",
            hostFixture: "host-items", peerFixture: "linux-session-items",
            script: [
                (500, .offer(.peer, .drag, "drag-4")), (600, .takeDrag(SimItems.token(4))),
                (620, .answerTake(.report(.armed))), (630, .targetTake("promise-folder")),
                (650, .controlTake(.catcher(shown: false))), (660, .answerTake(.report(.stoodDown))),
                (700, .controlTake(.catcher(shown: true))),
                (720, .answerTake(.report(.armed))), (730, .answerTake(.report(.targeted([])))),
                (750, .controlTake(.deliver)), (760, .answerTake(.report(.delivering))),
                (800, .answerTake(.report(.named([Data("IMG_0042.jpeg".utf8)])))),
                (810, .answerTake(.caught(folderSizes: [8192]))),
                (850, .itemPull(.host, SimItems.request(4, ceiling: 1 << 20))),
                (950, .release(.host, SimItems.token(4))),
            ], end: 1100),
        Exchange(
            id: "C08", title: "drag: the host calls a take off after ARMED, and the peer's drag stays offered",
            hostFixture: "host-items", peerFixture: "linux-session-items",
            script: [
                (500, .offer(.peer, .drag, "drag-1")), (600, .takeDrag(SimItems.token(1))),
                (620, .answerTake(.report(.armed))), (650, .cancelTake), (700, .withdraw(.peer, SimItems.token(1))),
            ], end: 1000),
    ]
}

/// One recorded item of a duet, from which both pinned views are rendered.
package enum DuetItem: Sendable {
    case wire(time: UInt64, from: SimSide, line: String, describe: FrozenLine?)
    case dataTotal(time: UInt64, from: SimSide, stream: UInt32, bytes: Int, checksum: UInt32)
    case input(time: UInt64, TranscriptInput)
    case event(time: UInt64, side: SimSide, text: String)
}

/// Runs an exchange with both sides real, one millisecond per hop, recording everything.
package final class Duet {
    let exchange: Exchange
    package private(set) var host: HostEndpoint
    package private(set) var peer: PeerEndpoint
    package private(set) var items: [DuetItem] = []
    /// Harness misuse the run met: a scripted input the current side faulted on, or one with nothing to address.
    package private(set) var failures: [String] = []
    private var localFaults: [String] = []
    private var now: UInt64 = 0
    private var inflight: [(arrive: UInt64, to: SimSide, bytes: Data)] = []
    private var decoders: [SimSide: FrameDecoder] = [.host: FrameDecoder(), .peer: FrameDecoder()]
    private var preambleSeen: Set<SimSide> = []
    private var kinds: [UInt32: StreamKind] = [:]
    private var rawTotals: [UInt32: (bytes: Int, crc: CRC32C)] = [:]
    private var rawOffsets: [UInt32: Int] = [:]
    private var ring = LogRing()
    private var extrasPending = false
    private var source = FixturePayloadSource()
    private var itemSource = ContainerItemSource()
    private var itemSink = DecodingItemSink()
    /// The take the peer was asked about last, which `.answerTake` answers.
    private var lastTake: DragTakeID?
    /// The take the host opened last, which `.controlTake` and `.cancelTake` address.
    private var lastOpenedTake: DragTakeID?
    /// The item commands sent and not yet answered, each with the step's text.
    private var asked: [ItemRequestID: String] = [:]
    /// The item the last `.read` answered.
    private var read: OfferedItem?
    private var nextRequest: UInt64 = 0
    private lazy var bundleContent: Data? = TranscriptFixture.host(exchange.hostFixture)?.bundles.first.map {
        SimHub.expectedContent($0.manifest)
    }

    static let base: UInt64 = 1_000_000_000

    package init?(_ exchange: Exchange) {
        guard let hostConfiguration = TranscriptFixture.host(exchange.hostFixture),
            let peerConfiguration = TranscriptFixture.peer(exchange.peerFixture)
        else { return nil }
        self.exchange = exchange
        let start = CoreInstant(nanoseconds: Self.base)
        host = HostEndpoint(hostConfiguration, generation: TranscriptInput.generation, now: start)
        peer = PeerEndpoint(peerConfiguration, generation: TranscriptInput.generation, now: start)
        extrasPending = exchange.extrasFrom != nil
    }

    var instant: CoreInstant { CoreInstant(nanoseconds: Self.base + now * 1_000_000) }

    package func run() {
        var script = exchange.script[...]
        drainAll()
        while true {
            let deadlines = [host.nextDeadline, peer.nextDeadline].compactMap { $0 }
                .map { ($0.nanoseconds - min($0.nanoseconds, Self.base) + 999_999) / 1_000_000 }
            let candidates = inflight.map(\.arrive) + (script.first.map { [$0.time] } ?? []) + deadlines
            guard let next = candidates.min(), next <= exchange.end else { break }
            now = max(now, next)
            while let index = inflight.firstIndex(where: { $0.arrive <= now }) {
                let delivery = inflight.remove(at: index)
                switch delivery.to {
                case .host: host.receive(delivery.bytes, now: instant)
                case .peer: peer.receive(delivery.bytes, now: instant)
                }
                drainAll()
            }
            while let step = script.first, step.time <= now {
                script = script.dropFirst()
                apply(step.input)
            }
            if let deadline = host.nextDeadline, deadline <= instant {
                host.handleTimeout(now: instant)
                drainAll()
            }
            if let deadline = peer.nextDeadline, deadline <= instant {
                peer.handleTimeout(now: instant)
                drainAll()
            }
        }
    }

    private func apply(_ input: TranscriptInput) {
        items.append(.input(time: now, input))
        let faultsBefore = localFaults.count
        defer {
            for fault in localFaults[faultsBefore...] {
                failures.append("t=\(now): `\(input.text)` raised a local fault: \(fault)")
            }
        }
        switch input {
        case .host(let command): host.handle(command, now: instant)
        case .peer(let input): peer.handle(input, now: instant)
        case .pull(let report):
            guard let stream = kinds.filter({ $0.value == .updatePull && $0.key % 2 == 1 }).keys.max() else {
                failures.append("t=\(now): `\(input.text)` with no UPDATE_PULL opened")
                return
            }
            peer.handle(
                report.input(UpdatePullID(generation: TranscriptInput.generation, stream: StreamID(rawValue: stream))),
                now: instant)
        case .peerLogs(let count):
            var post = false
            for number in 0..<count {
                let record = LogRecordValue(
                    timestampMilliseconds: 1_700_000_000_000 + Int64(now), level: .info, subsystem: "app.kernova.agent",
                    category: "transcript",
                    segments: [LogSegmentValue(text: "record "), LogSegmentValue(text: "\(number)", isPrivate: true)])
                if ring.append(record) { post = true }
            }
            if post { peer.handle(.logs(.recordsAvailable), now: instant) }
        case .offer(let side, let feature, let name):
            guard let offer = TranscriptFixture.offer(name) else { break }
            item(side, ask(input) { .offer($0, offer, feature: feature) })
        case .itemPull(let side, let request):
            // The landing takes the storage of the representation the pull names, so the item is read first.
            read = nil
            item(side, ask(input) { .read($0, token: request.token, item: request.item) })
            drainAll()
            let storage = read?.representations.dropFirst(Int(request.representation)).first?.storage ?? .file
            let order = ItemPullOrder(request, landing: DecodingItemSink.landing(storage))
            item(side, ask(input) { .pull($0, order) })
        case .withdraw(let side, let token): item(side, .withdraw(token: token))
        case .release(let side, let token): item(side, .release(token: token))
        case .takeDrag(let token):
            item(.host, ask(input) { .takeDrag($0, token: token) })
        case .controlTake(let control):
            guard let lastOpenedTake else {
                failures.append("t=\(now): `\(input.text)` with no take opened")
                break
            }
            item(.host, .controlTake(lastOpenedTake, control))
        case .cancelTake:
            guard let lastOpenedTake else {
                failures.append("t=\(now): `\(input.text)` with no take opened")
                break
            }
            item(.host, .cancelTake(lastOpenedTake))
        case .answerTake(let answer):
            guard let lastTake else {
                failures.append("t=\(now): `\(input.text)` with no take asked")
                break
            }
            peer.handle(.dragTake(lastTake, answer), now: instant)
        case .targetTake(let fixture):
            guard let lastTake, let offer = TranscriptFixture.offer(fixture) else {
                failures.append("t=\(now): `\(input.text)` with no take asked")
                break
            }
            peer.handle(.dragTake(lastTake, .report(.targeted(offer.items))), now: instant)
        }
        drainAll()
    }

    /// The command `build` makes around a fresh request id, whose refusal fails `input`.
    private func ask(_ input: TranscriptInput, _ build: (ItemRequestID) -> ItemCommand) -> ItemCommand {
        nextRequest += 1
        let id = ItemRequestID(rawValue: nextRequest)
        asked[id] = input.text
        return build(id)
    }

    private func item(_ side: SimSide, _ command: ItemCommand) {
        switch side {
        case .host: host.handle(.items(command), now: instant)
        case .peer: peer.handle(.itemCommand(command), now: instant)
        }
    }

    /// Fails the step whose command `reply` refused.
    private func answered(_ id: ItemRequestID, _ reply: ItemReply) {
        guard let text = asked.removeValue(forKey: id) else {
            return failures.append("t=\(now): an answer to no step")
        }
        let refusal: WireError? =
            switch reply {
            case .offered(let refusal): refusal
            case .pulled(.failure(let error)), .took(.failure(let error)): error
            case .pulled, .took, .read: nil
            }
        if case .read(let item) = reply { read = item }
        if case .took(.success(let id)) = reply { lastOpenedTake = id }
        if let refusal { failures.append("t=\(now): `\(text)` refused: \(refusal)") }
    }

    private func drainAll() {
        var progressed = true
        while progressed {
            progressed = false
            // Effects before events: a pull's `.commit` or `.abort` before its `.pullEnded`, as the machine emits them.
            while let effect = host.pollEffect() {
                progressed = true
                switch effect {
                case .read(let id, let manifest, let offset, let maxBytes):
                    host.handle(source.answer(id, manifest, offset: offset, maxBytes: maxBytes), now: instant)
                case .itemSource(let effect):
                    if let input = itemSource.handle(effect) { host.handle(.source(input), now: instant) }
                case .itemSink(let effect):
                    if let input = itemSink.handle(effect) { host.handle(.sink(input), now: instant) }
                }
            }
            while let event = host.pollEvent() {
                progressed = true
                if case .diagnostic(.localFault(let text)) = event { localFaults.append("host: \(text)") }
                if case .itemReply(let id, let reply) = event { answered(id, reply) }
                if let text = TranscriptEvents.describe(event) {
                    items.append(.event(time: now, side: .host, text: text))
                }
            }
            while let effect = peer.pollEffect() {
                progressed = true
                if let text = TranscriptEvents.describe(effect) {
                    items.append(.event(time: now, side: .peer, text: text))
                }
                switch effect {
                case .update(.payload(let id, let bytes)):
                    peer.handle(.update(.consumed(id, bytes.count)), now: instant)
                case .logs(.mode(let mode)): ring.setMode(mode)
                case .logs(.ready):
                    if let batch = ring.takeBatch() { peer.handle(.logs(.batch(batch)), now: instant) }
                case .itemSource(let effect):
                    if let input = itemSource.handle(effect) { peer.handle(.items(.source(input)), now: instant) }
                case .itemSink(let effect):
                    if let input = itemSink.handle(effect) { peer.handle(.items(.sink(input)), now: instant) }
                default: break
                }
            }
            while let event = peer.pollEvent() {
                progressed = true
                if case .diagnostic(.localFault(let text)) = event { localFaults.append("peer: \(text)") }
                if case .dragTake(.requested(let id, _)) = event { lastTake = id }
                if case .itemReply(let id, let reply) = event { answered(id, reply) }
                if let text = TranscriptEvents.describe(event) {
                    items.append(.event(time: now, side: .peer, text: text))
                }
            }
            while let transmit = host.pollTransmit(maxBytes: 1 << 20 + 10) {
                progressed = true
                write(transmit, from: .host)
                if transmit.isFinal { host.finalTransmitWritten(now: instant) }
            }
            while let transmit = peer.pollTransmit(maxBytes: 1 << 20 + 10) {
                progressed = true
                write(transmit, from: .peer)
                if transmit.isFinal { peer.finalTransmitWritten(now: instant) }
            }
        }
        _ = host.takeTrace()
        _ = peer.takeTrace()
    }

    private func write(_ transmit: Transmit, from side: SimSide) {
        var bytes = Data()
        for chunk in transmit.chunks { bytes.append(chunk) }
        var out = Data()
        if !preambleSeen.contains(side) {
            preambleSeen.insert(side)
            items.append(
                .wire(time: now, from: side, line: FrozenFields.hex(bytes.prefix(4)), describe: FrozenLine("preamble")))
            out.append(WireConstants.preamble)
        }
        var frames: [Frame] = []
        decoders[side]?.append(bytes)
        while let frame = try? decoders[side]?.nextFrame() { frames.append(frame) }
        for var frame in frames {
            if extrasPending, side == exchange.extrasFrom, frame.streamID == .session, frame.type == .data {
                frame = Self.withUnknownFeature(frame)
                extrasPending = false
                record(frame, from: side, into: &out)
                for extra in Self.extras { record(extra, from: side, into: &out) }
                continue
            }
            record(frame, from: side, into: &out)
        }
        inflight.append((now + 1, side == .host ? .peer : .host, out))
    }

    private func record(_ frame: Frame, from side: SimSide, into out: inout Data) {
        for part in FrameEncoder.encode(frame) { out.append(part) }
        let id = frame.streamID.rawValue
        if frame.type == .open, let open = try? Kernova_V2_Open(serializedBytes: frame.payload) {
            kinds[id] = open.kind
        }
        if frame.type == .data, !frame.flags.contains(.message) {
            var total = rawTotals[id] ?? (0, CRC32C())
            total.bytes += frame.payload.count
            total.crc.update(frame.payload)
            rawTotals[id] = total
        }
        if frame.type == .end, let total = rawTotals[id] {
            items.append(.dataTotal(time: now, from: side, stream: id, bytes: total.bytes, checksum: total.crc.value))
            rawTotals[id] = nil
        }
        items.append(
            .wire(time: now, from: side, line: line(frame), describe: FrozenFields.describe(frame, kinds: kinds)))
    }

    /// A frame's line: header fields spaced, then the payload in hex, or a
    /// generated-payload reference for update DATA.
    private func line(_ frame: Frame) -> String {
        let id = frame.streamID.rawValue
        let header = Self.headerText(frame)
        if frame.type == .data, !frame.flags.contains(.message), kinds[id] == .updatePull,
            let bundle = TranscriptFixture.host(exchange.hostFixture)?.bundles.first
        {
            let content = bundleContent ?? Data()
            let offset = rawOffsets[id] ?? 0
            let end = offset + frame.payload.count
            if end <= content.count, content[offset..<end] == frame.payload {
                rawOffsets[id] = end
                return
                    "\(header) @gen(seed=\(FNV64.of(bundle.manifest.payloadHash)),size=\(content.count),offset=\(offset),count=\(frame.payload.count))"
            }
        }
        return frame.payload.isEmpty ? header : "\(header) \(FrozenFields.hex(frame.payload))"
    }

    static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }

    /// `ssssssss tt ff llllllll`: the header's fields in hex.
    static func headerText(_ frame: Frame) -> String {
        let length = UInt32(frame.payload.count)
        return FrozenFields.hex(bigEndian(frame.streamID.rawValue)) + " "
            + FrozenFields.hex(Data([frame.type.rawValue])) + " "
            + FrozenFields.hex(Data([frame.flags.rawValue])) + " " + FrozenFields.hex(bigEndian(length))
    }

    static func withUnknownFeature(_ frame: Frame) -> Frame {
        guard var message = try? Kernova_V2_SessionMessage(serializedBytes: frame.payload),
            case .hello(var hello) = message.message
        else { return frame }
        var unknown = Kernova_V2_FeatureAdvert()
        unknown.feature = .UNRECOGNIZED(9)
        unknown.version = 1
        unknown.params = Data([1, 2, 3])
        hello.features.append(unknown)
        message.hello = hello
        return Frame(
            streamID: .session, type: .data, flags: .message, payload: (try? message.serializedBytes()) ?? Data())
    }

    /// An `extension`, then a SessionMessage carrying only an unknown field (a case added later).
    static let extras: [Frame] = {
        var withExtension = Kernova_V2_SessionMessage()
        withExtension.extension = Data([0x08, 0x01])
        let unknownCase = Data([0x6A, 0x02, 0x08, 0x01])  // field 13, length-delimited
        return [
            Frame(
                streamID: .session, type: .data, flags: .message,
                payload: (try? withExtension.serializedBytes()) ?? Data()),
            Frame(streamID: .session, type: .data, flags: .message, payload: unknownCase),
        ]
    }()

    // MARK: Rendering

    /// The frozen transcript with `pinned`'s bytes.
    package func render(pinned: SimSide, fileID: String) -> String {
        let current: SimSide = pinned == .host ? .peer : .host
        let pinnedArrow = pinned == .host ? "h>p" : "p>h"
        let currentArrow = pinned == .host ? "p>h" : "h>p"
        var lines = [
            "# \(fileID) \(exchange.title) — \(pinned == .host ? "host" : "peer") pinned",
            "pinned \(pinned == .host ? "host" : "peer")  fixture=\(pinned == .host ? exchange.hostFixture : exchange.peerFixture)",
            "current \(current == .host ? "host" : "peer") fixture=\(current == .host ? exchange.hostFixture : exchange.peerFixture)\(current == .host ? " token=\(FrozenFields.hex(TranscriptFixture.token))" : "")",
            "end \(exchange.end)",
        ]
        for item in items {
            switch item {
            case .wire(let time, let from, let line, let describe):
                if from == pinned {
                    lines.append(Self.row(time, pinnedArrow, line))
                } else if let describe {
                    lines.append(Self.row(time, "expect", "\(currentArrow) \(describe.text)"))
                }
            case .dataTotal(let time, let from, let stream, let bytes, let checksum):
                if from == current {
                    lines.append(
                        Self.row(
                            time, "expect",
                            "\(currentArrow) s=\(stream) DATA-TOTAL bytes=\(bytes) crc32c=\(FrozenFields.hex(Self.bigEndian(checksum)))"
                        ))
                }
            case .input(let time, let input):
                if input.side == current { lines.append(Self.row(time, "in", input.text)) }
            case .event(let time, let side, let text):
                if side == current { lines.append(Self.row(time, "ev", text)) }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The duet transcript: both sides' bytes and every input.
    package func renderDuet() -> String {
        var lines = [
            "# \(exchange.id) \(exchange.title) — duet",
            "host fixture=\(exchange.hostFixture)",
            "peer fixture=\(exchange.peerFixture)",
            "end \(exchange.end)",
        ]
        for item in items {
            switch item {
            case .wire(let time, let from, let line, _):
                lines.append(Self.row(time, from == .host ? "h>p" : "p>h", line))
            case .input(let time, let input): lines.append(Self.row(time, "in", input.text))
            case .event(let time, let side, let text):
                lines.append(Self.row(time, "ev", "\(side == .host ? "" : "")\(text)"))
            case .dataTotal: break
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func row(_ time: UInt64, _ tag: String, _ rest: String) -> String {
        let stamp = "t=\(time)"
        return stamp.padding(toLength: max(9, stamp.count + 1), withPad: " ", startingAt: 0)
            + tag.padding(toLength: 8, withPad: " ", startingAt: 0) + rest
    }
}

/// The text of the events a transcript's `ev` lines name.
package enum TranscriptEvents {
    package static func describe(_ event: HostEvent) -> String? {
        switch event {
        case .power(let id, let result): "host power id=\(id.rawValue) \(describe(result))"
        case .update(.result(_, let result)):
            "host update result kind=\(result.kind == .staged ? 1 : 2) code=\(result.error?.code.rawValue ?? 0)"
        case .update(.closed(_, let closure)): "host update closed \(describe(closure))"
        case .closed(let closure): "host closed \(describe(closure))"
        case .items(let event): describe(event, side: .host)
        case .dragTake(let event): describe(event, side: .host)
        default: nil
        }
    }

    package static func describe(_ effect: PeerEffect) -> String? {
        switch effect {
        case .power(.perform(let id, let action)): "peer power perform id=\(id.rawValue) action=\(action.rawValue)"
        case .power(.cancel(let id)): "peer power cancel id=\(id.rawValue)"
        case .update(.complete(let id, let manifest)):
            "peer update complete id=\(id.stream.rawValue) size=\(manifest.payloadSize)"
        case .update(.recordRejected(let hash)): "peer update recordRejected hash=\(FrozenFields.hex(hash))"
        case .update(.abort(let id)): "peer update abort id=\(id.stream.rawValue)"
        default: nil
        }
    }

    package static func describe(_ event: ItemTransferEvent, side: SimSide) -> String {
        let prefix = side == .host ? "host item" : "peer item"
        return switch event {
        case .offerReceived(let header):
            "\(prefix) offerReceived feature=\(header.feature.rawValue) token=\(FrozenFields.hex(header.token)) items=\(header.count)"
        case .offerEnded(let feature, let origin, let token, let closure):
            "\(prefix) offerEnded feature=\(feature.rawValue) \(origin == .local ? "local" : "remote") token=\(FrozenFields.hex(token)) \(describe(closure))"
        case .pullEnded(let feature, let id, let result):
            "\(prefix) pullEnded feature=\(feature.rawValue) id=\(id.stream.rawValue) \(describe(result))"
        case .serveEnded(let feature, let id, let result):
            "\(prefix) serveEnded feature=\(feature.rawValue) id=\(id.stream.rawValue) \(describe(result))"
        }
    }

    package static func describe(_ event: DragTakeEvent, side: SimSide) -> String {
        let prefix = side == .host ? "host drag" : "peer drag"
        return switch event {
        case .requested(let id, let token):
            "\(prefix) takeRequested id=\(id.stream.rawValue) token=\(FrozenFields.hex(token))"
        case .control(let id, .catcher(let shown)):
            "\(prefix) takeControl id=\(id.stream.rawValue) catcher shown=\(shown ? 1 : 0)"
        case .control(let id, .deliver): "\(prefix) takeControl id=\(id.stream.rawValue) deliver"
        case .cancelled(let id): "\(prefix) takeCancelled id=\(id.stream.rawValue)"
        case .report(let id, .targeted(let items)):
            "\(prefix) takeReport id=\(id.stream.rawValue) targeted items=\(items.count)"
        case .report(let id, .named(let names)):
            "\(prefix) takeReport id=\(id.stream.rawValue) named names=\(list(names))"
        case .report(let id, let report): "\(prefix) takeReport id=\(id.stream.rawValue) \(name(report))"
        case .ended(let id, .caught(let delivery)):
            "\(prefix) takeEnded id=\(id.stream.rawValue) caught"
                + (delivery.map { delivery in
                    " names=\(list(delivery.names.sorted { $0.key < $1.key }.map(\.value)))"
                        + " folderSizes=\(list(delivery.folderSizes.sorted { $0.key < $1.key }.map(\.value)))"
                } ?? "")
        case .ended(let id, .returned): "\(prefix) takeEnded id=\(id.stream.rawValue) returned"
        case .ended(let id, .refused(let error)):
            "\(prefix) takeEnded id=\(id.stream.rawValue) refused code=\(error.code.rawValue)"
        case .ended(let id, .closed(let closure)):
            "\(prefix) takeEnded id=\(id.stream.rawValue) closed \(describe(closure))"
        }
    }

    /// How a transcript names a take's step.
    static func name(_ report: DragTakeReport) -> String {
        switch report {
        case .armed: "armed"
        case .targeted: "targeted"
        case .delivering: "delivering"
        case .deliverRefused: "deliverRefused"
        case .stoodDown: "stoodDown"
        case .named: "named"
        }
    }

    /// How a transcript writes a list of names: each in hex, comma-separated; `-` for none.
    static func list(_ names: [Data]) -> String {
        names.isEmpty ? "-" : names.map { FrozenFields.hex($0) }.joined(separator: ",")
    }

    /// How a transcript writes a list of sizes, comma-separated; `-` for none.
    static func list(_ sizes: [UInt64]) -> String {
        sizes.isEmpty ? "-" : sizes.map(String.init).joined(separator: ",")
    }

    /// The names ``list(_:)-([Data])`` wrote.
    static func names(_ text: String) -> [Data]? {
        guard text != "-" else { return [] }
        let names = text.split(separator: ",").compactMap(FrozenFields.unhex)
        return names.count == text.split(separator: ",").count ? names : nil
    }

    /// The sizes ``list(_:)-([UInt64])`` wrote.
    static func sizes(_ text: String) -> [UInt64]? {
        guard text != "-" else { return [] }
        let sizes = text.split(separator: ",").compactMap { UInt64($0) }
        return sizes.count == text.split(separator: ",").count ? sizes : nil
    }

    /// The step a transcript names `name`.
    static func report(named name: String) -> DragTakeReport? {
        [DragTakeReport.armed, .targeted([]), .delivering, .deliverRefused, .stoodDown].first { Self.name($0) == name }
    }

    static func describe(_ result: ItemPullResult) -> String {
        switch result {
        case .landed(.named(let name)): "landed name=\(FrozenFields.hex(name))"
        case .landed(.inline(let bytes)): "landed inline=\(FrozenFields.hex(bytes))"
        case .failed(let error): "failed code=\(error.code.rawValue)"
        case .closed(let closure): "closed \(describe(closure))"
        }
    }

    static func describe(_ result: ItemServeResult) -> String {
        switch result {
        case .landed: "landed"
        case .failed(let error): "failed code=\(error.code.rawValue)"
        case .closed(let closure): "closed \(describe(closure))"
        }
    }

    package static func describe(_ event: PeerEvent) -> String? {
        switch event {
        case .closed(let closure): "peer closed \(describe(closure))"
        case .items(let event): describe(event, side: .peer)
        case .dragTake(let event): describe(event, side: .peer)
        default: nil
        }
    }

    static func describe(_ result: PowerRequestResult) -> String {
        switch result {
        case .accepted: "accepted"
        case .progress(let stage, let apps):
            "progress stage=\(stage == .askingApps ? 2 : 3) apps=\(TranscriptInput.names(apps))"
        case .refused(let error): "refused code=\(error.code.rawValue)"
        case .indeterminate: "indeterminate"
        case .finished(.handedOff): "finished handedOff"
        case .finished(.blocked(let apps)): "finished blocked apps=\(TranscriptInput.names(apps))"
        case .finished(.cancelledInGuest): "finished cancelledInGuest"
        case .finished(.failed(let error)): "finished failed code=\(error.code.rawValue)"
        case .lostAfterAcceptance: "lostAfterAcceptance"
        }
    }

    static func describe(_ closure: StreamClosure) -> String {
        switch closure {
        case .completed: "completed"
        case .resetByPeer(let error): "resetByPeer code=\(error.code.rawValue)"
        case .resetLocally(let error): "resetLocally code=\(error.code.rawValue)"
        case .connectionClosedLocally(let error): "connectionClosedLocally code=\(error.code.rawValue)"
        case .connectionClosedByPeer(let error): "connectionClosedByPeer code=\(error.code.rawValue)"
        case .connectionLost: "connectionLost"
        }
    }

    static func describe(_ closure: ConnectionClosure) -> String {
        switch closure {
        case .closedLocally(let error): "local code=\(error.code.rawValue) retry=\(error.retryAfter?.milliseconds ?? 0)"
        case .closedByPeer(let error): "byPeer code=\(error.code.rawValue) retry=\(error.retryAfter?.milliseconds ?? 0)"
        case .transportLost: "lost"
        case .notThisProtocol: "notThisProtocol"
        }
    }
}
