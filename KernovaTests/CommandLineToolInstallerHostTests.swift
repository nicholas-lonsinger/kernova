import Foundation
import Testing

@testable import KernovaCore

/// The installer over the tool a built Kernova.app carries, which only the app
/// as host has.
@Suite("Command line tool installer, in the app", .caseScoped)
struct CommandLineToolInstallerHostTests {
    private let scratch = TestScratchDirectory(prefix: "knv-install")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    @Test("A link into this copy's own tool is its own, and is rewritten")
    func installRewritesThisCopysLink() throws {
        let destination = scratch.url.appendingPathComponent("kernova")
        // The test host is a built Kernova.app, which carries the tool.
        try #require(
            FileManager.default.fileExists(
                atPath: CommandLineToolInstaller.bundledToolURL.path(percentEncoded: false)))
        try CommandLineToolInstaller.installSymlink(at: destination)

        #expect(CommandLineToolInstaller.occupant(at: destination) == .thisCopysLink)
        try CommandLineToolInstaller.installSymlink(at: destination)

        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.path(percentEncoded: false))
        #expect(target == CommandLineToolInstaller.bundledToolURL.path(percentEncoded: false))
    }
}
