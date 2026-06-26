import Foundation

/// Numeric comparison of guest-agent version strings, shared by the host and the
/// guest so both sides decide "current vs. outdated" by exactly the same rule.
///
/// The host uses it to decide whether a guest's reported version resolves to
/// `.current` or `.outdated` (driving the "Update Guest Agent…" affordance); the
/// guest uses it to label its own menu-bar update line. Keeping the one numeric
/// rule here prevents the two sides from drifting on edge cases (empty strings,
/// dotted-decimal ordering like `0.9.0` < `0.10.0`).
public enum KernovaVersionComparison {
    /// The guest's update state relative to the version the host bundles.
    public enum UpdateState: Equatable, Sendable {
        /// The host's bundled version isn't known (empty handshake field — e.g.
        /// a host predating the field, or its version sidecar is missing). The
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
    /// reference version never produces a spurious "outdated" verdict. Strictly
    /// older is the only `false`.
    public static func isAtLeast(_ version: String, _ bundled: String) -> Bool {
        let reference = bundled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return true }
        return isAtLeast(version, normalizedBundled: reference)
    }

    /// Classifies `own` against the host's `bundled` version for UI display.
    ///
    /// Empty `bundled` → `.unknown` (show nothing). Equal or newer → `.upToDate`.
    /// Strictly older → `.updateAvailable`.
    public static func updateState(own: String, hostBundled bundled: String) -> UpdateState {
        let reference = bundled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return .unknown }
        return isAtLeast(own, normalizedBundled: reference)
            ? .upToDate : .updateAvailable(bundled: reference)
    }

    /// Numeric comparison against an already-trimmed, non-empty reference.
    ///
    /// The two public entry points each normalize `bundled` exactly once and
    /// share this core, so there is a single normalization point — no second
    /// trim and no re-checking emptiness that the callers already guaranteed.
    private static func isAtLeast(_ version: String, normalizedBundled reference: String) -> Bool {
        // `.numeric` compares dotted decimals correctly ("0.9.0" < "0.10.0").
        version.compare(reference, options: .numeric) != .orderedAscending
    }
}
