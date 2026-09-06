import Foundation
import KernovaKit
import os

/// Putting the bundled `kernova` tool somewhere a shell will find it.
///
/// A symlink rather than a copy: the tool and the app it talks to ship
/// together, so a copy would go stale the first time the app updated and would
/// then be refused by the protocol-version check instead of just working.
enum CommandLineToolInstaller {
    /// Where the tool lives inside the app bundle.
    ///
    /// `Contents/Helpers`, never `Contents/MacOS` — [BUILD.md](docs/BUILD.md)
    /// "The bundled `kernova` tool" says why.
    static var bundledToolURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(KernovaAppGroup.commandLineToolName, isDirectory: false)
    }

    /// Whether this build can offer the tool at all.
    ///
    /// It needs a group container to listen in and a bundled tool to point at.
    /// The container is the same condition the listener binds under, so the
    /// affordance and the capability cannot disagree: a build that would offer
    /// an Install button leading to a tool that can reach nothing offers none.
    static var isAvailable: Bool {
        KernovaAppGroup.containerURL() != nil
            && FileManager.default.fileExists(atPath: bundledToolURL.path(percentEncoded: false))
    }

    /// Why an install did not happen.
    enum InstallFailure: Error, Equatable {
        /// Something is already at the destination.
        case exists
        /// The destination cannot be written, grant or no grant.
        case unwritable(String)
    }

    /// Links `destination` to the bundled tool.
    ///
    /// - Throws: ``InstallFailure``. Nothing is replaced: a file already there
    ///   might be another tool, or a link the user pointed somewhere on purpose.
    static func installSymlink(at destination: URL) throws {
        let manager = FileManager.default
        let path = destination.path(percentEncoded: false)
        guard !manager.fileExists(atPath: path) else { throw InstallFailure.exists }
        do {
            try manager.createSymbolicLink(at: destination, withDestinationURL: bundledToolURL)
        } catch {
            Self.logger.error(
                "Could not install the command line tool at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw InstallFailure.unwritable(error.localizedDescription)
        }
        Self.logger.notice("Installed the command line tool at \(path, privacy: .public)")
    }

    /// The command that does by hand what the panel does.
    static func manualCommand(for destination: URL) -> String {
        "ln -s \"\(bundledToolURL.path(percentEncoded: false))\" \"\(destination.path(percentEncoded: false))\""
    }

    private static let logger = Logger(
        subsystem: "app.kernova", category: "CommandLineToolInstaller")
}
