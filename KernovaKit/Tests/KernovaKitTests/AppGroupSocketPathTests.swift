import Foundation
import KernovaTestSupport
import System
import Testing

@testable import KernovaCLICore
@testable import KernovaKit

/// Which command socket a copy of Kernova answers on: one per copy, named the
/// same way by the app and by the tool inside it, however either spells the
/// bundle's path.
@Suite("KernovaAppGroup socket path", .caseScoped)
struct AppGroupSocketPathTests {
    /// A signed build's group container under a 30-character account name.
    private static let container = URL(
        fileURLWithPath: "/Users/\(String(repeating: "a", count: 30))/Library/Group Containers/"
            + "8MT4P4GZL2.app.kernova",
        isDirectory: true)

    private let scratch = TestScratchDirectory(prefix: "AppGroupSocketPathTests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    private func socketPath(_ bundle: URL) throws(KernovaAppGroup.CopyPathFailure) -> String {
        try KernovaAppGroup.CopyFiles(forAppBundle: bundle, in: Self.container).socketPath
    }

    /// A `Kernova.app` directory in `directory`.
    private func makeBundle(in directory: URL) throws -> URL {
        let bundle = directory.appendingPathComponent("Kernova.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return bundle
    }

    @Test("A bundle reached through a symlink names the socket its resolved path names")
    func symlinkedBundleNamesTheResolvedSocket() throws {
        let bundle = try makeBundle(in: scratch.url)
        let link = scratch.url.appendingPathComponent("Linked.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)

        #expect(try socketPath(link) == socketPath(bundle))
    }

    /// APFS matches names without regard to case, so a path spelled in another
    /// case opens the same bundle.
    @Test("A bundle spelled in another case names the socket its on-disk spelling names")
    func differentlyCasedBundleNamesTheSameSocket() throws {
        let bundle = try makeBundle(in: scratch.url)
        let recased = scratch.url.appendingPathComponent("KERNOVA.app", isDirectory: true)

        #expect(try socketPath(recased) == socketPath(bundle))
    }

    @Test("A bundle spelled through the data volume's firmlink names the same socket")
    func firmlinkedBundleNamesTheSameSocket() throws {
        let bundle = try makeBundle(in: scratch.url)
        // The kernel's own spelling, since the data volume holds `private/var`
        // but not the root volume's `/var` link into it.
        let throughData = try URL(
            fileURLWithPath: "/System/Volumes/Data" + CanonicalPath.of(bundle), isDirectory: true)

        #expect(try socketPath(throughData) == socketPath(bundle))
    }

    @Test("Two copies of the app name two sockets")
    func distinctBundlesNameDistinctSockets() throws {
        let installed = try makeBundle(in: scratch.url.appendingPathComponent("Applications"))
        let built = try makeBundle(in: scratch.url.appendingPathComponent("Build/Products/Debug"))

        #expect(try socketPath(installed) != socketPath(built))
    }

    @Test("A bundle that is not there names no socket")
    func missingBundleNamesNoSocket() throws {
        let gone = scratch.url.appendingPathComponent("Kernova.app", isDirectory: true)

        #expect(throws: KernovaAppGroup.CopyPathFailure.unresolvableBundle(.noSuchFileOrDirectory)) {
            try socketPath(gone)
        }
    }

    @Test("The socket lives in the group container and fits sun_path under a long account name")
    func socketFitsSunPathInsideTheContainer() throws {
        let path = try socketPath(makeBundle(in: scratch.url))

        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().path == Self.container.path)
        #expect(throws: Never.self) { try UnixSocketAddress.make(path: path) }
    }

    @Test("A copy's lock file and its socket carry one digest name in the group container")
    func lockAndSocketShareOneDigest() throws {
        let files = try KernovaAppGroup.CopyFiles(
            forAppBundle: makeBundle(in: scratch.url), in: Self.container)
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
        let installed = try InstalledToolFixture(in: scratch.url)

        let toolsApp = try #require(EnclosingAppBundle.locate(executable: installed.link))

        #expect(try socketPath(toolsApp) == socketPath(installed.bundle))
    }
}
