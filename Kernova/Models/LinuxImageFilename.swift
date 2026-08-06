import Foundation

/// Turns a Linux installer image's URL into the filename its download lands on.
///
/// Every source — a catalog entry resolved against its mirror's manifest, a URL
/// the user pasted — names its destination here, so no name a mirror or a
/// hand-edited `config.json` chose reaches the filesystem.
enum LinuxImageFilename {
    /// The download destination's filename for the ISO at `url`.
    ///
    /// Always unique to `url`, never the name the source gave the file.
    /// Downloads holds everything the user has ever fetched and `DownloadService`
    /// adopts a completed file at the destination as the download, so a
    /// source-chosen name can land on a file the user already has — installed in
    /// place of the image chosen when nothing is verified, and trashed for
    /// failing a digest that was never its own when something is.
    static func destination(for url: URL) -> String {
        UniqueDownloadFilename.make(
            for: url, fileExtension: "iso", defaultStem: defaultStem)
    }

    /// The name the source gave the ISO this app downloaded to `filename`, or
    /// `nil` when `filename` is not one ``destination(for:)`` produced.
    ///
    /// What a file in Downloads answers about where it came from: only a name
    /// carrying a discriminator is one of this app's downloads, and only such a
    /// file is what a later download would find and adopt.
    static func sourceFilename(of filename: String) -> String? {
        UniqueDownloadFilename.sourceFilename(of: filename, fileExtension: "iso")
    }

    /// Stem of a generated filename when the URL's own last component yields none.
    private static let defaultStem = "LinuxImage"
}
