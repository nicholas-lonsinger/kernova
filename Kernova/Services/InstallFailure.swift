import Foundation

/// Why writing something into a folder the user picked did not happen.
///
/// One type for both installs the Advanced pane offers — the symlink to the
/// tool and a shell's completion file — because a caller does the same two
/// things with either: say what stopped it, and keep the equivalent command on
/// screen.
enum InstallFailure: Error, Equatable {
    /// Something is already at the destination, and it is not this app's.
    case exists
    /// The destination cannot be written, grant or no grant.
    case unwritable(String)
}
