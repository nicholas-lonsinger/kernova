import CryptoKit
import Foundation

/// Turns a restore image's URL into the filename its download lands on.
///
/// Every source — the bundled catalog, a pasted URL, a persisted install
/// context — resolves its destination here, so no filename a remote server or a
/// hand-edited `config.json` controls reaches the filesystem unchecked.
enum RestoreImageFilename {
    /// The destination filename for an image whose URL names none.
    static let fallback = "\(defaultStem).ipsw"

    /// The download destination's filename for the image at `url`.
    ///
    /// Apple's `UniversalMac_<version>_<build>_Restore.ipsw` convention passes
    /// through, because the build in such a name is the image's identity: two
    /// picks of one build share a destination on purpose. Any other URL gets a
    /// name unique to it, since a shared name lets an unrelated image already on
    /// disk satisfy the download and install in place of the one chosen.
    static func destination(for url: URL) -> String {
        guard let sanitized = sanitized(url.lastPathComponent),
            ProbedRestoreImage.parseFilename(sanitized).build != nil
        else { return unique(for: url) }
        return sanitized
    }

    /// `candidate` when it is a filename safe to append to a directory, `nil`
    /// when the caller must generate one instead.
    ///
    /// A restore image is an `.ipsw`; ``SafeFilename`` owns what makes a name
    /// safe to append at all.
    static func sanitized(_ candidate: String) -> String? {
        SafeFilename.sanitized(candidate, requiring: "ipsw")
    }

    /// A destination filename unique to `url`.
    static func unique(for url: URL) -> String {
        UniqueDownloadFilename.make(
            for: url, fileExtension: "ipsw", defaultStem: defaultStem)
    }

    /// Stem of a generated filename when the URL's own last component yields none.
    private static let defaultStem = "RestoreImage"
}

/// A macOS marketing version, parsed for comparison against a host.
struct MacOSVersion: Sendable, Equatable {
    /// Numeric components, zero-padded to three.
    let components: [Int]

    /// `nil` when `version` is not a dot-separated run of numbers.
    init?(_ version: String) {
        let parsed = version.split(separator: ".").map { Int($0) }
        guard !parsed.isEmpty, !parsed.contains(nil) else { return nil }
        var components = parsed.compactMap { $0 }
        while components.count < 3 { components.append(0) }
        self.components = Array(components.prefix(3))
    }

    /// A version fixed at compile time, for thresholds no string has to parse
    /// into.
    init(major: Int, minor: Int, patch: Int = 0) {
        components = [major, minor, patch]
    }

    /// Whether this version is `other` or newer, compared component by component
    /// as numbers — so 12.10 outranks 12.3, which comparing the text does not.
    func isAtLeast(_ other: MacOSVersion) -> Bool {
        for (mine, theirs) in zip(components, other.components) where mine != theirs {
            return mine > theirs
        }
        return true
    }

    /// Whether a guest at this version can run on the given host.
    ///
    /// Virtualization refuses a guest newer than the host, and the framework's
    /// own answer is only available after the image is downloaded — it comes
    /// from `VZMacOSRestoreImage.loadFileURL`, which takes a local file.
    func isSupported(onHost host: OperatingSystemVersion) -> Bool {
        let hostComponents = [host.majorVersion, host.minorVersion, host.patchVersion]
        for (guestPart, hostPart) in zip(components, hostComponents) where guestPart != hostPart {
            return guestPart < hostPart
        }
        return true
    }
}
