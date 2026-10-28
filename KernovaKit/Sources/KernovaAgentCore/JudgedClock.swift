/// The connection's two clocks (§5.2). Raw time is the core's own monotonic
/// timeline: it advances by each input's step forward and by nothing for a step
/// backwards, so a clock that steps back neither charges the far side nor stops
/// the core's timers. Judged time advances only while the far side is running
/// and this side was not itself suspended.
public struct JudgedClock: Sendable, Equatable {
    /// The core's monotonic time.
    public private(set) var raw: CoreInstant
    /// Time charged to the far side.
    public private(set) var judged: CoreInstant
    /// Whether the far side is frozen (the VM is live-paused); nothing is judged.
    public private(set) var isFrozen = false
    /// The latest input's `now`, on the caller's timeline.
    public private(set) var lastInput: CoreInstant
    let suspendedStep: CoreDuration

    init(now: CoreInstant, suspendedStep: CoreDuration) {
        raw = now
        judged = now
        lastInput = now
        self.suspendedStep = suspendedStep
    }

    /// Charges the step to `now`: nothing when frozen, nothing for a step longer
    /// than `suspendedStep` (this side was suspended), nothing backwards.
    mutating func advance(to now: CoreInstant) {
        defer { lastInput = now }
        guard now > lastInput else { return }
        let step = lastInput.duration(to: now)
        raw = raw.advanced(by: step)
        if !isFrozen, step <= suspendedStep {
            judged = judged.advanced(by: step)
        }
    }

    /// A raw instant on the caller's timeline, for `nextDeadline`.
    public func external(_ instant: CoreInstant?) -> CoreInstant? {
        instant.map { lastInput.advanced(by: raw.duration(to: $0)) }
    }

    mutating func setFrozen(_ frozen: Bool) {
        isFrozen = frozen
    }

    /// The raw instant at which judged time reaches `judgedInstant`, were the
    /// far side to keep running; nil while frozen.
    func rawInstant(whenJudgedReaches judgedInstant: CoreInstant) -> CoreInstant? {
        guard !isFrozen else { return nil }
        return raw.advanced(by: max(.zero, judged.duration(to: judgedInstant)))
    }
}

/// A deadline on judged time whose expiry is confirmed (§5.2 rule 4): found
/// passed, it fires only at a later evaluation at least `confirmation` of raw
/// time on that still finds it passed. Whatever ends the judgment replaces it.
public struct JudgedDeadline: Sendable, Equatable {
    /// The judged instant it expires at.
    public private(set) var expiry: CoreInstant
    private var foundPassedAt: CoreInstant?
    private let confirmation: CoreDuration

    /// A deadline `span` of judged time after the clock's current judged instant.
    public init(after span: CoreDuration, on clock: JudgedClock, confirmation: CoreDuration) {
        expiry = clock.judged.advanced(by: span)
        self.confirmation = confirmation
    }

    /// Whether the deadline fires now. A frozen clock judges nothing and restarts
    /// any confirmation.
    public mutating func evaluate(_ clock: JudgedClock) -> Bool {
        guard !clock.isFrozen, clock.judged >= expiry else {
            foundPassedAt = nil
            return false
        }
        guard let foundPassedAt else {
            self.foundPassedAt = clock.raw
            return false
        }
        return clock.raw >= foundPassedAt.advanced(by: confirmation)
    }

    /// The raw instant of the next evaluation the deadline needs; nil while frozen.
    public func wake(_ clock: JudgedClock) -> CoreInstant? {
        if let foundPassedAt { return foundPassedAt.advanced(by: confirmation) }
        return clock.rawInstant(whenJudgedReaches: expiry)
    }
}

/// A token bucket refilled continuously on raw time, in nano-tokens so a
/// slow refill never rounds away.
struct TokenBucket: Sendable, Equatable {
    private static let scale: UInt64 = 1_000_000_000
    private var scaled: UInt64
    let capacity: Int
    let perSecond: Int
    private var refilledAt: CoreInstant

    init(capacity: Int, perSecond: Int, now: CoreInstant, full: Bool = true) {
        self.capacity = capacity
        self.perSecond = perSecond
        scaled = full ? UInt64(capacity) * Self.scale : 0
        refilledAt = now
    }

    var tokens: Int { Int(scaled / Self.scale) }

    mutating func refill(_ now: CoreInstant) {
        guard now > refilledAt else { return }
        let elapsed = min(now.nanoseconds - refilledAt.nanoseconds, 1_000_000_000_000)
        refilledAt = now
        scaled = min(UInt64(capacity) * Self.scale, scaled + elapsed * UInt64(perSecond))
    }

    mutating func take(_ count: Int) -> Bool {
        guard tokens >= count else { return false }
        scaled -= UInt64(count) * Self.scale
        return true
    }

    mutating func takeUpTo(_ count: Int) -> Int {
        let taken = min(count, tokens)
        scaled -= UInt64(taken) * Self.scale
        return taken
    }

    /// When the bucket will hold at least `count` whole tokens (at most its capacity).
    func instant(holding count: Int) -> CoreInstant {
        let target = UInt64(min(count, capacity)) * Self.scale
        guard target > scaled, perSecond > 0 else { return refilledAt }
        let nanoseconds = (target - scaled + UInt64(perSecond) - 1) / UInt64(perSecond)
        return refilledAt.advanced(by: CoreDuration(nanoseconds: Int64(clamping: nanoseconds)))
    }
}
