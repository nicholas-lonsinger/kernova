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

    @Test("Each lifecycle verb parses to its own subcommand")
    func lifecycleVerbsResolve() throws {
        #expect(try parse(["start", "Alpha"]) is KernovaCommand.Start)
        #expect(try parse(["stop", "Alpha"]) is KernovaCommand.Stop)
        #expect(try parse(["suspend", "Alpha"]) is KernovaCommand.Suspend)
        #expect(try parse(["pause", "Alpha"]) is KernovaCommand.Pause)
        #expect(try parse(["resume", "Alpha"]) is KernovaCommand.Resume)
        #expect(try parse(["restart", "Alpha"]) is KernovaCommand.Restart)
        #expect(try parse(["open", "Alpha"]) is KernovaCommand.Open)
    }

    @Test("start takes --recovery, and defaults to a normal boot")
    func startParsesRecovery() throws {
        #expect(try #require(try parse(["start", "Alpha"]) as? KernovaCommand.Start).recovery == false)
        let recovery = try #require(
            try parse(["start", "Alpha", "--recovery"]) as? KernovaCommand.Start)
        #expect(recovery.recovery)
        #expect(recovery.vm == "Alpha")
    }

    @Test("stop defaults to asking the guest, and each method names its own disposition")
    func stopMethodsMapToDispositions() throws {
        let byDefault = try #require(try parse(["stop", "Alpha"]) as? KernovaCommand.Stop)
        #expect(byDefault.method == .graceful)
        #expect(byDefault.method.disposition == .graceful)

        let forced = try #require(try parse(["stop", "Alpha", "--force"]) as? KernovaCommand.Stop)
        #expect(forced.method.disposition == .force)

        let resumed = try #require(
            try parse(["stop", "Alpha", "--resume-first"]) as? KernovaCommand.Stop)
        #expect(resumed.method.disposition == .resumeThenShutDown)
    }

    @Test("Two stop methods at once is a usage error, not a silent winner")
    func stopMethodsAreExclusive() {
        #expect(throws: (any Error).self) { try parse(["stop", "Alpha", "--force", "--graceful"]) }
    }

    @Test("Every stop method maps onto a wire disposition, exhaustively")
    func everyStopMethodMaps() {
        let mapped = Set(KernovaCommand.StopMethod.allCases.map(\.disposition))
        #expect(mapped == Set(StopDisposition.allCases))
    }

    @Test("wait parses its condition and its deadline")
    func waitParsesItsCondition() throws {
        let running = try #require(
            try parse(["wait", "Alpha", "--until", "running"]) as? KernovaCommand.Wait)
        #expect(running.until == .running)
        #expect(running.timeout == 300)

        let agent = try #require(
            try parse(["wait", "Alpha", "--until", "agent", "--timeout", "45"])
                as? KernovaCommand.Wait)
        #expect(agent.until == .agent)
        #expect(agent.timeout == 45)
    }

    @Test("wait refuses a condition this build cannot watch for, and one it was not given")
    func waitRefusesAnUnknownCondition() {
        #expect(throws: (any Error).self) { try parse(["wait", "Alpha", "--until", "melted"]) }
        #expect(throws: (any Error).self) { try parse(["wait", "Alpha"]) }
    }

    @Test("ip takes --wait and its own deadline")
    func ipParsesWait() throws {
        let plain = try #require(try parse(["ip", "Alpha"]) as? KernovaCommand.IP)
        #expect(!plain.wait)

        let waiting = try #require(
            try parse(["ip", "Alpha", "--wait", "--timeout", "10"]) as? KernovaCommand.IP)
        #expect(waiting.wait)
        #expect(waiting.timeout == 10)
    }

    @Test("Each wait condition reads exactly one kind of state")
    func waitConditionsReadOneKindOfState() {
        #expect(WaitCondition.running.isSatisfied(byStatus: "running") == true)
        #expect(WaitCondition.running.isSatisfied(byStatus: "stopped") == false)
        #expect(WaitCondition.stopped.isSatisfied(byStatus: "stopped") == true)
        #expect(WaitCondition.stopped.isSatisfied(byStatus: "running") == false)
        // A status-shaped condition says nothing about the agent, and the
        // agent condition says nothing about the status.
        #expect(WaitCondition.running.isSatisfied(byAgentStatus: "current") == nil)
        #expect(WaitCondition.stopped.isSatisfied(byAgentStatus: "current") == nil)
        #expect(WaitCondition.agent.isSatisfied(byStatus: "running") == nil)
        #expect(WaitCondition.agent.isSatisfied(byAgentStatus: "current") == true)
        // Connected but out of date is not what a script waited for.
        for other in ["waiting", "connecting", "outdated", "unresponsive", "expectedMissing"] {
            #expect(WaitCondition.agent.isSatisfied(byAgentStatus: other) == false, "\(other)")
        }
    }

    @Test("Every wait condition is reachable from the command line")
    func everyWaitConditionParses() throws {
        for condition in WaitCondition.allCases {
            let parsed = try #require(
                try parse(["wait", "Alpha", "--until", condition.rawValue])
                    as? KernovaCommand.Wait)
            #expect(parsed.until == condition)
        }
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
