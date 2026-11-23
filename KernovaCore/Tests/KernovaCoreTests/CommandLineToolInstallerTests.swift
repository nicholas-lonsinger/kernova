import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Linking the bundled `kernova` tool somewhere a shell will find it.
@Suite("Command line tool installer", .caseScoped)
struct CommandLineToolInstallerTests {
    private let scratch = TestScratchDirectory(prefix: "knv-install")

    /// The installer of a copy at `This.app` in the scratch directory, which
    /// holds no tool until a test makes one.
    private var installer: CommandLineToolInstaller {
        CommandLineToolInstaller(appBundleURL: scratch.url.appendingPathComponent("This.app", isDirectory: true))
    }

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    @Test("Something already at the path is left alone")
    func installRefusesAnOccupiedPath() throws {
        let destination = scratch.url.appendingPathComponent("kernova")
        let existing = Data("someone else's tool".utf8)
        try existing.write(to: destination)

        #expect(throws: InstallFailure.exists) {
            try installer.installSymlink(at: destination)
        }
        // Untouched: replacing it could delete a tool the user relies on.
        #expect(try Data(contentsOf: destination) == existing)
    }

    @Test("A live link somewhere else is the user's, and is refused")
    func installRefusesAnExistingLink() throws {
        let destination = scratch.url.appendingPathComponent("kernova")
        try FileManager.default.createSymbolicLink(
            at: destination, withDestinationURL: URL(fileURLWithPath: "/usr/bin/env"))

        #expect(installer.occupant(at: destination) == .somethingElse)
        #expect(throws: InstallFailure.exists) {
            try installer.installSymlink(at: destination)
        }
    }

    @Test("A dangling link pointing anywhere else is left alone")
    func installRefusesADanglingForeignLink() throws {
        let destination = scratch.url.appendingPathComponent("kernova")
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: scratch.url.appendingPathComponent("some-other-tool"))

        #expect(installer.occupant(at: destination) == .somethingElse)
        #expect(throws: InstallFailure.exists) {
            try installer.installSymlink(at: destination)
        }
    }
}
