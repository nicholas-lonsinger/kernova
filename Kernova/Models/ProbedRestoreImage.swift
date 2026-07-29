import Foundation

/// A restore image at a user-supplied URL, after the pre-download check.
///
/// Only ``sizeBytes`` and the fact that the image carries the virtual-machine
/// hardware model are measured. ``version`` and ``build`` are read out of
/// Apple's filename convention and are absent whenever the filename does not
/// follow it, so nothing that gates the install may depend on them.
struct ProbedRestoreImage: Sendable, Equatable {
    var url: URL
    var sizeBytes: UInt64
    /// Marketing version parsed from the filename, e.g. `"15.6.1"`.
    var version: String?
    /// Apple build parsed from the filename, e.g. `"24G90"`.
    var build: String?

    /// The filename the download lands on, derived from ``url``.
    var suggestedFilename: String {
        RestoreImageFilename.destination(for: url)
    }

    /// Version and build as one phrase, or a fallback when the filename did not
    /// follow Apple's convention.
    var versionSummary: String {
        switch (version, build) {
        case (let version?, let build?): "macOS \(version) (\(build))"
        case (let version?, nil): "macOS \(version)"
        case (nil, let build?): "Build \(build)"
        case (nil, nil): "Unrecognized version"
        }
    }

    /// Whether the parsed version is at most `host`.
    ///
    /// `nil` when the filename yielded no version — the answer is unknown, which
    /// is not the same as a "no".
    func isSupported(onHost host: OperatingSystemVersion) -> Bool? {
        version.flatMap(MacOSVersion.init)?.isSupported(onHost: host)
    }

    /// Reads version and build out of Apple's restore-image filename.
    ///
    /// The convention is `UniversalMac_<version>_<build>_Restore.ipsw`. Anything
    /// else yields `(nil, nil)` rather than a guess.
    static func parseFilename(_ filename: String) -> (version: String?, build: String?) {
        let parts = filename.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 4,
            parts[0] == "UniversalMac",
            parts[3].lowercased() == "restore.ipsw"
        else { return (nil, nil) }

        let version = String(parts[1])
        let build = String(parts[2])
        let versionIsNumeric =
            !version.isEmpty
            && version.split(separator: ".", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
        let buildLooksLikeBuild =
            !build.isEmpty && build.allSatisfy { $0.isLetter || $0.isNumber }
        guard versionIsNumeric, buildLooksLikeBuild else { return (nil, nil) }
        return (version, build)
    }
}
