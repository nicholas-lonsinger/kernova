import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Linking the bundled `kernova` tool somewhere a shell will find it.
@Suite("Command line tool installer", .admissionGated)
struct CommandLineToolInstallerTests {
    /// A fresh directory the test owns, removed when it ends.
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("knv-install-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Installing writes a link pointing at the bundled tool")
    func installWritesASymlink() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("kernova")

        try CommandLineToolInstaller.installSymlink(at: destination)

        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.path(percentEncoded: false))
        #expect(target == CommandLineToolInstaller.bundledToolURL.path(percentEncoded: false))
    }

    @Test("A link is written, never a copy — so an app update carries the tool with it")
    func installWritesALinkNotACopy() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("kernova")

        try CommandLineToolInstaller.installSymlink(at: destination)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: destination.path(percentEncoded: false))
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test("Something already at the path is left alone")
    func installRefusesAnOccupiedPath() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("kernova")
        let existing = Data("someone else's tool".utf8)
        try existing.write(to: destination)

        #expect(throws: InstallFailure.exists) {
            try CommandLineToolInstaller.installSymlink(at: destination)
        }
        // Untouched: replacing it could delete a tool the user relies on.
        #expect(try Data(contentsOf: destination) == existing)
    }

    @Test("A live link somewhere else is the user's, and is refused")
    func installRefusesAnExistingLink() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("kernova")
        try FileManager.default.createSymbolicLink(
            at: destination, withDestinationURL: URL(fileURLWithPath: "/usr/bin/env"))

        #expect(CommandLineToolInstaller.occupant(at: destination) == .somethingElse)
        #expect(throws: InstallFailure.exists) {
            try CommandLineToolInstaller.installSymlink(at: destination)
        }
    }

    @Test("A dangling link into a Kernova bundle is ours, and is repointed")
    func installReplacesAStaleKernovaLink() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("kernova")
        // The shape the installer writes, for an app that has since moved.
        let vanished =
            directory
            .appendingPathComponent("Gone.app/Contents/Helpers/kernova")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: vanished)

        // `fileExists` follows the link and reports nothing there, which is the
        // trap: the create would fail EEXIST and read as a write problem.
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        #expect(CommandLineToolInstaller.occupant(at: destination) == .staleKernovaLink)

        try CommandLineToolInstaller.installSymlink(at: destination)

        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.path(percentEncoded: false))
        #expect(target == CommandLineToolInstaller.bundledToolURL.path(percentEncoded: false))
    }

    @Test("A dangling link pointing anywhere else is left alone")
    func installRefusesADanglingForeignLink() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("kernova")
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: directory.appendingPathComponent("some-other-tool"))

        #expect(CommandLineToolInstaller.occupant(at: destination) == .somethingElse)
        #expect(throws: InstallFailure.exists) {
            try CommandLineToolInstaller.installSymlink(at: destination)
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
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = try makeTool("Other.app/Contents/Helpers/kernova", in: directory)
        let destination = directory.appendingPathComponent("kernova")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: other)

        guard
            case .anotherCopysLink(let app) = CommandLineToolInstaller.occupant(at: destination)
        else {
            Issue.record("expected a link into another copy")
            return
        }
        #expect(app.path == directory.appendingPathComponent("Other.app").path)

        try CommandLineToolInstaller.installSymlink(at: destination)

        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.path(percentEncoded: false))
        #expect(target == CommandLineToolInstaller.bundledToolURL.path(percentEncoded: false))
    }

    @Test("A relative link is read from its own folder")
    func relativeLinkIsReadFromItsFolder() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try makeTool("Other.app/Contents/Helpers/kernova", in: directory)
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let destination = bin.appendingPathComponent("kernova")
        try FileManager.default.createSymbolicLink(
            atPath: destination.path(percentEncoded: false),
            withDestinationPath: "../Other.app/Contents/Helpers/kernova")

        guard
            case .anotherCopysLink(let app) = CommandLineToolInstaller.occupant(at: destination)
        else {
            Issue.record("expected a link into another copy")
            return
        }
        #expect(app.path == directory.appendingPathComponent("Other.app").path)
    }

    @Test("A link into this copy's own tool is its own, and is rewritten")
    func installRewritesThisCopysLink() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("kernova")
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

    @Test("A live link into a kernova outside an app's Contents/Helpers is left alone")
    func installRefusesALinkOutsideAnAppBundle() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let loose = try makeTool("Tools/Contents/Helpers/kernova", in: directory)
        let destination = directory.appendingPathComponent("kernova")
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: loose)

        #expect(CommandLineToolInstaller.occupant(at: destination) == .somethingElse)
        #expect(throws: InstallFailure.exists) {
            try CommandLineToolInstaller.installSymlink(at: destination)
        }
    }

    @Test("A free path holds nothing")
    func freePathHoldsNothing() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(
            CommandLineToolInstaller.occupant(at: directory.appendingPathComponent("kernova"))
                == .nothing)
    }

    @Test("A path the app cannot write refuses, and says why")
    func installRefusesAnUnwritablePath() {
        // The system volume is read-only, and no grant makes it otherwise.
        let destination = URL(fileURLWithPath: "/System/kernova-should-not-exist")
        do {
            try CommandLineToolInstaller.installSymlink(at: destination)
            Issue.record("expected the write to be refused")
            try? FileManager.default.removeItem(at: destination)
        } catch InstallFailure.unwritable(let detail) {
            #expect(!detail.isEmpty)
        } catch {
            Issue.record("expected an unwritable failure, got \(error)")
        }
    }

    @Test("The tool is offered from Contents/Helpers, never from Contents/MacOS")
    func bundledToolLivesInHelpers() {
        let path = CommandLineToolInstaller.bundledToolURL.path(percentEncoded: false)
        #expect(path.hasSuffix("/Contents/Helpers/kernova"))
        // A case-insensitive volume makes Contents/MacOS/kernova the app's own
        // executable — Config/Targets/KernovaCLI.xcconfig.
        #expect(!path.contains("/Contents/MacOS/"))
    }

    @Test("The manual command names both ends of the link the panel would have made")
    func manualCommandNamesBothEnds() {
        let destination = URL(fileURLWithPath: "/usr/local/bin/kernova")
        let command = CommandLineToolInstaller.manualCommand(for: destination)
        #expect(command.hasPrefix("ln -s "))
        #expect(command.contains(CommandLineToolInstaller.bundledToolURL.path(percentEncoded: false)))
        #expect(command.contains("/usr/local/bin/kernova"))
    }

    @Test("The offer follows the container the socket binds in")
    func availabilityFollowsTheContainer() {
        // One condition, read in one place: an Install button that could only
        // ever produce a tool reaching nothing is not offered at all.
        let hasContainer = KernovaAppGroup.containerURL() != nil
        let hasTool = FileManager.default.fileExists(
            atPath: CommandLineToolInstaller.bundledToolURL.path(percentEncoded: false))
        #expect(CommandLineToolInstaller.isAvailable == (hasContainer && hasTool))
    }
}
