import Foundation
import os

/// Privacy attribute accepted by `KernovaLogMessage` interpolations.
///
/// Mirrors the static-API shape of `OSLogPrivacy` so call sites read the
/// same: `\(value, privacy: .public)`, `\(value, privacy: .private)`, etc.
/// We define our own type because Apple's `OSLogMessage` /
/// `OSLogInterpolation` are guarded by compile-time `@_semantics` checks
/// that reject manual construction from outside the `os` module —
/// so we redact privately-marked values ourselves instead of relying on
/// the OS's runtime privacy machinery.
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

/// Captures a log message in two parallel rendered forms — one suitable
/// for emission to `os.Logger` on the local process, one for forwarding to
/// a remote (the host, over vsock).
///
/// **Local form** (`localRendered`): values marked `.private` or
/// `.sensitive` are replaced by the literal `<private>` placeholder. The
/// rendered string is then passed to `os.Logger` as a single `.public`
/// argument, so Console.app displays the placeholders directly instead of
/// relying on the OS's runtime privacy redaction. `.public` and `.auto`
/// values render as themselves.
///
/// **Wire form** (`wireRendered`): every interpolated value is rendered
/// in cleartext. Vsock is host-guest only and the host is the trusted
/// destination; redacting on the wire would simply hide diagnostic
/// information from the user inspecting their own VM's logs.
///
/// Lives in `KernovaKit` so both the guest agent (which forwards over
/// vsock) and the host app (which logs locally) share one logging surface;
/// see `KernovaLogger`.
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
        // `StringInterpolationProtocol` witness, invoked by Swift's
        // compiler-emitted interpolation machinery.
        /// Appends a `String` value, redacting the local form per `privacy`.
        public mutating func appendInterpolation(
            _ value: String,
            privacy: LogPrivacy = .private
        ) {
            wireRendered += value
            localRendered += redacted(value, privacy: privacy)
        }

        // Generic fallback for non-`String` types — numbers, booleans,
        // arrays, anything `CustomStringConvertible`. Rendered via
        // `String(describing:)`. Same witness rationale as the `String` overload.
        /// Appends any value via `String(describing:)`, redacting the local
        /// form per `privacy`.
        public mutating func appendInterpolation<T>(
            _ value: T,
            privacy: LogPrivacy = .private
        ) {
            let s = String(describing: value)
            wireRendered += s
            localRendered += redacted(s, privacy: privacy)
        }

        // Applies the privacy policy; called only from the `appendInterpolation`
        // witnesses above.
        func redacted(_ value: String, privacy: LogPrivacy) -> String {
            switch privacy.kind {
            case .public, .auto:
                return value
            case .private, .sensitive:
                return "<private>"
            }
        }
    }

    /// String suitable for emission to local `os.Logger`.
    ///
    /// Values marked
    /// `.private` or `.sensitive` have already been replaced with the
    /// `<private>` placeholder.
    public let localRendered: String

    /// String suitable for forwarding over vsock.
    ///
    /// Every interpolated
    /// value is rendered in cleartext.
    public let wireRendered: String

    /// Builds a message from an interpolated string literal.
    public init(stringInterpolation: StringInterpolation) {
        localRendered = stringInterpolation.localRendered
        wireRendered = stringInterpolation.wireRendered
    }

    /// Builds a message from a plain string literal (identical local/wire forms).
    public init(stringLiteral value: String) {
        localRendered = value
        wireRendered = value
    }
}
