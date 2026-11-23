#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaLogging
import KernovaPortableTestSupport
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
        note("readMore")
    }

    func write(_ chunks: [Data], _ completion: @escaping @Sendable (ByteStreamError?) -> Void) {
        state.withLock { state in
            state.pending = completion
            state.writes.append(chunks.reduce(into: Data()) { $0.append($1) })
        }
        note("write")
    }

    func shutdown() {
        let pending = state.withLock { state in
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

    /// The bytes of every write not yet taken.
    func takeWritten() -> Data {
        state.withLock { state in
            defer { state.writes.removeAll() }
            return state.writes.reduce(into: Data()) { $0.append($1) }
        }
    }
}

/// A clock that stands still: it records each deadline armed and fires none.
final class ManualScheduler: RuntimeScheduler {
    private struct Entry: Sendable {
        var id: Int
        var at: CoreInstant
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
            state.entries.append(Entry(id: state.nextID, at: at))
            return state.nextID
        }
        journal?.add("arm")
        arms.record(at)
        return Fire { [state] in state.withLock { $0.entries.removeAll { $0.id == id } } }
    }

    /// The deadlines armed and not yet fired or cancelled, earliest first.
    var armed: [CoreInstant] { state.withLock { $0.entries.map(\.at).sorted() } }
}

/// Waits until every block already on `queue` has run.
func flush(_ queue: DispatchQueue, fileID: String = #fileID, line: Int = #line) async throws {
    try await Backstop("flush", fileID: fileID, line: line).park { resume in queue.async { resume(()) } }
}

/// The configurations both roles run with in these suites.
enum Fixture {
    static let t0 = CoreInstant(nanoseconds: 1_000_000_000)

    static let hostClaim = PeerClaim(role: .host, versionLabel: "host")

    static let peerClaim = PeerClaim(
        role: .sessionPeer, scope: .user, os: .linux, architecture: .arm64,
        payloadHash: Data(repeating: 0xA1, count: 32), versionLabel: "peer",
        instanceID: Data(repeating: 7, count: 16))

    static let peerState = PeerSessionState(console: .on, sessionID: "1", userName: "user")

    static let logsEnabled = PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: true)])

    static let peerConfiguration = PeerConfiguration(
        claim: peerClaim, state: peerState, power: .available(PowerOffer(actions: [.shutdown])),
        logs: .available(NoParams()), update: .absent(.notImplemented, debugDetail: ""))

    static let logger = KernovaLogger(
        subsystem: "app.kernova.tests", category: "AgentRuntime", sink: .init { _, _, _, _ in })

    /// A logger whose every emission is recorded as its level and text.
    static func recordingLogger() -> (KernovaLogger, Recorder<(KernovaLogLevel, String)>) {
        let records = Recorder<(KernovaLogLevel, String)>()
        let logger = KernovaLogger(
            subsystem: "app.kernova.tests", category: "AgentRuntime",
            sink: .init { level, _, _, segments in
                records.record((level, segments.map(\.text).joined()))
            })
        return (logger, records)
    }
}

/// A peer `ConnectionDriver` over a `ScriptedStream`, its stream, clock and handlers recording into one
/// journal.
final class PeerDriverHarness: Sendable {
    let journal = Journal()
    let scheduler: ManualScheduler
    let stream: ScriptedStream
    let driver: ConnectionDriver<PeerEndpoint>

    init() {
        let journal = journal
        scheduler = ManualScheduler(now: Fixture.t0, journal: journal)
        stream = ScriptedStream(journal: journal)
        driver = ConnectionDriver(
            endpoint: PeerEndpoint(
                Fixture.peerConfiguration, generation: ConnectionGeneration(rawValue: 1), now: Fixture.t0),
            stream: stream, scheduler: scheduler, logger: Fixture.logger,
            handlers: ConnectionDriver<PeerEndpoint>.Handlers(
                effect: { effect, _ in journal.add("effect \(effect)") },
                event: { event, _ in journal.add("event \(Self.name(event))") },
                ended: { _, _ in journal.add("ended") }))
    }

    static func name(_ event: PeerEvent) -> String {
        switch event {
        case .role(.established): "established"
        case .role(.policyReceived): "policyReceived"
        case .liveness: "liveness"
        case .role(.updateAvailable): "updateAvailable"
        case .items: "items"
        case .dragTake: "dragTake"
        case .role(.itemFeatureUsable): "itemFeatureUsable"
        case .itemReply: "itemReply"
        case .diagnostic: "diagnostic"
        case .closed: "closed"
        }
    }

    /// Runs every block already on the driver queue.
    func settle(fileID: String = #fileID, line: Int = #line) async throws {
        try await flush(driver.queue, fileID: fileID, line: line)
    }
}

extension PeerEvent {
    /// Whether this is a `PolicyUpdate`'s arrival, whatever it carries.
    var isPolicyReceived: Bool {
        if case .role(.policyReceived) = self { true } else { false }
    }
}
