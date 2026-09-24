import Foundation

/// A directory under the temporary directory for one test to own and remove.
///
/// Symlinks resolved, so the `/var` → `/private/var` link is not what a path
/// comparison trips on.
func makeScratchDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .resolvingSymlinksInPath()
        .appendingPathComponent("knv-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The shape Settings → Advanced installs, built in a scratch directory: a
/// `Kernova.app` carrying the tool at `Contents/Helpers/kernova`, and a
/// `bin/kernova` link to it.
struct InstalledToolFixture {
    /// The app bundle the tool is inside.
    let bundle: URL
    /// The link a shell runs.
    let link: URL

    init(in scratch: URL) throws {
        let manager = FileManager.default
        bundle = scratch.appendingPathComponent("Kernova.app", isDirectory: true)
        let helpers = bundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let binaries = scratch.appendingPathComponent("bin", isDirectory: true)
        try manager.createDirectory(at: helpers, withIntermediateDirectories: true)
        try manager.createDirectory(at: binaries, withIntermediateDirectories: true)
        let tool = helpers.appendingPathComponent("kernova")
        try Data().write(to: tool)
        link = binaries.appendingPathComponent("kernova")
        try manager.createSymbolicLink(at: link, withDestinationURL: tool)
    }
}
