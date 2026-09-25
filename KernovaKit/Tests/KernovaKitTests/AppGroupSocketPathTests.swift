import Foundation
import KernovaTestSupport
import System
import Testing

@testable import KernovaCLICore
@testable import KernovaKit

/// Which command socket a copy of Kernova answers on: one per copy, named the
/// same way by the app and by the tool inside it, however either spells the
/// bundle's path.
@Suite("KernovaAppGroup socket path", .admissionGated)
struct AppGroupSocketPathTests {
    /// A signed build's group container under a 30-character account name.
    private static let container = URL(
        fileURLWithPath: "/Users/\(String(repeating: "a", count: 30))/Library/Group Containers/"
            + "8MT4P4GZL2.app.kernova",
        isDirectory: true)

    private func socketPath(_ bundle: URL) throws(KernovaAppGroup.CopyPathFailure) -> String {
        try KernovaAppGroup.CopyFiles(forAppBundle: bundle, in: Self.container).socketPath
    }

    /// A `Kernova.app` directory in `scratch`.
    private func makeBundle(in scratch: URL) throws -> URL {
        let bundle = scratch.appendingPathComponent("Kernova.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return bundle
    }

    @Test("A bundle reached through a symlink names the socket its resolved path names")
    func symlinkedBundleNamesTheResolvedSocket() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = try makeBundle(in: scratch)
        let link = scratch.appendingPathComponent("Linked.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)

        #expect(try socketPath(link) == socketPath(bundle))
    }

    /// APFS matches names without regard to case, so a path spelled in another
    /// case opens the same bundle.
    @Test("A bundle spelled in another case names the socket its on-disk spelling names")
    func differentlyCasedBundleNamesTheSameSocket() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = try makeBundle(in: scratch)
        let recased = scratch.appendingPathComponent("KERNOVA.app", isDirectory: true)

        #expect(try socketPath(recased) == socketPath(bundle))
    }

    @Test("A bundle spelled through the data volume's firmlink names the same socket")
    func firmlinkedBundleNamesTheSameSocket() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = try makeBundle(in: scratch)
        // The kernel's own spelling, since the data volume holds `private/var`
        // but not the root volume's `/var` link into it.
        let throughData = try URL(
            fileURLWithPath: "/System/Volumes/Data" + CanonicalPath.of(bundle), isDirectory: true)

        #expect(try socketPath(throughData) == socketPath(bundle))
    }

    @Test("Two copies of the app name two sockets")
    func distinctBundlesNameDistinctSockets() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let installed = try makeBundle(in: scratch.appendingPathComponent("Applications"))
        let built = try makeBundle(in: scratch.appendingPathComponent("Build/Products/Debug"))

        #expect(try socketPath(installed) != socketPath(built))
    }

    @Test("A bundle that is not there names no socket")
    func missingBundleNamesNoSocket() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let gone = scratch.appendingPathComponent("Kernova.app", isDirectory: true)

        #expect(throws: KernovaAppGroup.CopyPathFailure.unresolvableBundle(.noSuchFileOrDirectory)) {
            try socketPath(gone)
        }
    }

    @Test("The socket lives in the group container and fits sun_path under a long account name")
    func socketFitsSunPathInsideTheContainer() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let path = try socketPath(makeBundle(in: scratch))

        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().path == Self.container.path)
        #expect(throws: Never.self) { try UnixSocketAddress.make(path: path) }
    }

    @Test("A copy's lock file and its socket carry one digest name in the group container")
    func lockAndSocketShareOneDigest() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let files = try KernovaAppGroup.CopyFiles(
            forAppBundle: makeBundle(in: scratch), in: Self.container)
        let socket = URL(fileURLWithPath: files.socketPath)

        #expect(socket.pathExtension == "sock")
        #expect(files.lockURL.pathExtension == "lock")
        #expect(
            files.lockURL.deletingPathExtension().lastPathComponent
                == socket.deletingPathExtension().lastPathComponent)
        #expect(files.lockURL.deletingLastPathComponent().path == Self.container.path)
    }

    /// The app names its socket from `Bundle.main.bundleURL`, the tool from the
    /// bundle it finds itself inside — through the link Settings → Advanced
    /// installs — and the two must land on one path.
    @Test("The installed tool names the socket the app it links into binds")
    func installedToolNamesItsAppsSocket() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let installed = try InstalledToolFixture(in: scratch)

        let toolsApp = try #require(EnclosingAppBundle.locate(executable: installed.link))

        #expect(try socketPath(toolsApp) == socketPath(installed.bundle))
    }
}
