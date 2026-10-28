/// A point on one monotonic timeline, in nanoseconds. The core never reads a
/// clock: every input carries the caller's `now`.
public struct CoreInstant: Comparable, Hashable, Sendable {
    /// Nanoseconds since the timeline's arbitrary origin.
    public var nanoseconds: UInt64

    /// Creates the instant `nanoseconds` after the origin.
    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    /// The instant `duration` later (or earlier), saturating at the timeline's ends.
    public func advanced(by duration: CoreDuration) -> CoreInstant {
        if duration.nanoseconds >= 0 {
            let (sum, overflow) = nanoseconds.addingReportingOverflow(UInt64(duration.nanoseconds))
            return CoreInstant(nanoseconds: overflow ? .max : sum)
        }
        let magnitude = duration.nanoseconds.magnitude
        return CoreInstant(nanoseconds: nanoseconds >= magnitude ? nanoseconds - magnitude : 0)
    }

    /// The signed span from this instant to `other`, saturating.
    public func duration(to other: CoreInstant) -> CoreDuration {
        if other.nanoseconds >= nanoseconds {
            return CoreDuration(nanoseconds: Int64(clamping: other.nanoseconds - nanoseconds))
        }
        return CoreDuration(nanoseconds: -Int64(clamping: nanoseconds - other.nanoseconds))
    }

    /// Orders instants along the timeline.
    public static func < (lhs: CoreInstant, rhs: CoreInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}

/// A signed span of time, in nanoseconds.
public struct CoreDuration: Comparable, Hashable, Sendable {
    /// The span's length; negative spans point backwards.
    public var nanoseconds: Int64

    /// Creates a span of `nanoseconds`.
    public init(nanoseconds: Int64) {
        self.nanoseconds = nanoseconds
    }

    /// No time at all.
    public static let zero = CoreDuration(nanoseconds: 0)

    /// A span of whole seconds, saturating.
    public static func seconds(_ seconds: Int64) -> CoreDuration {
        CoreDuration(
            nanoseconds: seconds.multipliedReportingOverflow(by: 1_000_000_000).overflow
                ? (seconds < 0 ? .min : .max) : seconds * 1_000_000_000)
    }

    /// A span of whole milliseconds, saturating.
    public static func milliseconds(_ milliseconds: Int64) -> CoreDuration {
        CoreDuration(
            nanoseconds: milliseconds.multipliedReportingOverflow(by: 1_000_000).overflow
                ? (milliseconds < 0 ? .min : .max) : milliseconds * 1_000_000)
    }

    /// The span in whole milliseconds, rounded toward zero.
    public var milliseconds: Int64 { nanoseconds / 1_000_000 }

    /// Orders spans by length.
    public static func < (lhs: CoreDuration, rhs: CoreDuration) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    /// The sum of two spans, saturating.
    public static func + (lhs: CoreDuration, rhs: CoreDuration) -> CoreDuration {
        let (sum, overflow) = lhs.nanoseconds.addingReportingOverflow(rhs.nanoseconds)
        guard overflow else { return CoreDuration(nanoseconds: sum) }
        return CoreDuration(nanoseconds: rhs.nanoseconds > 0 ? .max : .min)
    }
}
