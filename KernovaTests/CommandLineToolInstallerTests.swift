import Foundation
import KernovaKit
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

        #expect(throws: CommandLineToolInstaller.InstallFailure.exists) {
            try CommandLineToolInstaller.installSymlink(at: destination)
        }
        // Untouched: replacing it could delete a tool the user relies on.
        #expect(try Data(contentsOf: destination) == existing)
    }

    @Test("An existing link is refused too, rather than silently repointed")
    func installRefusesAnExistingLink() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("kernova")
        try FileManager.default.createSymbolicLink(
            at: destination, withDestinationURL: URL(fileURLWithPath: "/usr/bin/env"))

        #expect(throws: CommandLineToolInstaller.InstallFailure.exists) {
            try CommandLineToolInstaller.installSymlink(at: destination)
        }
    }

    @Test("A path the app cannot write refuses, and says why")
    func installRefusesAnUnwritablePath() {
        // The system volume is read-only, and no grant makes it otherwise.
        let destination = URL(fileURLWithPath: "/System/kernova-should-not-exist")
        do {
            try CommandLineToolInstaller.installSymlink(at: destination)
            Issue.record("expected the write to be refused")
            try? FileManager.default.removeItem(at: destination)
        } catch CommandLineToolInstaller.InstallFailure.unwritable(let detail) {
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
        // executable — docs/BUILD.md "The bundled kernova tool".
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
