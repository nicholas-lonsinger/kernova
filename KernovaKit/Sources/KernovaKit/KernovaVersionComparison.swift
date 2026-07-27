import Foundation

/// Numeric comparison of guest-agent version strings, shared by the host and the
/// guest so both sides decide "current vs. outdated" by exactly the same rule.
public enum KernovaVersionComparison {
    /// The guest's update state relative to the version the host bundles.
    public enum UpdateState: Equatable, Sendable {
        /// The host's bundled version isn't known (empty handshake field), so the
        /// guest shows no update info rather than guessing.
        case unknown
        /// The installed/own version is at least the host's bundled version.
        case upToDate
        /// The installed/own version is older than the host's bundled version.
        case updateAvailable(bundled: String)
    }

    /// Whether `version` is at least `bundled` (equal or newer) by numeric
    /// dotted-decimal ordering.
    ///
    /// An empty/whitespace `bundled` is treated as "at least" (true) so a missing
    /// reference version never produces a spurious "outdated" verdict.
    public static func isAtLeast(_ version: String, _ bundled: String) -> Bool {
        let reference = bundled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return true }
        return isAtLeast(version, normalizedBundled: reference)
    }

    /// Classifies `own` against the host's `bundled` version for UI display.
    public static func updateState(own: String, hostBundled bundled: String) -> UpdateState {
        let reference = bundled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return .unknown }
        return isAtLeast(own, normalizedBundled: reference)
            ? .upToDate : .updateAvailable(bundled: reference)
    }

    /// Numeric comparison against an already-trimmed, non-empty reference.
    private static func isAtLeast(_ version: String, normalizedBundled reference: String) -> Bool {
        // `.numeric` compares dotted decimals correctly ("0.9.0" < "0.10.0").
        version.compare(reference, options: .numeric) != .orderedAscending
    }
}
