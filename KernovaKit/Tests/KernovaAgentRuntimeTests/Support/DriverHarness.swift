#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaLogging
import KernovaSynchronization
import KernovaWire

/// What the stream, the scheduler and the driver's handlers did, in the order they did it.
final class Journal: Sendable {
    private let entries = Locked<[String]>([])

    func add(_ entry: String) {
        entries.withLock { $0.append(entry) }
    }

    /// Everything recorded since the last `take()`.
    func take() -> [String] {
        entries.withLock { entries in
            defer { entries.removeAll() }
            return entries
        }
    }
}

/// A `ByteStream` the test plays: it records each call and delivers only what the test scripts.
final class ScriptedStream: ByteStream {
    private struct State: Sendable {
        var queue: DispatchQueue?
        var handler: (@Sendable (ByteStreamEvent) -> Void)?
        var pending: (@Sendable (ByteStreamError?) -> Void)?
        var writes: [Data] = []
        var overlappingWrites = 0
        var readMores = 0
        var shutdowns = 0
    }

    private let state = Locked(State())
    private let journal: Journal
    /// Each call the stream took: `start`, `write`, `readMore`, `shutdown`.
    let calls = Recorder<String>()

    init(journal: Journal = Journal()) {
        self.journal = journal
    }

    func start(on queue: DispatchQueue, _ handler: @escaping @Sendable (ByteStreamEvent) -> Void) {
        state.withLock {
            $0.queue = queue
            $0.handler = handler
        }
        note("start")
    }

    func readMore() {
        state.withLock { $0.readMores += 1 }
        note("readMore")
    }

    func write(_ chunks: [Data], _ completion: @escaping @Sendable (ByteStreamError?) -> Void) {
        state.withLock { state in
            if state.pending != nil { state.overlappingWrites += 1 }
            state.pending = completion
            state.writes.append(chunks.reduce(into: Data()) { $0.append($1) })
        }
        note("write")
    }

    func shutdown() {
        let pending = state.withLock { state in
            state.shutdowns += 1
            defer { state.pending = nil }
            return (state.queue, state.pending)
        }
        note("shutdown")
        if let queue = pending.0, let completion = pending.1 { queue.async { completion(.shutDown) } }
    }

    private func note(_ call: String) {
        journal.add(call)
        calls.record(call)
    }

    // MARK: The script

    /// The start queue, once started.
    var queue: DispatchQueue? { state.withLock(\.queue) }

    /// Delivers `event` on the start queue.
    func deliver(_ event: ByteStreamEvent) {
        let (queue, handler) = state.withLock { ($0.queue, $0.handler) }
        guard let queue, let handler else { return }
        queue.async { handler(event) }
    }

    /// Completes the outstanding write on the start queue.
    func completeWrite(_ error: ByteStreamError? = nil) {
        let (queue, completion) = state.withLock { state in
            defer { state.pending = nil }
            return (state.queue, state.pending)
        }
        guard let queue, let completion else { return }
        queue.async { completion(error) }
    }

    var hasPendingWrite: Bool { state.withLock { $0.pending != nil } }
    var writeCount: Int { state.withLock { $0.writes.count } }
    var overlappingWrites: Int { state.withLock { $0.overlappingWrites } }
    var readMores: Int { state.withLock { $0.readMores } }
    var shutdowns: Int { state.withLock { $0.shutdowns } }

    /// The bytes of every write not yet taken.
    func takeWritten() -> Data {
        state.withLock { state in
            defer { state.writes.removeAll() }
            return state.writes.reduce(into: Data()) { $0.append($1) }
        }
    }
}

/// A clock the test advances; due fires run on their queues when it does.
final class ManualScheduler: RuntimeScheduler {
    private struct Entry: Sendable {
        var id: Int
        var at: CoreInstant
        var queue: DispatchQueue
        var fire: @Sendable () -> Void
    }

    private struct Fire: ScheduledFire {
        let cancelBody: @Sendable () -> Void
        func cancel() { cancelBody() }
    }

    private struct State: Sendable {
        var now: CoreInstant
        var nextID = 0
        var entries: [Entry] = []
    }

    private let state: Locked<State>
    private let journal: Journal?
    /// Each deadline armed, in order.
    let arms = Recorder<CoreInstant>()

    init(now: CoreInstant, journal: Journal? = nil) {
        state = Locked(State(now: now))
        self.journal = journal
    }

    var now: CoreInstant { state.withLock(\.now) }

    func schedule(at: CoreInstant, on queue: DispatchQueue, _ fire: @escaping @Sendable () -> Void)
        -> any ScheduledFire
    {
        let id = state.withLock { state in
            state.nextID += 1
            state.entries.append(Entry(id: state.nextID, at: at, queue: queue, fire: fire))
            return state.nextID
        }
        journal?.add("arm")
        arms.record(at)
        return Fire { [state] in state.withLock { $0.entries.removeAll { $0.id == id } } }
    }

    /// The deadlines armed and not yet fired or cancelled, earliest first.
    var armed: [CoreInstant] { state.withLock { $0.entries.map(\.at).sorted() } }

    /// Moves the clock to `instant` and queues every fire now due, each on its queue.
    func advance(to instant: CoreInstant) {
        let due = state.withLock { state -> [Entry] in
            state.now = instant
            let due = state.entries.filter { $0.at <= instant }
            state.entries.removeAll { $0.at <= instant }
            return due
        }
        for entry in due { entry.queue.async(execute: entry.fire) }
    }

    /// Moves the clock to `instant` without running any fire.
    func set(now instant: CoreInstant) {
        state.withLock { $0.now = instant }
    }

    /// Queues the earliest armed fire now, whatever its deadline: a timer that fires early.
    func fireEarliestEarly() {
        let entry = state.withLock { state -> Entry? in
            guard let earliest = state.entries.min(by: { $0.at < $1.at }) else { return nil }
            state.entries.removeAll { $0.id == earliest.id }
            return earliest
        }
        if let entry { entry.queue.async(execute: entry.fire) }
    }
}

/// Waits until every block already on `queue` has run.
func flush(_ queue: DispatchQueue) async {
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
}

/// The configurations both roles run with in these suites.
enum Fixture {
    static let t0 = CoreInstant(nanoseconds: 1_000_000_000)

    static func at(milliseconds: Int64) -> CoreInstant {
        t0.advanced(by: .milliseconds(milliseconds))
    }

    /// When a connection made at `t0` first sends a PING.
    static let firstPing = t0.advanced(by: ReceiverPolicy.production.pingInterval)

    static let hostClaim = PeerClaim(role: .host, versionLabel: "host")

    static let peerClaim = PeerClaim(
        role: .sessionPeer, scope: .user, os: .linux, architecture: .arm64,
        payloadHash: Data(repeating: 0xA1, count: 32), versionLabel: "peer",
        instanceID: Data(repeating: 7, count: 16))

    static let peerState = PeerSessionState(console: .on, sessionID: "1", userName: "user")

    static let logsEnabled = PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: true)])

    static func peerConfiguration(power: Availability<PowerOffer> = .available(PowerOffer(actions: [.shutdown])))
        -> PeerConfiguration
    {
        PeerConfiguration(
            claim: peerClaim, state: peerState, power: power, logs: .available(NoParams()),
            update: .absent(.notImplemented, debugDetail: ""))
    }

    static func hostConfiguration(policy: PolicySnapshot = PolicySnapshot(), bundles: [BundledPayload] = [])
        -> HostConfiguration
    {
        HostConfiguration(claim: hostClaim, sessionToken: Data(0..<16), policy: policy, bundles: bundles)
    }

    static let logger = KernovaLogger(subsystem: "app.kernova.tests", category: "AgentRuntime") { _, _, _, _ in }

    /// A logger whose every emission is recorded as its level and text.
    static func recordingLogger() -> (KernovaLogger, Recorder<(KernovaLogLevel, String)>) {
        let records = Recorder<(KernovaLogLevel, String)>()
        let logger = KernovaLogger(subsystem: "app.kernova.tests", category: "AgentRuntime") { level, _, _, segments in
            records.record((level, segments.map(\.text).joined()))
        }
        return (logger, records)
    }

    /// The frames `bytes` holds: whole frames written after the preamble.
    static func frames(_ bytes: Data) -> [Frame] {
        var decoder = FrameDecoder()
        decoder.append(WireConstants.preamble)
        decoder.append(bytes)
        var frames: [Frame] = []
        while let frame = try? decoder.nextFrame() { frames.append(frame) }
        return frames
    }
}

/// A host endpoint the test runs by hand as the far side of a scripted stream.
final class FarHost: Sendable {
    private let endpoint: Locked<HostEndpoint>
    private let clock: ManualScheduler
    /// Everything the host endpoint told its hub.
    let events = Recorder<HostEvent>()

    init(
        clock: ManualScheduler, configuration: HostConfiguration = Fixture.hostConfiguration(),
        generation: ConnectionGeneration = ConnectionGeneration(rawValue: 1)
    ) {
        self.clock = clock
        endpoint = Locked(HostEndpoint(configuration, generation: generation, now: clock.now))
    }

    /// Feeds the host endpoint what the peer wrote.
    func read(_ bytes: Data) {
        let now = clock.now
        let events = endpoint.withLock { endpoint in
            endpoint.receive(bytes, now: now)
            return Self.drain(&endpoint)
        }
        events.forEach(self.events.record)
    }

    /// Runs a hub command on the host endpoint.
    func command(_ command: HostCommand) {
        let now = clock.now
        let events = endpoint.withLock { endpoint in
            endpoint.handle(command, now: now)
            return Self.drain(&endpoint)
        }
        events.forEach(self.events.record)
    }

    /// Everything the host endpoint has to send.
    func output() -> Data {
        let (bytes, events) = endpoint.withLock { endpoint in
            var bytes = Data()
            while let transmit = endpoint.pollTransmit(maxBytes: 1 << 20) {
                for chunk in transmit.chunks { bytes.append(chunk) }
            }
            return (bytes, Self.drain(&endpoint))
        }
        events.forEach(self.events.record)
        return bytes
    }

    private static func drain(_ endpoint: inout HostEndpoint) -> [HostEvent] {
        var events: [HostEvent] = []
        while let event = endpoint.pollEvent() { events.append(event) }
        while endpoint.pollEffect() != nil {}
        return events
    }
}

/// A peer `ConnectionDriver` over a `ScriptedStream`, with a host endpoint the test runs by hand as the
/// far side of the transport.
final class PeerDriverHarness: Sendable {
    let journal = Journal()
    let scheduler: ManualScheduler
    let stream: ScriptedStream
    let driver: ConnectionDriver<PeerEndpoint>
    let far: FarHost
    /// Each `Handlers.ended` call's closure.
    let ended = Recorder<ConnectionClosure>()
    private let events = Locked<[PeerEvent]>([])

    init(
        power: Availability<PowerOffer> = .available(PowerOffer(actions: [.shutdown])),
        policy: PolicySnapshot = PolicySnapshot(), logger: KernovaLogger = Fixture.logger,
        inTurn: @escaping @Sendable (PeerEffect) -> InTurnEffect<PeerInput> = { _ in .deliver }
    ) {
        let journal = journal
        let events = events
        let ended = ended
        scheduler = ManualScheduler(now: Fixture.t0, journal: journal)
        stream = ScriptedStream(journal: journal)
        let generation = ConnectionGeneration(rawValue: 1)
        driver = ConnectionDriver(
            endpoint: PeerEndpoint(Fixture.peerConfiguration(power: power), generation: generation, now: Fixture.t0),
            stream: stream, scheduler: scheduler, logger: logger,
            handlers: ConnectionDriver<PeerEndpoint>.Handlers(
                inTurn: inTurn,
                effect: { effect, _ in journal.add("effect \(effect)") },
                event: { event, _ in
                    events.withLock { $0.append(event) }
                    journal.add("event \(Self.name(event))")
                },
                ended: { closure, _ in
                    journal.add("ended")
                    ended.record(closure)
                }))
        far = FarHost(clock: scheduler, configuration: Fixture.hostConfiguration(policy: policy))
    }

    static func name(_ event: PeerEvent) -> String {
        switch event {
        case .established: "established"
        case .policyReceived: "policyReceived"
        case .hostLiveness: "hostLiveness"
        case .updateAvailable: "updateAvailable"
        case .diagnostic: "diagnostic"
        case .closed: "closed"
        }
    }

    /// Runs every block already on the driver queue.
    func settle() async {
        await flush(driver.queue)
    }

    /// The events delivered since the last call.
    func takeEvents() -> [PeerEvent] {
        events.withLock { events in
            defer { events.removeAll() }
            return events
        }
    }

    /// Feeds the peer's written bytes to the host endpoint.
    func hostReads() {
        far.read(stream.takeWritten())
    }

    /// Starts the driver, completes its first write, and delivers the host's Hello and what follows it.
    func handshake() async {
        driver.start()
        await settle()
        stream.completeWrite()
        await settle()
        hostReads()
        stream.deliver(.received(far.output()))
        await settle()
    }
}
