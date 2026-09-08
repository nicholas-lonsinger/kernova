import Foundation

/// The home directory the user sees, which under the App Sandbox is not the
/// one the process has.
///
/// `FileManager.homeDirectoryForCurrentUser` answers the container; anything
/// naming a path *for the user* — a folder to abbreviate with `~`, a place a
/// shell looks for its own files — has to name the real one.
enum UserHome {
    /// The real home directory's path.
    ///
    /// Falls back to the process home when the account database will not say,
    /// which is the same answer as having asked for the container directly.
    static var path: String {
        guard let directory = getpwuid(getuid())?.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        }
        return String(cString: directory)
    }

    /// The real home directory.
    static var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}
