import CryptoKit
import Foundation

/// Turns a restore image's URL into the filename its download lands on.
///
/// Every source — the bundled catalog, a pasted URL, a persisted install
/// context — resolves its destination here, so no filename a remote server or a
/// hand-edited `config.json` controls reaches the filesystem unchecked.
enum RestoreImageFilename {
    /// The download destination's filename for the image at `url`.
    ///
    /// Apple's `UniversalMac_<version>_<build>_Restore.ipsw` convention passes
    /// through, because the build in such a name is the image's identity: two
    /// picks of one build share a destination. Any other URL gets a name unique
    /// to it, since a shared name lets an unrelated image already on disk
    /// satisfy the download and install in place of the one chosen.
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
