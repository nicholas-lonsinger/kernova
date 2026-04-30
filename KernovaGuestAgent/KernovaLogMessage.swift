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
    @usableFromInline enum Kind: Sendable {
        case `public`
        case `private`
        case sensitive
        case auto
    }
    @usableFromInline let kind: Kind

    public static let `public` = LogPrivacy(kind: .public)
    public static let `private` = LogPrivacy(kind: .private)
    public static let sensitive = LogPrivacy(kind: .sensitive)
    public static let auto = LogPrivacy(kind: .auto)
}

/// Captures a log message in two parallel rendered forms — one suitable
/// for emission to `os.Logger` on the local guest, one for forwarding to
/// the host over vsock.
///
/// **Local form** (`localRendered`): values marked `.private` or
/// `.sensitive` are replaced by the literal `<private>` placeholder. The
/// rendered string is then passed to `os.Logger` as a single `.public`
/// argument, so Console.app on the guest displays the placeholders
/// directly instead of relying on the OS's runtime privacy redaction.
/// `.public` and `.auto` values render as themselves.
///
/// **Wire form** (`wireRendered`): every interpolated value is rendered
/// in cleartext. Vsock is host-guest only and the host is the trusted
/// destination; redacting on the wire would simply hide diagnostic
/// information from the user inspecting their own VM's logs.
///
/// NOTE: This type currently lives only inside the `KernovaGuestAgent`
/// target. If a future use case needs the same wrapper on the host or in
/// another target, relocate this file (and `KernovaLogger.swift`) into
/// the `KernovaProtocol` Swift Package and update the consuming targets'
/// dependencies.
public struct KernovaLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, Sendable {

    public struct StringInterpolation: StringInterpolationProtocol {
        @usableFromInline var localRendered: String
        @usableFromInline var wireRendered: String

        public init(literalCapacity: Int, interpolationCount: Int) {
            localRendered = ""
            wireRendered = ""
            localRendered.reserveCapacity(literalCapacity * 2)
            wireRendered.reserveCapacity(literalCapacity * 2)
        }

        public mutating func appendLiteral(_ literal: String) {
            localRendered += literal
            wireRendered += literal
        }

        // Default-privacy = `.private` matches `os.Logger`'s string default.

        public mutating func appendInterpolation(
            _ value: String,
            privacy: LogPrivacy = .private
        ) {
            wireRendered += value
            localRendered += redacted(value, privacy: privacy)
        }

        // Generic fallback for non-`String` types — numbers, booleans,
        // arrays, anything `CustomStringConvertible`. Rendered via
        // `String(describing:)`.
        public mutating func appendInterpolation<T>(
            _ value: T,
            privacy: LogPrivacy = .private
        ) {
            let s = String(describing: value)
            wireRendered += s
            localRendered += redacted(s, privacy: privacy)
        }

        @usableFromInline
        func redacted(_ value: String, privacy: LogPrivacy) -> String {
            switch privacy.kind {
            case .public, .auto:
                return value
            case .private, .sensitive:
                return "<private>"
            }
        }
    }

    /// String suitable for emission to local `os.Logger`. Values marked
    /// `.private` or `.sensitive` have already been replaced with the
    /// `<private>` placeholder.
    public let localRendered: String

    /// String suitable for forwarding over vsock. Every interpolated
    /// value is rendered in cleartext.
    public let wireRendered: String

    public init(stringInterpolation: StringInterpolation) {
        localRendered = stringInterpolation.localRendered
        wireRendered = stringInterpolation.wireRendered
    }

    public init(stringLiteral value: String) {
        localRendered = value
        wireRendered = value
    }
}
