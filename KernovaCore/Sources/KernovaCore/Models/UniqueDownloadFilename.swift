import CryptoKit
import Foundation

/// A download destination filename unique to the URL the file came from.
///
/// Downloads is shared with everything else the user has ever fetched, so a
/// destination named from a remote URL alone can land on a file that is already
/// there and has nothing to do with this download. `DownloadService` treats a
/// completed file at the destination as the download, so a collision is not a
/// clash to resolve — it silently substitutes one image for another.
///
/// The digest covers the whole absolute URL, so two images differing only in
/// host or query land on different files, while one URL always resolves to the
/// same file and stays resumable across attempts.
enum UniqueDownloadFilename {
    /// Leading bytes of the URL digest a generated filename carries.
    private static let discriminatorBytes = 4

    /// Longest stem a generated filename keeps, so a hostile URL cannot push the
    /// name past the byte limit a path component has.
    private static let maximumStemLength = 64

    /// A filename unique to `url`, ending in `.<fileExtension>`.
    ///
    /// `defaultStem` names the file when `url`'s own last component yields no
    /// usable stem.
    static func make(for url: URL, fileExtension: String, defaultStem: String) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let discriminator =
            digest.prefix(discriminatorBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(stem(of: url.lastPathComponent) ?? defaultStem)-\(discriminator).\(fileExtension)"
    }

    /// The name the source gave a file ``make(for:fileExtension:defaultStem:)``
    /// named, or `nil` when `filename` carries no discriminator.
    ///
    /// The discriminator is a digest and cannot be inverted, so only the stem
    /// comes back — which is what says where the file came from. A stem long
    /// enough to have been truncated comes back truncated, so a source name
    /// past ``maximumStemLength`` is not recognized.
    static func sourceFilename(of filename: String, fileExtension: String) -> String? {
        guard let stem = stem(of: filename, requiring: fileExtension) else { return nil }
        // `-<discriminator>`, with at least one character of source name ahead
        // of it — a name that is nothing but a discriminator names no source.
        let suffixLength = discriminatorBytes * 2 + 1
        guard stem.count > suffixLength else { return nil }
        let source = stem.dropLast(suffixLength)
        let suffix = stem.dropFirst(source.count)
        guard suffix.first == "-",
            suffix.dropFirst().allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase })
        else { return nil }
        return "\(source).\(fileExtension)"
    }

    /// The part of `candidate` before a `.<fileExtension>` it must end in.
    private static func stem(of candidate: String, requiring fileExtension: String) -> String? {
        guard let name = SafeFilename.sanitized(candidate, requiring: fileExtension) else {
            return nil
        }
        return String(name.dropLast(fileExtension.count + 1))
    }

    /// The part of `candidate` before its extension, or `nil` when `candidate`
    /// is not usable as a filename at all.
    private static func stem(of candidate: String) -> String? {
        guard SafeFilename.isSingleComponent(candidate) else { return nil }
        var stem = candidate
        if let dot = stem.lastIndex(of: "."), dot != stem.startIndex {
            stem = String(stem[stem.startIndex..<dot])
        }
        guard !stem.isEmpty else { return nil }
        return String(stem.prefix(maximumStemLength))
    }
}
