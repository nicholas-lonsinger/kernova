import Foundation

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
}
