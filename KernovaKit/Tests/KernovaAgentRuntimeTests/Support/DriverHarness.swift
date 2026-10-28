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

    init(journal: Journal) {
        self.journal = journal
    }

    func start(on queue: DispatchQueue, _ handler: @escaping @Sendable (ByteStreamEvent) -> Void) {
        state.withLock {
            $0.queue = queue
            $0.handler = handler
        }
        journal.add("start")
    }

    func readMore() {
        state.withLock { $0.readMores += 1 }
        journal.add("readMore")
    }

    func write(_ chunks: [Data], _ completion: @escaping @Sendable (ByteStreamError?) -> Void) {
        state.withLock { state in
            if state.pending != nil { state.overlappingWrites += 1 }
            state.pending = completion
            state.writes.append(chunks.reduce(into: Data()) { $0.append($1) })
        }
        journal.add("write")
    }

    func shutdown() {
        let pending = state.withLock { state in
            state.shutdowns += 1
            defer { state.pending = nil }
            return (state.queue, state.pending)
        }
        journal.add("shutdown")
        if let queue = pending.0, let completion = pending.1 { queue.async { completion(.shutDown) } }
    }

    // MARK: The script

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
        return Fire { [state] in state.withLock { $0.entries.removeAll { $0.id == id } } }
    }

    /// The deadlines armed and not yet fired or cancelled, earliest first.
    var armed: [CoreInstant] { state.withLock { $0.entries.map(\.at).sorted() } }

    /// Moves the clock to `instant` and runs every fire now due, each on its queue.
    func advance(to instant: CoreInstant) {
        let due = state.withLock { state -> [Entry] in
            state.now = instant
            let due = state.entries.filter { $0.at <= instant }
            state.entries.removeAll { $0.at <= instant }
            return due
        }
        for entry in due { entry.queue.async(execute: entry.fire) }
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
}

/// A peer `ConnectionDriver` over a `ScriptedStream`, with a host endpoint the test runs by hand as the
/// far side of the transport.
final class PeerDriverHarness: Sendable {
    let journal = Journal()
    let scheduler: ManualScheduler
    let stream: ScriptedStream
    let driver: ConnectionDriver<PeerEndpoint>
    private let events = Locked<[PeerEvent]>([])
    private let far: Locked<HostEndpoint>

    init(power: Availability<PowerOffer> = .available(PowerOffer(actions: [.shutdown]))) {
        let journal = journal
        let events = events
        scheduler = ManualScheduler(now: Fixture.t0, journal: journal)
        stream = ScriptedStream(journal: journal)
        let generation = ConnectionGeneration(rawValue: 1)
        driver = ConnectionDriver(
            endpoint: PeerEndpoint(Fixture.peerConfiguration(power: power), generation: generation, now: Fixture.t0),
            stream: stream, scheduler: scheduler, logger: Fixture.logger,
            handlers: ConnectionDriver<PeerEndpoint>.Handlers(
                effect: { effect, _ in journal.add("effect \(effect)") },
                event: { event, _ in
                    events.withLock { $0.append(event) }
                    journal.add("event \(Self.name(event))")
                }))
        far = Locked(HostEndpoint(Fixture.hostConfiguration(), generation: generation, now: Fixture.t0))
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
        let bytes = stream.takeWritten()
        let now = scheduler.now
        far.withLock { $0.receive(bytes, now: now) }
    }

    /// Runs `command` on the host endpoint.
    func host(_ command: HostCommand) {
        let now = scheduler.now
        far.withLock { $0.handle(command, now: now) }
    }

    /// Everything the host endpoint has to send.
    func hostOutput() -> Data {
        far.withLock { far in
            var bytes = Data()
            while let transmit = far.pollTransmit(maxBytes: 1 << 20) {
                for chunk in transmit.chunks { bytes.append(chunk) }
            }
            return bytes
        }
    }

    /// Starts the driver, completes its first write, and delivers the host's Hello and what follows it.
    func handshake() async {
        driver.start()
        await settle()
        stream.completeWrite()
        await settle()
        hostReads()
        stream.deliver(.received(hostOutput()))
        await settle()
    }
}
