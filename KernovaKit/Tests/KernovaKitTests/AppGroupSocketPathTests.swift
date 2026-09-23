import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCLICore
@testable import KernovaKit

/// Which command socket a copy of Kernova answers on: one per copy, named the
/// same way by the app and by the tool inside it.
@Suite("KernovaAppGroup socket path", .admissionGated)
struct AppGroupSocketPathTests {
    /// A signed build's group container under a 30-character account name.
    private static let container = URL(
        fileURLWithPath: "/Users/\(String(repeating: "a", count: 30))/Library/Group Containers/"
            + "8MT4P4GZL2.app.kernova",
        isDirectory: true)

    private func socketPath(_ bundle: URL) -> String? {
        KernovaAppGroup.socketPath(forAppBundle: bundle, in: Self.container)
    }

    @Test("A bundle reached through a symlink names the socket its resolved path names")
    func symlinkedBundleNamesTheResolvedSocket() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = scratch.appendingPathComponent("Kernova.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let link = scratch.appendingPathComponent("Linked.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)

        let resolved = try #require(socketPath(bundle))

        #expect(socketPath(link) == resolved)
    }

    @Test("Two copies of the app name two sockets")
    func distinctBundlesNameDistinctSockets() throws {
        let installed = try #require(socketPath(URL(fileURLWithPath: "/Applications/Kernova.app")))
        let built = try #require(
            socketPath(
                URL(
                    fileURLWithPath:
                        "/Users/somebody/Library/Developer/Xcode/DerivedData/Kernova-abc/Build/"
                        + "Products/Debug/Kernova.app")))

        #expect(installed != built)
    }

    @Test("The socket lives in the group container and fits sun_path under a long account name")
    func socketFitsSunPathInsideTheContainer() throws {
        let path = try #require(socketPath(URL(fileURLWithPath: "/Applications/Kernova.app")))

        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().path == Self.container.path)
        #expect(throws: Never.self) { try UnixSocketAddress.make(path: path) }
    }

    /// The app names its socket from `Bundle.main.bundleURL`, the tool from the
    /// bundle it finds itself inside — through the link Settings → Advanced
    /// installs — and the two must land on one path.
    @Test("The installed tool names the socket the app it links into binds")
    func installedToolNamesItsAppsSocket() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let bundle = scratch.appendingPathComponent("Kernova.app", isDirectory: true)
        let helpers = bundle.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let binaries = scratch.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        let tool = helpers.appendingPathComponent("kernova")
        try Data().write(to: tool)
        let link = binaries.appendingPathComponent("kernova")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)

        let toolsApp = try #require(EnclosingAppBundle.locate(executable: link))

        #expect(socketPath(toolsApp) == socketPath(bundle))
    }

    /// A scratch directory under the temporary directory.
    private func makeScratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("knv-socket-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
