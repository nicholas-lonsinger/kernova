import Foundation

/// Which file a URL names, as the volume holding it identifies the file.
///
/// Two spellings the volume folds together — a case variant on the default
/// case-insensitive APFS volume, a path through a link to a folder above the
/// file — name one file. A link at the end of a path is a file of its own.
package struct FileIdentity: Hashable {
    typealias Identifier = any NSCopying & NSSecureCoding & NSObjectProtocol

    /// The file's `URLResourceKey.fileResourceIdentifierKey` value — an
    /// opaque object, compared only with `isEqual(_:)`.
    let fileResourceIdentifier: Identifier

    #if DEBUG
    /// An identity no file backs, for a fake that folds files together as a
    /// volume does.
    init(fileResourceIdentifier: Identifier) {
        self.fileResourceIdentifier = fileResourceIdentifier
    }
    #endif

    /// The identity of the file at `url`, or `nil` when the volume reports
    /// none: nothing is there, or Kernova may not read it.
    init?(at url: URL) {
        // A fresh URL, because resource values are cached per URL instance and
        // a cached identifier would outlive a rename.
        let identifier = try? URL(filePath: url.path(percentEncoded: false))
            .resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        guard let identifier else { return nil }
        self.fileResourceIdentifier = identifier
    }

    package static func == (lhs: FileIdentity, rhs: FileIdentity) -> Bool {
        lhs.fileResourceIdentifier.isEqual(rhs.fileResourceIdentifier)
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(fileResourceIdentifier.hash)
    }

    /// A URL's path exactly as spelled — standardized and without a trailing
    /// separator, so a listing's directory URL and a derived one compare equal.
    /// Two spellings of one file differ here; identity is what equates them.
    package static func spelling(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
