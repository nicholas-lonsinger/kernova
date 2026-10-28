/// Why a dial failed.
public enum DialFailure: Error, Sendable, Equatable {
    /// Try again later.
    case transient
    /// This guest has no transport to the host; never retry.
    case permanent
}

/// Why the agent stops for good.
public enum StopReason: Sendable, Equatable {
    /// Another live process holds this identity (`SUPERSEDED`).
    case superseded
    /// There is no transport.
    case noTransport
}

/// What the dial schedule asks the runtime to do.
public enum AgentEffect: Sendable, Equatable {
    /// Dial the host now.
    case dial
    /// Exit with status 0 and dial no more.
    case stop(StopReason)
}

/// The peer's pure dial scheduler (§9.3): it holds no endpoint, only when to
/// dial next.
public struct PeerAgent: Sendable {
    /// The delays between attempts; the last repeats.
    static let backoff: [CoreDuration] = [1, 2, 4, 8, 16, 30].map { CoreDuration.seconds($0) }
    /// A connection that received its first policy and then stayed up this long resets the backoff.
    static let lastingSession = CoreDuration.seconds(30)

    /// The schedule's own monotonic time, so a clock stepping back delays nothing.
    private var clock: JudgedClock
    private var nextBackoff = 0
    private var generation = ConnectionGeneration(rawValue: 0)
    private var connected = false
    private var policyAt: CoreInstant?
    private var dialAt: CoreInstant?
    private var dialing = false
    private var stopped = false
    private var effects: [AgentEffect] = []

    /// A schedule that dials at once.
    public init(now: CoreInstant) {
        clock = JudgedClock(now: now, suspendedStep: CoreDuration(nanoseconds: .max))
        dialing = true
        effects.append(.dial)
    }

    /// When `handleTimeout` must next run.
    public var nextDeadline: CoreInstant? { stopped ? nil : clock.external(dialAt) }

    /// The current connection's generation, once one has connected.
    public var currentGeneration: ConnectionGeneration { generation }

    /// The dial connected; the driver makes the endpoint with the generation returned.
    public mutating func dialSucceeded(now: CoreInstant) -> ConnectionGeneration {
        clock.advance(to: now)
        dialing = false
        connected = true
        policyAt = nil
        generation = ConnectionGeneration(rawValue: generation.rawValue + 1)
        return generation
    }

    /// The dial failed.
    public mutating func dialFailed(_ failure: DialFailure, now: CoreInstant) {
        clock.advance(to: now)
        guard !stopped else { return }
        dialing = false
        switch failure {
        case .permanent:
            stop(.noTransport)
        case .transient:
            schedule(after: takeBackoff())
        }
    }

    /// The current connection received its first `PolicyUpdate`.
    public mutating func policyReceived(_ generation: ConnectionGeneration, now: CoreInstant) {
        clock.advance(to: now)
        guard generation == self.generation, connected, policyAt == nil else { return }
        policyAt = clock.raw
    }

    /// A connection ended.
    public mutating func connectionEnded(
        _ generation: ConnectionGeneration, _ closure: ConnectionClosure, now: CoreInstant
    ) {
        clock.advance(to: now)
        guard !stopped, generation == self.generation, connected else { return }
        connected = false
        var retryAfter: CoreDuration?
        if case .closedByPeer(let error) = closure {
            if error.code == .superseded { return stop(.superseded) }
            retryAfter = error.retryAfter
        }
        if let policyAt, policyAt.duration(to: clock.raw) >= Self.lastingSession {
            nextBackoff = 0
        }
        self.policyAt = nil
        schedule(after: max(retryAfter ?? .zero, takeBackoff()))
    }

    /// The timer fired.
    public mutating func handleTimeout(now: CoreInstant) {
        clock.advance(to: now)
        guard !stopped, let dialAt, clock.raw >= dialAt else { return }
        self.dialAt = nil
        dialing = true
        effects.append(.dial)
    }

    /// The next effect.
    public mutating func pollEffect() -> AgentEffect? {
        effects.isEmpty ? nil : effects.removeFirst()
    }

    private mutating func takeBackoff() -> CoreDuration {
        let delay = Self.backoff[min(nextBackoff, Self.backoff.count - 1)]
        nextBackoff = min(nextBackoff + 1, Self.backoff.count - 1)
        return delay
    }

    private mutating func schedule(after delay: CoreDuration) {
        dialAt = clock.raw.advanced(by: delay)
    }

    private mutating func stop(_ reason: StopReason) {
        stopped = true
        dialAt = nil
        effects.append(.stop(reason))
    }
}
