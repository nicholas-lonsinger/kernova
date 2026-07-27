import Foundation
import os

/// Privacy attribute accepted by `KernovaLogMessage` interpolations.
///
/// Mirrors the static-API shape of `OSLogPrivacy` so call sites read the same:
/// `\(value, privacy: .public)`. Apple's `OSLogMessage`/`OSLogInterpolation`
/// can't be reused — compile-time `@_semantics` checks reject manual
/// construction from outside the `os` module — so redaction happens here
/// instead of in the OS's runtime privacy machinery.
public struct LogPrivacy: Sendable {
    /// The redaction policy applied to an interpolated value's local form.
    public enum Kind: Sendable {
        /// Rendered in cleartext locally and on the wire.
        case `public`
        /// Replaced by `<private>` in the local form; cleartext on the wire.
        case `private`
        /// Same redaction as `.private`; signals heightened sensitivity.
        case sensitive
        /// Default-equivalent; rendered in cleartext (matches `.public` here).
        case auto
    }
    /// This attribute's redaction policy.
    public let kind: Kind

    /// Render in cleartext everywhere.
    public static let `public` = LogPrivacy(kind: .public)
    /// Redact the local form; keep cleartext on the wire.
    public static let `private` = LogPrivacy(kind: .private)
    /// Redact the local form; keep cleartext on the wire.
    public static let sensitive = LogPrivacy(kind: .sensitive)
    /// Render in cleartext everywhere.
    public static let auto = LogPrivacy(kind: .auto)
}

/// Captures a log message in two parallel rendered forms — one for `os.Logger`
/// locally, one for forwarding to the host over vsock.
///
/// `localRendered` replaces `.private`/`.sensitive` values with the literal
/// `<private>` placeholder and is passed to `os.Logger` as a single `.public`
/// argument. `wireRendered` is entirely cleartext: vsock is host-guest only and
/// the host is trusted, so redacting there would only hide the user's own VM
/// logs from them.
public struct KernovaLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral,
    Sendable
{
    /// Accumulates a message's local and wire forms as Swift's interpolation
    /// machinery walks the literal segments and interpolated values.
    public struct StringInterpolation: StringInterpolationProtocol {
        var localRendered: String
        var wireRendered: String

        /// Reserves capacity for both rendered forms.
        public init(literalCapacity: Int, interpolationCount: Int) {
            localRendered = ""
            wireRendered = ""
            localRendered.reserveCapacity(literalCapacity * 2)
            wireRendered.reserveCapacity(literalCapacity * 2)
        }

        /// Appends a literal segment verbatim to both forms.
        public mutating func appendLiteral(_ literal: String) {
            localRendered += literal
            wireRendered += literal
        }

        // Default-privacy = `.private` matches `os.Logger`'s string default.
        /// Appends a `String` value, redacting the local form per `privacy`.
        public mutating func appendInterpolation(
            _ value: String,
            privacy: LogPrivacy = .private
        ) {
            wireRendered += value
            localRendered += redacted(value, privacy: privacy)
        }

        /// Appends any non-`String` value via `String(describing:)`, redacting
        /// the local form per `privacy`.
        public mutating func appendInterpolation<T>(
            _ value: T,
            privacy: LogPrivacy = .private
        ) {
            let s = String(describing: value)
            wireRendered += s
            localRendered += redacted(s, privacy: privacy)
        }

        func redacted(_ value: String, privacy: LogPrivacy) -> String {
            switch privacy.kind {
            case .public, .auto:
                return value
            case .private, .sensitive:
                return "<private>"
            }
        }
    }

    /// String for local `os.Logger`, with `.private`/`.sensitive` values already
    /// replaced by the `<private>` placeholder.
    public let localRendered: String

    /// String for forwarding over vsock, every value in cleartext.
    public let wireRendered: String

    /// Builds a message from an interpolated string literal.
    public init(stringInterpolation: StringInterpolation) {
        localRendered = stringInterpolation.localRendered
        wireRendered = stringInterpolation.wireRendered
    }

    /// Builds a message from a plain string literal.
    public init(stringLiteral value: String) {
        localRendered = value
        wireRendered = value
    }
}
