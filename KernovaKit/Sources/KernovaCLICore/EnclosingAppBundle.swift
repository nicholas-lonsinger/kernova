import Foundation

/// The app bundle a helper executable is embedded in.
enum EnclosingAppBundle {
    /// The app bundle this copy of the tool is inside, or `nil` for a copy that
    /// is not inside one.
    static var current: URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        return locate(executable: executable)
    }

    /// The innermost ancestor directory whose name ends in `.app`, or `nil` when
    /// the executable is not inside one.
    ///
    /// Symlinks are resolved first, because the installed tool is one: Settings
    /// → Advanced puts a link in `/usr/local/bin`, and `Bundle.main.executableURL`
    /// answers the path it was invoked through rather than the file behind it.
    ///
    /// Ancestors only: an executable whose own name ends in `.app` is a file,
    /// not the bundle it would be launched as.
    static func locate(executable: URL) -> URL? {
        var candidate = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        while true {
            if candidate.pathExtension == "app" { return candidate }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { return nil }
            candidate = parent
        }
    }
}
