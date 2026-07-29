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
    /// `URL.lastPathComponent` percent-decodes, so a URL ending in
    /// `a%2F..%2F..%2Fevil.ipsw` hands back `a/../../evil.ipsw` — a value that
    /// walks out of whatever directory it is appended to. Anything empty,
    /// hidden (`.` and `..` included), carrying a separator, or not naming an
    /// `.ipsw` is refused.
    static func sanitized(_ candidate: String) -> String? {
        guard candidate.lowercased().hasSuffix(".ipsw"), isSingleComponent(candidate) else {
            return nil
        }
        return candidate
    }

    /// A destination filename unique to `url`.
    ///
    /// The digest covers the whole absolute URL, so two images differing only in
    /// host or query land on different files, while one URL always resolves to
    /// the same file and stays resumable across attempts.
    static func unique(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let discriminator =
            digest.prefix(discriminatorBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(stem(of: url.lastPathComponent) ?? defaultStem)-\(discriminator).ipsw"
    }

    /// Stem of a generated filename when the URL's own last component yields none.
    private static let defaultStem = "RestoreImage"

    /// Leading bytes of the URL digest a generated filename carries.
    private static let discriminatorBytes = 4

    /// Longest stem a generated filename keeps, so a hostile URL cannot push the
    /// name past the byte limit a path component has.
    private static let maximumStemLength = 64

    /// Whether `candidate` is one visible path component.
    private static func isSingleComponent(_ candidate: String) -> Bool {
        // `.` and `..` fall out of the leading-dot refusal.
        guard !candidate.isEmpty, !candidate.hasPrefix(".") else { return false }
        let decoded = candidate.removingPercentEncoding ?? candidate
        return !candidate.contains(where: isSeparator)
            && !decoded.contains(where: isSeparator)
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character == "/" || character == "\0"
    }

    /// The part of `candidate` before its extension, or `nil` when `candidate`
    /// is not usable as a filename at all.
    private static func stem(of candidate: String) -> String? {
        guard isSingleComponent(candidate) else { return nil }
        var stem = candidate
        if let dot = stem.lastIndex(of: "."), dot != stem.startIndex {
            stem = String(stem[stem.startIndex..<dot])
        }
        guard !stem.isEmpty else { return nil }
        return String(stem.prefix(maximumStemLength))
    }
}

/// A macOS marketing version, parsed for comparison against a host.
struct MacOSVersion: Sendable, Equatable {
    /// Numeric components, zero-padded to three.
    let components: [Int]

    /// `version` rendered the way Apple names a release: a zero patch is left
    /// off, so `26.6.0` reads as `"26.6"` and matches the catalog's own strings.
    static func displayString(_ version: OperatingSystemVersion) -> String {
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion == 0 ? base : "\(base).\(version.patchVersion)"
    }

    /// `nil` when `version` is not a dot-separated run of numbers.
    init?(_ version: String) {
        let parsed = version.split(separator: ".").map { Int($0) }
        guard !parsed.isEmpty, !parsed.contains(nil) else { return nil }
        var components = parsed.compactMap { $0 }
        while components.count < 3 { components.append(0) }
        self.components = Array(components.prefix(3))
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
