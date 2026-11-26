import Foundation

/// Which bundle directory a URL names.
///
/// A bundle on disk is identified by its ``FileIdentity``, so two spellings
/// the volume folds together — a case-only rename on the default
/// case-insensitive APFS volume — are one bundle. A destination that does not
/// exist yet has no file identity, so it is matched by ``nameKey(_:)``
/// instead, folded the way that volume folds names.
package struct VMBundleIdentity: Hashable {
    let file: FileIdentity

    #if DEBUG
    /// An identity no directory backs, for a storage fake that folds bundles
    /// together as a volume does.
    init(fileResourceIdentifier: FileIdentity.Identifier) {
        file = FileIdentity(fileResourceIdentifier: fileResourceIdentifier)
    }
    #endif

    /// The identity of the bundle — a directory holding a configuration — on
    /// disk at `url`, or `nil` when none is there.
    init?(bundleAt url: URL) {
        guard
            FileManager.default.fileExists(
                atPath: VMBundleLayout(bundleURL: url).configURL.path(percentEncoded: false)),
            let file = FileIdentity(at: url)
        else { return nil }
        self.file = file
    }

    /// A URL's path as the default case- and normalization-insensitive APFS
    /// volume matches it: its ``FileIdentity/spelling(_:)``, folded.
    static func nameKey(_ url: URL) -> String {
        FileIdentity.spelling(url).precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: nil)
    }
}
