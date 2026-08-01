import Foundation

/// Numeric rendering and reading of an operating-system version, shared by the
/// host and the guest agent so the restore-image UI and the
/// `AgentInfo.os_version` handshake field agree on one shape.
public enum KernovaOSVersion {
    /// `version` rendered the way Apple names a release: a zero patch is left
    /// off, so `26.6.0` reads as `"26.6"` and matches the catalog's own strings.
    ///
    /// - Parameter version: The decomposed version to render.
    /// - Returns: A dotted-decimal string such as `"26.6"` or `"12.0.1"`.
    public static func displayString(_ version: OperatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? base : "\(base).\(version.patchVersion)"
    }

    /// The running system's version in that shape.
    ///
    /// Reads the decomposed `ProcessInfo.operatingSystemVersion`, since
    /// `operatingSystemVersionString` is documented as human-readable only, not
    /// appropriate for parsing, and is localized to the reporting machine's
    /// locale (`ProcessInfo` reference).
    public static var current: String {
        displayString(ProcessInfo.processInfo.operatingSystemVersion)
    }

    /// The first dotted-decimal run in `reported`, or `nil` when it holds none.
    ///
    /// `AgentInfo.os_version` is peer-supplied, so a peer that sends a
    /// human-readable string instead of the documented numeric shape still reads
    /// as a version: `"Version 26.0 (Build 25A123)"` and its translation in any
    /// locale both yield `"26.0"`.
    ///
    /// - Parameter reported: The peer-supplied version string.
    /// - Returns: The leading dotted-decimal run, or `nil` when `reported`
    ///   contains no digits.
    public static func numericVersion(in reported: String) -> String? {
        guard let match = reported.firstMatch(of: #/\d+(?:\.\d+)*/#) else { return nil }
        return String(match.output)
    }
}
