import Foundation

/// How the tool turns a typed path argument into one the app can act on.
public enum PathParsing {
    /// `path` as an absolute path, which is the only form the app can act on.
    ///
    /// Resolved against the shell's directory, which is `PWD` in the
    /// environment rather than the process's own: the tool is sandboxed, and a
    /// sandboxed process reads its working directory as its container
    /// (observed 2026-09-06, macOS 27 — a relative path crossed the wire under
    /// `~/Library/Containers/app.kernova.cli/Data`). Nothing on disk is
    /// consulted: the tool cannot read the file, so whether the path names
    /// anything is the app's question to answer.
    public static func wirePath(
        for path: String,
        workingDirectory: String? = ProcessInfo.processInfo.environment["PWD"]
    ) -> String {
        let base = workingDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path
    }
}
