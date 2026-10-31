import KernovaWire

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

/// The peer's pure dial scheduler: it holds no endpoint, only when to
/// dial next.
public struct PeerAgent: Sendable {
    /// The delays between attempts; the last repeats.
    static let backoff: [CoreDuration] = [1, 2, 4, 8, 16, 30].map { CoreDuration.seconds($0) }
    /// A connection that received its first policy and then stayed up this long resets the backoff.
    static let lastingSession = CoreDuration.seconds(30)

    /// Where the schedule stands.
    private enum Phase: Sendable {
        /// Waiting to dial at this instant.
        case waiting(until: CoreInstant)
        /// A dial is in flight.
        case dialing
        /// A connection is up.
        case connected(Link)
        /// No session to serve: nothing dials until `unpark`. What was in flight when it parked, if
        /// anything, still ends here.
        case parked(InFlight?)
        /// For good.
        case stopped
    }

    /// What a park left in flight.
    private enum InFlight: Sendable {
        /// A dial, whose connection is refused.
        case dial
        /// A connection, which the runtime closes.
        case connection(Link)
    }

    /// One connection.
    private struct Link: Sendable {
        var generation: ConnectionGeneration
        /// When its first policy arrived.
        var policyAt: CoreInstant?
        /// Unparked while it was still up: the next dial follows its end at once.
        var redialOnEnd = false
    }

    /// The schedule's own monotonic time, so a clock stepping back delays nothing.
    private var clock: JudgedClock
    private var nextBackoff = 0
    private var generation = ConnectionGeneration(rawValue: 0)
    private var phase: Phase
    private var effects: [AgentEffect] = []

    /// A schedule that dials at once, or, `parked`, once `unpark` is called.
    public init(now: CoreInstant, parked: Bool = false) {
        clock = JudgedClock(now: now, suspendedStep: CoreDuration(nanoseconds: .max))
        phase = .parked(nil)
        if !parked { dialNow() }
    }

    /// When `handleTimeout` must next run.
    public var nextDeadline: CoreInstant? {
        guard case .waiting(let dialAt) = phase else { return nil }
        return clock.external(dialAt)
    }

    /// The current connection's generation, once one has connected.
    public var currentGeneration: ConnectionGeneration { generation }

    /// The dial connected; the driver makes the endpoint with the generation returned. Nil once the agent
    /// has stopped or parked: the stream is the caller's to shut down.
    public mutating func dialSucceeded(now: CoreInstant) -> ConnectionGeneration? {
        clock.advance(to: now)
        switch phase {
        case .dialing:
            generation = ConnectionGeneration(rawValue: generation.rawValue + 1)
            phase = .connected(Link(generation: generation))
            return generation
        case .parked(.dial?):
            phase = .parked(nil)
            return nil
        case .waiting, .connected, .parked, .stopped:
            return nil
        }
    }

    /// The dial failed.
    public mutating func dialFailed(_ failure: DialFailure, now: CoreInstant) {
        clock.advance(to: now)
        switch phase {
        case .dialing:
            switch failure {
            case .permanent: stop(.noTransport)
            case .transient: schedule(after: takeBackoff())
            }
        case .parked(.dial?):
            phase = .parked(nil)
        case .waiting, .connected, .parked, .stopped:
            break
        }
    }

    /// The current connection received its first `PolicyUpdate`.
    public mutating func policyReceived(_ generation: ConnectionGeneration, now: CoreInstant) {
        clock.advance(to: now)
        switch phase {
        case .connected(var link) where link.generation == generation && link.policyAt == nil:
            link.policyAt = clock.raw
            phase = .connected(link)
        case .parked(.connection(var link)?) where link.generation == generation && link.policyAt == nil:
            link.policyAt = clock.raw
            phase = .parked(.connection(link))
        default:
            break
        }
    }

    /// A connection ended.
    public mutating func connectionEnded(
        _ generation: ConnectionGeneration, _ closure: ConnectionClosure, now: CoreInstant
    ) {
        clock.advance(to: now)
        let link: Link
        let parked: Bool
        switch phase {
        case .connected(let current) where current.generation == generation: (link, parked) = (current, false)
        case .parked(.connection(let current)?) where current.generation == generation: (link, parked) = (current, true)
        default: return
        }
        var retryAfter: CoreDuration?
        if case .closedByPeer(let error) = closure {
            if error.code == .superseded { return stop(.superseded) }
            retryAfter = error.retryAfter
        }
        if let policyAt = link.policyAt, policyAt.duration(to: clock.raw) >= Self.lastingSession {
            nextBackoff = 0
        }
        if parked {
            phase = .parked(nil)
        } else if link.redialOnEnd {
            dialNow()
        } else {
            schedule(after: max(retryAfter ?? .zero, takeBackoff()))
        }
    }

    /// The peer has no session to serve: dial no more until `unpark`. The runtime closes the connection,
    /// if there is one, and a dial in flight connects nothing.
    public mutating func park(now: CoreInstant) {
        clock.advance(to: now)
        switch phase {
        case .waiting: phase = .parked(nil)
        case .dialing: phase = .parked(.dial)
        case .connected(var link):
            link.redialOnEnd = false
            phase = .parked(.connection(link))
        case .parked, .stopped: break
        }
    }

    /// The peer has a session to serve again: dial at once — or, while a connection is still up, as soon
    /// as it ends; a dial still in flight serves it. Does nothing unless parked.
    public mutating func unpark(now: CoreInstant) {
        clock.advance(to: now)
        guard case .parked(let inFlight) = phase else { return }
        switch inFlight {
        case nil:
            dialNow()
        case .dial?:
            phase = .dialing
        case .connection(var link)?:
            link.redialOnEnd = true
            phase = .connected(link)
        }
    }

    /// The shell is exiting: dial no more, with no `.stop` effect, since the shell asked for it. Every
    /// later input does nothing.
    public mutating func shutDown(now: CoreInstant) {
        clock.advance(to: now)
        phase = .stopped
    }

    /// The timer fired.
    public mutating func handleTimeout(now: CoreInstant) {
        clock.advance(to: now)
        guard case .waiting(let dialAt) = phase, clock.raw >= dialAt else { return }
        dialNow()
    }

    /// The next effect.
    public mutating func pollEffect() -> AgentEffect? {
        effects.isEmpty ? nil : effects.removeFirst()
    }

    private mutating func dialNow() {
        phase = .dialing
        effects.append(.dial)
    }

    private mutating func takeBackoff() -> CoreDuration {
        let delay = Self.backoff[min(nextBackoff, Self.backoff.count - 1)]
        nextBackoff = min(nextBackoff + 1, Self.backoff.count - 1)
        return delay
    }

    private mutating func schedule(after delay: CoreDuration) {
        phase = .waiting(until: clock.raw.advanced(by: delay))
    }

    private mutating func stop(_ reason: StopReason) {
        phase = .stopped
        effects.append(.stop(reason))
    }
}
