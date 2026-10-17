import Foundation
import KernovaLogging

/// The path validation a configuration's attachments pass on their way into a
/// build: each user-supplied path resolved (symlinks followed) and checked,
/// with a failure mapped to the ``ConfigurationBuilderError`` naming it.
package enum ConfigurationPaths {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "ConfigurationBuilder")

    /// Validates one shared directory at `path` — by default its own — and
    /// returns the resolved URL (symlinks followed); a failure names
    /// `directory`'s entry, as the Sharing pane lists it.
    package static func resolveSharedDirectory(
        _ directory: SharedDirectory, at path: String? = nil
    ) throws -> URL {
        let path = path ?? directory.path
        let (id, label) = (directory.id, directory.displayName)
        return try resolveDirectory(
            at: path, context: "Shared directory",
            requireReadable: true, requireWritable: !directory.readOnly,
            notFound: .sharedDirectoryNotFound(id: id, path: path, label: label),
            notADirectory: .sharedDirectoryNotADirectory(id: id, path: path, label: label),
            notReadable: .sharedDirectoryNotReadable(id: id, path: path, label: label),
            notWritable: .sharedDirectoryNotWritable(id: id, path: path, label: label)
        ).url
    }

    /// Resolves and validates a file path, mapping `PathValidation.Failure` to `ConfigurationBuilderError`.
    package static func resolveFile(
        at path: String,
        context: String,
        requireWritable: Bool = false,
        notFound: ConfigurationBuilderError,
        isDirectory: ConfigurationBuilderError,
        notWritable: ConfigurationBuilderError? = nil
    ) throws -> PathValidation.ResolvedPath {
        do {
            let resolved = try PathValidation.resolveFile(at: path, requireWritable: requireWritable)
            resolved.logResolution(logger: logger, context: context)
            return resolved
        } catch {
            switch error {
            case .notFound:
                #log(logger, .error, "\(context, privacy: .public) not found at '\(path, privacy: .private)'")
                throw notFound
            case .unexpectedType:
                #log(logger, .error, "\(context, privacy: .public) path is a directory: '\(path, privacy: .private)'")
                throw isDirectory
            case .notWritable:
                #log(logger, .error, "\(context, privacy: .public) is not writable: '\(path, privacy: .private)'")
                guard let notWritableError = notWritable else {
                    #log(
                        logger, .fault,
                        "resolveFile called with requireWritable but no notWritable error for '\(path, privacy: .private)'"
                    )
                    assertionFailure("'notWritable' error must be provided when 'requireWritable' is true")
                    throw notFound
                }
                throw notWritableError
            case .notReadable:
                #log(logger, .fault, "Unexpected .notReadable from resolveFile for '\(path, privacy: .private)'")
                assertionFailure("resolveFile should never throw .notReadable")
                throw notFound
            }
        }
    }

    /// Resolves and validates a directory path, mapping `PathValidation.Failure` to `ConfigurationBuilderError`.
    static func resolveDirectory(
        at path: String,
        context: String,
        requireReadable: Bool = false,
        requireWritable: Bool = false,
        notFound: ConfigurationBuilderError,
        notADirectory: ConfigurationBuilderError,
        notReadable: ConfigurationBuilderError? = nil,
        notWritable: ConfigurationBuilderError? = nil
    ) throws -> PathValidation.ResolvedPath {
        do {
            let resolved = try PathValidation.resolveDirectory(
                at: path, requireReadable: requireReadable, requireWritable: requireWritable)
            resolved.logResolution(logger: logger, context: context)
            return resolved
        } catch {
            switch error {
            case .notFound:
                #log(logger, .error, "\(context, privacy: .public) not found at '\(path, privacy: .private)'")
                throw notFound
            case .unexpectedType:
                #log(
                    logger, .error, "\(context, privacy: .public) path is not a directory: '\(path, privacy: .private)'"
                )
                throw notADirectory
            case .notReadable:
                #log(logger, .error, "\(context, privacy: .public) is not readable: '\(path, privacy: .private)'")
                guard let notReadableError = notReadable else {
                    #log(
                        logger, .fault,
                        "resolveDirectory called with requireReadable but no notReadable error for '\(path, privacy: .private)'"
                    )
                    assertionFailure("'notReadable' error must be provided when 'requireReadable' is true")
                    throw notFound
                }
                throw notReadableError
            case .notWritable:
                #log(logger, .error, "\(context, privacy: .public) is not writable: '\(path, privacy: .private)'")
                guard let notWritableError = notWritable else {
                    #log(
                        logger, .fault,
                        "resolveDirectory called with requireWritable but no notWritable error for '\(path, privacy: .private)'"
                    )
                    assertionFailure("'notWritable' error must be provided when 'requireWritable' is true")
                    throw notFound
                }
                throw notWritableError
            }
        }
    }
}
