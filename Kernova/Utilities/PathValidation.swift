import Foundation
import KernovaLogging

/// Shared path validation for user-supplied file and directory paths.
///
/// Resolving symlinks is for host-side durability, not a Virtualization
/// requirement: VZ opens a disk image whose leaf *or* whose directory component
/// is a symlink and starts the VM (observed 2026-09-16, macOS 26A428). What
/// resolution buys is an attachment that no longer depends on a link the user
/// can retarget or delete while the VM runs. Under the App Sandbox the
/// container's `Downloads` is itself a symlink to the user's, so every path
/// picked there carries one.
enum PathValidation {
    /// The result of resolving a path through symlinks.
    struct ResolvedPath: Sendable {
        let url: URL
        let resolvedPath: String
        let originalPath: String

        var wasSymlink: Bool { resolvedPath != originalPath }

        /// Logs an info message when the path was a symlink, using the given context label.
        func logResolution(logger: KernovaLogger, context: String) {
            guard wasSymlink else { return }
            #log(
                logger, .info,
                "\(context, privacy: .public) path '\(originalPath, privacy: .public)' resolved to '\(resolvedPath, privacy: .public)'"
            )
        }
    }

    /// Reasons a path validation can fail.
    enum Failure: Error, Sendable {
        case notFound
        case unexpectedType
        case notReadable
        case notWritable
    }

    /// Resolves symlinks and validates that a regular file exists at the given path.
    ///
    /// Never throws `.notReadable`: readability is established only when
    /// Virtualization.framework opens the file, and any earlier check races that
    /// open.
    static func resolveFile(at path: String, requireWritable: Bool = false) throws(Failure) -> ResolvedPath {
        let resolved = resolve(path)
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: resolved.resolvedPath, isDirectory: &isDirectory) else {
            throw .notFound
        }
        guard !isDirectory.boolValue else {
            throw .unexpectedType
        }
        if requireWritable {
            guard fm.isWritableFile(atPath: resolved.resolvedPath) else {
                throw .notWritable
            }
        }
        return resolved
    }

    /// Resolves symlinks and validates that a directory exists at the given path.
    static func resolveDirectory(
        at path: String,
        requireReadable: Bool = false,
        requireWritable: Bool = false
    ) throws(Failure) -> ResolvedPath {
        let resolved = resolve(path)
        let fm = FileManager.default

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: resolved.resolvedPath, isDirectory: &isDirectory) else {
            throw .notFound
        }
        guard isDirectory.boolValue else {
            throw .unexpectedType
        }
        if requireReadable {
            guard fm.isReadableFile(atPath: resolved.resolvedPath) else {
                throw .notReadable
            }
        }
        if requireWritable {
            guard fm.isWritableFile(atPath: resolved.resolvedPath) else {
                throw .notWritable
            }
        }
        return resolved
    }

    private static func resolve(_ path: String) -> ResolvedPath {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return ResolvedPath(
            url: url,
            resolvedPath: url.path(percentEncoded: false),
            originalPath: path
        )
    }
}
