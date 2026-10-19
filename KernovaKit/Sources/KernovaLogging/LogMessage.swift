/// One run of a log message: either a piece of the literal or one rendered
/// interpolation.
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

/// The privacy an interpolation in a `LogMessage` asks for.
public enum LogPrivacy: Sendable {
    /// Shown in the log store as written.
    case `public`
    /// Redacted in the log store unless the system reveals private data.
    case `private`
}

/// A log message written as a string literal, recorded as `LogSegment`s.
///
/// Each interpolation takes an optional `privacy:` argument. Without one it
/// gets `os.Logger`'s documented default: "By default, the system doesn't
/// redact integer, floating-point and Boolean values, but it does redact the
/// contents of dynamic strings and complex dynamic objects."
public struct LogMessage: ExpressibleByStringInterpolation, Sendable, Equatable {
    /// The message's literal runs and rendered interpolations, in order.
    public let segments: [LogSegment]

    /// Creates a message from segments already split and marked.
    public init(segments: [LogSegment]) {
        self.segments = segments
    }

    /// Creates a message with no interpolations: one public segment, or none
    /// when `value` is empty.
    public init(stringLiteral value: String) {
        segments = value.isEmpty ? [] : [LogSegment(text: value, isPrivate: false)]
    }

    /// Creates a message from an interpolated literal.
    public init(stringInterpolation: StringInterpolation) {
        segments = stringInterpolation.segments
    }

    /// Every `appendInterpolation` overload takes the same parameters: with a
    /// shorter list on one, an unannotated `Int` resolves to the catch-all and
    /// comes out private.
    public struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var segments: [LogSegment] = []

        /// Reserves room for every literal run and interpolation.
        public init(literalCapacity: Int, interpolationCount: Int) {
            segments.reserveCapacity(2 * interpolationCount + 1)
        }

        /// A literal run, public; an empty run adds no segment.
        public mutating func appendLiteral(_ literal: String) {
            guard !literal.isEmpty else { return }
            segments.append(LogSegment(text: literal, isPrivate: false))
        }

        /// An integer, public unless `privacy` says otherwise.
        public mutating func appendInterpolation<T: BinaryInteger>(_ value: T, privacy: LogPrivacy? = nil) {
            append(String(describing: value), privacy, byDefault: .public)
        }

        /// A floating-point value, public unless `privacy` says otherwise.
        public mutating func appendInterpolation<T: BinaryFloatingPoint>(_ value: T, privacy: LogPrivacy? = nil) {
            append(String(describing: value), privacy, byDefault: .public)
        }

        /// A Boolean, public unless `privacy` says otherwise.
        public mutating func appendInterpolation(_ value: Bool, privacy: LogPrivacy? = nil) {
            append(String(describing: value), privacy, byDefault: .public)
        }

        /// A string, private unless `privacy` says otherwise.
        public mutating func appendInterpolation(_ value: String, privacy: LogPrivacy? = nil) {
            append(value, privacy, byDefault: .private)
        }

        /// Any other value, rendered with `String(describing:)`, private unless
        /// `privacy` says otherwise.
        public mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy? = nil) {
            append(String(describing: value), privacy, byDefault: .private)
        }

        private mutating func append(_ text: String, _ privacy: LogPrivacy?, byDefault: LogPrivacy) {
            segments.append(LogSegment(text: text, isPrivate: (privacy ?? byDefault) == .private))
        }
    }
}
