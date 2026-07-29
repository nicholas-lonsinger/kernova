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

    /// The filename the download lands on, taken from the URL.
    ///
    /// Per-image rather than a fixed name for the same reason a catalog pick is:
    /// a shared filename lets an already-downloaded image of a different version
    /// satisfy the download step.
    var suggestedFilename: String {
        let candidate = url.lastPathComponent
        guard candidate.lowercased().hasSuffix(".ipsw"), !candidate.hasPrefix(".") else {
            return "RestoreImage.ipsw"
        }
        return candidate
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
    /// is not the same as a "no". Virtualization refuses a guest newer than the
    /// host, but it only says so once the image is on disk.
    func isSupported(onHost host: OperatingSystemVersion) -> Bool? {
        guard let version else { return nil }
        let parsed = version.split(separator: ".").map { Int($0) }
        guard !parsed.isEmpty, !parsed.contains(nil) else { return nil }
        var components = parsed.compactMap { $0 }
        while components.count < 3 { components.append(0) }
        let hostComponents = [host.majorVersion, host.minorVersion, host.patchVersion]
        for (guestPart, hostPart) in zip(components.prefix(3), hostComponents)
        where guestPart != hostPart {
            return guestPart < hostPart
        }
        return true
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
