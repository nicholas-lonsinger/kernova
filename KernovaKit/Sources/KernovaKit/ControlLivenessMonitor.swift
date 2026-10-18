import Foundation

/// The control channel's two-stage silence watchdog, keeping one answer for
/// both peers to "is the far side still there, and how does it stop being
/// unresponsive".
///
/// A value its owner keeps beside the connection state the verdicts drive, so
/// one critical section — the host's main actor, the guest agent's lock —
/// both reaches a verdict and acts on it.
public struct ControlLivenessMonitor: Sendable {
    /// What one liveness observation says about the peer.
    ///
    /// Stage changes are edge-triggered — ``becameUnresponsive`` and
    /// ``recovered`` are emitted exactly once per crossing — so a caller acts
    /// on them directly instead of tracking whether it already reacted.
    public enum Verdict: Equatable, Sendable {
        /// No crossing: the peer stands where the previous observation left it,
        /// or has never been heard from at all, so its silence measures
        /// nothing. One case, because a caller does nothing either way.
        case unchanged

        /// The peer was unresponsive and has been heard from again.
        ///
        /// Only ``record(at:)`` and ``hold(at:)`` reach it: they are the sole
        /// writers of the deadline, so an evaluation against a monotonic clock
        /// can only ever find the peer further into its silence.
        case recovered

        /// The peer has just crossed `unresponsiveAfter` seconds of silence.
        case becameUnresponsive(silentFor: TimeInterval)

        /// The peer has crossed `terminateAfter` seconds of silence; the
        /// channel is dead and the caller tears it down.
        case expired(silentFor: TimeInterval)
    }

    private let cadence: ControlChannelCadence
    private var lastSignal: EngineInstant?

    /// Whether the peer is currently in the unresponsive stage.
    public private(set) var isUnresponsive = false

    /// Creates a monitor judging silence against `cadence`.
    public init(cadence: ControlChannelCadence) {
        self.cadence = cadence
    }

    /// Records an inbound frame as a liveness signal at `instant`, arming the
    /// deadline if this is the first.
    ///
    /// With ``hold(at:)``, the only way out of the unresponsive stage: returns
    /// ``Verdict/recovered`` on the call that leaves it and
    /// ``Verdict/unchanged`` on every other.
    @discardableResult
    public mutating func record(at instant: EngineInstant) -> Verdict {
        lastSignal = instant
        guard isUnresponsive else { return .unchanged }
        isUnresponsive = false
        return .recovered
    }

    /// Defers the deadline to `instant` while the peer is unable to answer —
    /// the host holding a live-paused guest's clock.
    ///
    /// A peer that has never been heard from has no deadline to defer, so this
    /// records nothing and answers ``Verdict/unchanged``: a hold must never
    /// stand in for the first signal, or a pause would arm the watchdog against
    /// a channel that never spoke. Otherwise it behaves as ``record(at:)``.
    @discardableResult
    public mutating func hold(at instant: EngineInstant) -> Verdict {
        guard lastSignal != nil else { return .unchanged }
        return record(at: instant)
    }

    /// Judges the peer's silence as of `instant`, which is how it enters the
    /// unresponsive stage and how the channel expires — never how it leaves
    /// either. A peer that has not spoken yet is not judged at all.
    public mutating func evaluate(at instant: EngineInstant) -> Verdict {
        guard let lastSignal else { return .unchanged }
        let silentFor = lastSignal.seconds(to: instant)
        if silentFor > cadence.terminateAfter {
            return .expired(silentFor: silentFor)
        }
        if silentFor > cadence.unresponsiveAfter, !isUnresponsive {
            isUnresponsive = true
            return .becameUnresponsive(silentFor: silentFor)
        }
        return .unchanged
    }

    /// Forgets the recorded signal and the unresponsive stage, so the next
    /// connection is judged from its own first frame.
    public mutating func reset() {
        lastSignal = nil
        isUnresponsive = false
    }
}
