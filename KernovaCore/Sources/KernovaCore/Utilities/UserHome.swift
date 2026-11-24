import Foundation
import KernovaCommandModel

/// The home directory the user sees, which under the App Sandbox is not the
/// one the process has.
///
/// `FileManager.homeDirectoryForCurrentUser` answers the container; anything
/// naming a path *for the user* — a folder to abbreviate with `~`, a place a
/// shell looks for its own files — has to name the real one.
package enum UserHome {
    /// The real home directory's path, with no trailing separator.
    ///
    /// Falls back to the process home when the account database will not say,
    /// which is the same answer as having asked for the container directly.
    package static var path: String {
        let path =
            (getpwuid(getuid())?.pointee.pw_dir).map { String(cString: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        // A directory URL's path ends in a separator; the account database's
        // does not.
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    /// The real home directory.
    static var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    /// `path` as a full path, a leading `~` read as the real home directory,
    /// for a door whose client names a path with no working directory to read
    /// a relative one against: a shortcut, a script.
    ///
    /// - Throws: ``CommandError/invalidArgument(_:)`` for any other path that
    ///   does not start at `/`, worded for `item`, what the path names.
    package static func fullPath(_ path: String, of item: String) throws -> String {
        if path == "~" { return Self.path }
        if path.hasPrefix("~/") { return Self.path + path.dropFirst() }
        guard path.hasPrefix("/") else {
            throw CommandError.invalidArgument(
                "\(item) is named by its full path, which starts with \u{201C}/\u{201D} or \u{201C}~/\u{201D}.")
        }
        return path
    }
}
