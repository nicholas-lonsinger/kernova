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

    @Test("A link into this copy's own tool is its own, and is rewritten")
    func installRewritesThisCopysLink() throws {
        _ = try makeTool("This.app/Contents/Helpers/kernova", in: scratch.url)
        let destination = scratch.url.appendingPathComponent("kernova")
        try installer.installSymlink(at: destination)

        #expect(installer.occupant(at: destination) == .thisCopysLink)
        try installer.installSymlink(at: destination)

        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.path(percentEncoded: false))
        #expect(target == installer.bundledToolURL.path(percentEncoded: false))
    }

    @Test("Installing writes a link pointing at the bundled tool")
    func installWritesASymlink() throws {
        let destination = scratch.url.appendingPathComponent("kernova")

        try installer.installSymlink(at: destination)

        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.path(percentEncoded: false))
        #expect(target == installer.bundledToolURL.path(percentEncoded: false))
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

    @Test("A dangling link into a Kernova bundle is ours, and is repointed")
    func installReplacesAStaleKernovaLink() throws {
        let destination = scratch.url.appendingPathComponent("kernova")
        // The shape the installer writes, for an app that has since moved.
        let vanished =
            scratch.url
            .appendingPathComponent("Gone.app/Contents/Helpers/kernova")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: vanished)

        // `fileExists` follows the link and reports nothing there, which is the
        // trap: the create would fail EEXIST and read as a write problem.
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        #expect(installer.occupant(at: destination) == .staleKernovaLink)

        try installer.installSymlink(at: destination)

        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.path(percentEncoded: false))
        #expect(target == installer.bundledToolURL.path(percentEncoded: false))
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

    /// A tool at `relativePath` inside `directory`, as another copy of Kernova
    /// or anything else would carry it.
    private func makeTool(_ relativePath: String, in directory: URL) throws -> URL {
        let tool = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: tool)
        return tool
    }

    /// The tool drives the copy it links into, so a link into another copy is
    /// ours to point at this one.
    @Test("A live link into another Kernova names that copy, and is repointed")
    func installRepointsAnotherCopysLink() throws {
        let other = try makeTool("Other.app/Contents/Helpers/kernova", in: scratch.url)
        let destination = scratch.url.appendingPathComponent("kernova")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: other)

        guard
            case .anotherCopysLink(let app) = installer.occupant(at: destination)
        else {
            Issue.record("expected a link into another copy")
            return
        }
        #expect(app.path == scratch.url.appendingPathComponent("Other.app").path)

        try installer.installSymlink(at: destination)

        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.path(percentEncoded: false))
        #expect(target == installer.bundledToolURL.path(percentEncoded: false))
    }

    @Test("A relative link is read from its own folder")
    func relativeLinkIsReadFromItsFolder() throws {
        _ = try makeTool("Other.app/Contents/Helpers/kernova", in: scratch.url)
        let bin = scratch.url.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let destination = bin.appendingPathComponent("kernova")
        try FileManager.default.createSymbolicLink(
            atPath: destination.path(percentEncoded: false),
            withDestinationPath: "../Other.app/Contents/Helpers/kernova")

        guard
            case .anotherCopysLink(let app) = installer.occupant(at: destination)
        else {
            Issue.record("expected a link into another copy")
            return
        }
        #expect(app.path == scratch.url.appendingPathComponent("Other.app").path)
    }

    @Test("A live link into a kernova outside an app's Contents/Helpers is left alone")
    func installRefusesALinkOutsideAnAppBundle() throws {
        let loose = try makeTool("Tools/Contents/Helpers/kernova", in: scratch.url)
        let destination = scratch.url.appendingPathComponent("kernova")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: loose)

        #expect(installer.occupant(at: destination) == .somethingElse)
        #expect(throws: InstallFailure.exists) {
            try installer.installSymlink(at: destination)
        }
    }

    @Test("A free path holds nothing")
    func freePathHoldsNothing() throws {
        #expect(
            installer.occupant(at: scratch.url.appendingPathComponent("kernova"))
                == .nothing)
    }

    @Test("A path the app cannot write refuses, and says why")
    func installRefusesAnUnwritablePath() {
        // The system volume is read-only, and no grant makes it otherwise.
        let destination = URL(fileURLWithPath: "/System/kernova-should-not-exist")
        do {
            try installer.installSymlink(at: destination)
            Issue.record("expected the write to be refused")
            try? FileManager.default.removeItem(at: destination)
        } catch InstallFailure.unwritable(let detail) {
            #expect(!detail.isEmpty)
        } catch {
            Issue.record("expected an unwritable failure, got \(error)")
        }
    }

    @Test("A process whose signature claims no app group offers no tool, even with one bundled")
    func noContainerOffersNoTool() throws {
        // The test runner's signature claims no application group.
        try #require(KernovaAppGroup.containerURL() == nil)
        _ = try makeTool("This.app/Contents/Helpers/kernova", in: scratch.url)
        try #require(FileManager.default.fileExists(atPath: installer.bundledToolURL.path(percentEncoded: false)))

        #expect(!installer.isAvailable)
    }

    @Test("The tool is offered from Contents/Helpers, never from Contents/MacOS")
    func bundledToolLivesInHelpers() {
        let path = installer.bundledToolURL.path(percentEncoded: false)
        #expect(path.hasSuffix("/Contents/Helpers/kernova"))
        // A case-insensitive volume makes Contents/MacOS/kernova the app's own
        // executable — Config/Targets/KernovaCLI.xcconfig.
        #expect(!path.contains("/Contents/MacOS/"))
    }

    @Test("The manual command names both ends of the link the panel would have made")
    func manualCommandNamesBothEnds() {
        let destination = URL(fileURLWithPath: "/usr/local/bin/kernova")
        let command = installer.manualCommand(for: destination)
        #expect(command.hasPrefix("ln -s "))
        #expect(command.contains(installer.bundledToolURL.path(percentEncoded: false)))
        #expect(command.contains("/usr/local/bin/kernova"))
    }
}
