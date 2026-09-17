import Foundation

/// One run of a forwarded log message: either a piece of the literal or one
/// rendered interpolation.
///
/// vsock is host-guest only and the host is trusted, so `text` is cleartext
/// either way; `isPrivate` is what lets the host redact by default and reveal
/// on demand, the way `logd` does for a record emitted on the host itself.
public struct LogSegment: Sendable, Equatable {
    /// The run's rendered text, always cleartext.
    public let text: String

    /// Whether the emitting side marked this run as private.
    public let isPrivate: Bool

    /// Creates a segment.
    public init(text: String, isPrivate: Bool) {
        self.text = text
        self.isPrivate = isPrivate
    }
}

/// Builds the wire segments for one interpolated value.
///
/// The `#log` expansion calls these and nothing else does. Apple states
/// `os.Logger`'s default: "By default, the system doesn't redact integer,
/// floating-point and Boolean values, but it does redact the contents of
/// dynamic strings and complex dynamic objects." The overload set mirrors that
/// rule, so an interpolation written without a `privacy:` argument lands on the
/// wire with the privacy `logd` gave it locally.
public enum LogWire {
    /// An integer, public by default.
    public static func segment<T: BinaryInteger>(_ value: T) -> LogSegment {
        LogSegment(text: String(describing: value), isPrivate: false)
    }

    /// A floating-point value, public by default.
    public static func segment<T: BinaryFloatingPoint>(_ value: T) -> LogSegment {
        LogSegment(text: String(describing: value), isPrivate: false)
    }

    /// A Boolean, public by default.
    public static func segment(_ value: Bool) -> LogSegment {
        LogSegment(text: String(describing: value), isPrivate: false)
    }

    /// A string or any other value, private by default.
    public static func segment<T>(_ value: T) -> LogSegment {
        LogSegment(text: String(describing: value), isPrivate: true)
    }

    /// Any value, with the privacy the call site asked for.
    public static func segment<T>(_ value: T, isPrivate: Bool) -> LogSegment {
        LogSegment(text: String(describing: value), isPrivate: isPrivate)
    }
}
