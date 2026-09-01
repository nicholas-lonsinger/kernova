import Foundation

/// The control channel's two-stage silence watchdog, keeping one answer for
/// both peers to "is the far side still there, and how does it stop being
/// unresponsive".
///
/// Lock-guarded rather than isolated: the host drives it from the main actor
/// and the guest from its per-connection serve task, and a watchdog that could
/// be queued behind the blocking send it exists to break is no watchdog.
public final class ControlLivenessMonitor: @unchecked Sendable {
    /// What one liveness observation says about the peer.
    ///
    /// Stage changes are edge-triggered — ``becameUnresponsive`` and
    /// ``recovered`` are emitted exactly once per crossing — so a caller acts
    /// on them directly instead of tracking whether it already reacted.
    public enum Verdict: Equatable, Sendable {
        /// Nothing has been recorded: the peer has never been heard from, so
        /// its silence measures nothing.
        case noSignal

        /// No crossing — the peer stands where the previous observation left
        /// it.
        case unchanged

        /// The peer was unresponsive and has been heard from again.
        case recovered

        /// The peer has just crossed `unresponsiveAfter` seconds of silence.
        case becameUnresponsive(silentFor: TimeInterval)

        /// The peer has crossed `terminateAfter` seconds of silence; the
        /// channel is dead and the caller tears it down.
        case expired(silentFor: TimeInterval)
    }

    private let cadence: ControlChannelCadence
    private let lock = NSLock()
    private var lastSignal: EngineInstant?
    private var unresponsive = false

    /// Creates a monitor judging silence against `cadence`.
    public init(cadence: ControlChannelCadence) {
        self.cadence = cadence
    }

    /// Whether the peer is currently in the unresponsive stage.
    public var isUnresponsive: Bool {
        lock.withLock { unresponsive }
    }

    /// Records a liveness signal at `instant` — an inbound frame, or a hold
    /// that defers the deadline while the peer cannot answer.
    ///
    /// The only way out of the unresponsive stage: returns ``Verdict/recovered``
    /// on the call that leaves it and ``Verdict/unchanged`` on every other.
    @discardableResult
    public func record(at instant: EngineInstant) -> Verdict {
        lock.withLock {
            lastSignal = instant
            guard unresponsive else { return .unchanged }
            unresponsive = false
            return .recovered
        }
    }

    /// Judges the peer's silence as of `instant`.
    public func evaluate(at instant: EngineInstant) -> Verdict {
        lock.withLock {
            guard let lastSignal else { return .noSignal }
            let silentFor = lastSignal.seconds(to: instant)
            if silentFor > cadence.terminateAfter {
                return .expired(silentFor: silentFor)
            }
            if silentFor > cadence.unresponsiveAfter {
                guard !unresponsive else { return .unchanged }
                unresponsive = true
                return .becameUnresponsive(silentFor: silentFor)
            }
            guard unresponsive else { return .unchanged }
            unresponsive = false
            return .recovered
        }
    }

    /// Forgets the recorded signal and the unresponsive stage, so the next
    /// connection is judged from its own first frame.
    public func reset() {
        lock.withLock {
            lastSignal = nil
            unresponsive = false
        }
    }
}
