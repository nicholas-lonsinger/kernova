import Foundation
import KernovaKit
import KernovaLogging

/// Putting the bundled `kernova` tool somewhere a shell will find it.
///
/// A symlink rather than a copy: the tool and the app it talks to ship
/// together, so a copy would go stale the first time the app updated and would
/// then be refused by the protocol-version check instead of just working.
enum CommandLineToolInstaller {
    /// Where the tool lives inside the app bundle.
    ///
    /// `Contents/Helpers`, never `Contents/MacOS` —
    /// `Config/Targets/KernovaCLI.xcconfig` says why.
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

    /// Links `destination` to the bundled tool.
    ///
    /// Nothing is replaced but a link into a Kernova bundle's tool, which is
    /// ours whichever copy it names: a file already there might be another
    /// tool, and any other link might be one the user pointed somewhere on
    /// purpose. The tool drives the copy it links into, so pointing the link
    /// here is the whole reason somebody clicked Install in this copy.
    ///
    /// - Throws: ``InstallFailure``.
    static func installSymlink(at destination: URL) throws {
        let manager = FileManager.default
        let path = destination.path(percentEncoded: false)

        switch occupant(at: destination) {
        case .nothing:
            break
        case .staleKernovaLink, .thisCopysLink, .anotherCopysLink:
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
            #log(
                Self.logger, .error,
                "Could not install the command line tool at \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw InstallFailure.unwritable(error.localizedDescription)
        }
        #log(Self.logger, .notice, "Installed the command line tool at \(path, privacy: .public)")
    }

    /// What is already at a destination.
    enum Occupant: Equatable {
        /// The path is free.
        case nothing
        /// A link into a Kernova bundle that is gone — the app moved, or that
        /// copy was deleted.
        case staleKernovaLink
        /// A link into this copy's own tool.
        case thisCopysLink
        /// A link into the tool of the copy of Kernova at `app`, which is the
        /// copy a shell running it drives.
        case anotherCopysLink(app: URL)
        /// Anything else, which is somebody's and is left alone.
        case somethingElse
    }

    /// What holds `destination`.
    ///
    /// A Kernova link is one in the shape this installer writes, into
    /// `<name>.app/Contents/Helpers/kernova`.
    ///
    /// `attributesOfItem` rather than `fileExists`, which follows symlinks: a
    /// dangling link reads as absent through the latter, so the create would
    /// fail `EEXIST` and be reported as a write problem instead of the stale
    /// link it is.
    static func occupant(at destination: URL) -> Occupant {
        let manager = FileManager.default
        let path = destination.path(percentEncoded: false)
        guard let attributes = try? manager.attributesOfItem(atPath: path) else { return .nothing }
        guard attributes[.type] as? FileAttributeType == .typeSymbolicLink,
            let written = try? manager.destinationOfSymbolicLink(atPath: path)
        else { return .somethingElse }

        // A relative target is followed from the link's own folder.
        let tool = URL(
            fileURLWithPath: written, relativeTo: destination.deletingLastPathComponent()
        ).standardizedFileURL
        let helpers = tool.deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard tool.lastPathComponent == KernovaAppGroup.commandLineToolName,
            helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents",
            app.pathExtension == "app"
        else { return .somethingElse }

        guard manager.fileExists(atPath: tool.path(percentEncoded: false)) else {
            return .staleKernovaLink
        }
        return isThisCopy(app) ? .thisCopysLink : .anotherCopysLink(app: app)
    }

    /// Whether `app` is the bundle this process runs from, however either path
    /// is spelled.
    ///
    /// A bundle that cannot be looked up is not this one: at worst, a link
    /// into this copy is treated as another copy's, whose repointing the user
    /// is asked about.
    private static func isThisCopy(_ app: URL) -> Bool {
        guard let linked = try? CanonicalPath.of(app),
            let running = try? CanonicalPath.of(Bundle.main.bundleURL)
        else { return false }
        return linked == running
    }

    /// The command that does by hand what the panel does.
    static func manualCommand(for destination: URL) -> String {
        "ln -s \"\(bundledToolURL.path(percentEncoded: false))\" \"\(destination.path(percentEncoded: false))\""
    }

    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "CommandLineToolInstaller")
}
