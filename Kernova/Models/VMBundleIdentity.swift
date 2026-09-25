import Foundation

/// Which bundle directory a URL names.
///
/// A bundle on disk is identified by its file identity, which the volume
/// decides: two spellings it folds together — a case-only rename on the
/// default case-insensitive APFS volume — are one bundle. A destination that
/// does not exist yet has no file identity, so it is matched by
/// ``nameKey(_:)`` instead, folded the way that volume folds names.
struct VMBundleIdentity: Hashable {
    typealias Identifier = any NSCopying & NSSecureCoding & NSObjectProtocol

    /// The directory's `URLResourceKey.fileResourceIdentifierKey` value — an
    /// opaque object, compared only with `isEqual(_:)`.
    let fileResourceIdentifier: Identifier

    init(fileResourceIdentifier: Identifier) {
        self.fileResourceIdentifier = fileResourceIdentifier
    }

    /// The identity of the bundle — a directory holding a configuration — on
    /// disk at `url`, or `nil` when none is there.
    init?(bundleAt url: URL) {
        guard
            FileManager.default.fileExists(
                atPath: VMBundleLayout(bundleURL: url).configURL.path(percentEncoded: false))
        else { return nil }
        // A fresh URL, because resource values are cached per URL instance and
        // a cached identifier would outlive a rename.
        let identifier = try? URL(filePath: url.path(percentEncoded: false), directoryHint: .isDirectory)
            .resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        guard let identifier else { return nil }
        self.fileResourceIdentifier = identifier
    }

    static func == (lhs: VMBundleIdentity, rhs: VMBundleIdentity) -> Bool {
        lhs.fileResourceIdentifier.isEqual(rhs.fileResourceIdentifier)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(fileResourceIdentifier.hash)
    }

    /// A URL's path as the default case- and normalization-insensitive APFS
    /// volume matches it: standardized, without a trailing separator, and
    /// folded.
    static func nameKey(_ url: URL) -> String {
        spelling(url).precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: nil)
    }

    /// A URL's path exactly as spelled — standardized and without a trailing
    /// separator, so a listing's directory URL and a derived one compare equal.
    /// Two spellings of one bundle differ here; identity is what equates them.
    static func spelling(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
