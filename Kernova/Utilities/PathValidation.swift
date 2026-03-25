import Foundation
import os

/// Shared path validation for user-supplied file and directory paths.
///
/// Consolidates the resolve-symlinks → check-exists → check-type → check-permissions
/// pattern used by `ConfigurationBuilder` and `USBDeviceService`.
enum PathValidation {

    /// The result of resolving a path through symlinks.
    struct ResolvedPath: Sendable {
        let url: URL
        let resolvedPath: String
        let originalPath: String

        var wasSymlink: Bool { resolvedPath != originalPath }

        /// Logs an info message when the path was a symlink, using the given context label.
        func logResolution(logger: Logger, context: String) {
            guard wasSymlink else { return }
            logger.info("\(context, privacy: .public) path '\(originalPath, privacy: .public)' resolved to '\(resolvedPath, privacy: .public)'")
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
    // RATIONALE: No `requireReadable` parameter for files. A pre-flight readability
    // check adds little value since the authoritative test occurs when
    // Virtualization.framework opens the file, and a TOCTOU race could invalidate
    // any earlier check. The writable check is retained because "not writable" is a
    // common, actionable user misconfiguration worth surfacing early. Callers must
    // still handle `.notReadable` in their switch for exhaustiveness, but this method
    // never throws it.
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
