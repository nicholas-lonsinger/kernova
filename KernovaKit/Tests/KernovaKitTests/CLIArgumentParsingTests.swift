import ArgumentParser
import Foundation
import KernovaKit
import Testing

@testable import KernovaCLICore

/// What a typed command line means, decided before anything is connected to.
@Suite("CLI argument parsing", .admissionGated)
struct CLIArgumentParsingTests {
    /// Parses `arguments` as the root command and returns what it resolved to.
    private func parse(_ arguments: [String]) throws -> ParsableCommand {
        try KernovaCommand.parseAsRoot(arguments)
    }

    // MARK: - Subcommand resolution

    @Test("Each read verb parses to its own subcommand")
    func readVerbsResolve() throws {
        #expect(try parse(["list"]) is KernovaCommand.List)
        #expect(try parse(["info", "Alpha"]) is KernovaCommand.Info)
        #expect(try parse(["ip", "Alpha"]) is KernovaCommand.IP)
        #expect(try parse(["version"]) is KernovaCommand.Version)
    }

    @Test("A bare invocation lists, so `kernova` alone answers something useful")
    func bareInvocationLists() throws {
        #expect(try parse([]) is KernovaCommand.List)
    }

    @Test("A verb this build does not have is a usage error, never a silent no-op")
    func unknownVerbIsRefused() {
        #expect(throws: (any Error).self) { try parse(["teleport", "Alpha"]) }
    }

    @Test("A verb that needs a virtual machine refuses without one")
    func missingArgumentIsRefused() {
        #expect(throws: (any Error).self) { try parse(["info"]) }
    }

    // MARK: - Global options

    @Test("The options default to the human-readable table")
    func optionsDefaultToTable() throws {
        let command = try #require(try parse(["list"]) as? KernovaCommand.List)
        #expect(command.options.format == .table)
        #expect(!command.options.quiet)
        #expect(!command.options.id)
        #expect(!command.options.yes)
    }

    @Test("Every global option parses on every verb that takes one")
    func optionsParseEverywhere() throws {
        let list = try #require(
            try parse(["list", "--format", "json", "--quiet"]) as? KernovaCommand.List)
        #expect(list.options.format == .json)
        #expect(list.options.quiet)

        let info = try #require(
            try parse(["info", "Alpha", "--id", "-q", "--yes"]) as? KernovaCommand.Info)
        #expect(info.vm == "Alpha")
        #expect(info.options.id)
        #expect(info.options.quiet)
        #expect(info.options.yes)
    }

    @Test("A format this build does not write is a usage error")
    func unknownFormatIsRefused() {
        #expect(throws: (any Error).self) { try parse(["list", "--format", "yaml"]) }
    }

    // MARK: - Selector parsing

    @Test("A bare argument is read as an identifier or a name, and the app decides")
    func bareArgumentIsIDOrName() throws {
        #expect(try SelectorParsing.selector(from: "Alpha", forcingID: false) == .idOrName("Alpha"))
        let identifier = UUID()
        #expect(
            try SelectorParsing.selector(from: identifier.uuidString, forcingID: false)
                == .idOrName(identifier.uuidString))
    }

    @Test("--id forces the identifier reading")
    func idFlagForcesTheIdentifier() throws {
        let identifier = UUID()
        #expect(
            try SelectorParsing.selector(from: identifier.uuidString, forcingID: true)
                == .id(identifier))
    }

    @Test("--id on something that is not an identifier is a usage error, not a name search")
    func idFlagRefusesANonIdentifier() {
        do {
            _ = try SelectorParsing.selector(from: "Alpha", forcingID: true)
            Issue.record("expected a usage refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == .usage)
            #expect(failure.message.contains("Alpha"))
        } catch {
            Issue.record("expected a CLIFailure, got \(error)")
        }
    }
}
