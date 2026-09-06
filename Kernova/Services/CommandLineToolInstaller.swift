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
    /// Nothing is replaced except this installer's own leftovers: a file
    /// already there might be another tool, and a link might be one the user
    /// pointed somewhere on purpose. A link into a Kernova bundle that no
    /// longer exists — the app moved, or an older copy was deleted — is ours,
    /// and repointing it is the whole reason somebody clicked Install again.
    ///
    /// - Throws: ``InstallFailure``.
    static func installSymlink(at destination: URL) throws {
        let manager = FileManager.default
        let path = destination.path(percentEncoded: false)

        switch occupant(at: destination) {
        case .nothing:
            break
        case .staleKernovaLink:
            do {
                try manager.removeItem(at: destination)
            } catch {
                throw InstallFailure.unwritable(error.localizedDescription)
            }
        case .somethingElse:
            throw InstallFailure.exists
        }

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

    /// What is already at a destination.
    enum Occupant: Equatable {
        /// The path is free.
        case nothing
        /// A broken link this installer wrote for a bundle that has since moved.
        case staleKernovaLink
        /// Anything else, which is somebody's and is left alone.
        case somethingElse
    }

    /// What holds `destination`.
    ///
    /// `attributesOfItem` rather than `fileExists`, which follows symlinks: a
    /// dangling link reads as absent through the latter, so the create would
    /// fail `EEXIST` and be reported as a write problem instead of the stale
    /// link it is.
    static func occupant(at destination: URL) -> Occupant {
        let manager = FileManager.default
        let path = destination.path(percentEncoded: false)
        guard let attributes = try? manager.attributesOfItem(atPath: path) else { return .nothing }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
            return .somethingElse
        }
        guard let target = try? manager.destinationOfSymbolicLink(atPath: path) else {
            return .somethingElse
        }
        // Only a link this installer could have written, and only one whose
        // target is gone. A live link to another Kernova is that copy's, and a
        // link somewhere else entirely is the user's.
        guard target.hasSuffix("/Contents/Helpers/\(KernovaAppGroup.commandLineToolName)"),
            !manager.fileExists(atPath: target)
        else { return .somethingElse }
        return .staleKernovaLink
    }

    /// The command that does by hand what the panel does.
    static func manualCommand(for destination: URL) -> String {
        "ln -s \"\(bundledToolURL.path(percentEncoded: false))\" \"\(destination.path(percentEncoded: false))\""
    }

    private static let logger = Logger(
        subsystem: "app.kernova", category: "CommandLineToolInstaller")
}
