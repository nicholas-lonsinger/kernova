import ArgumentParser
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// What a typed command line means, decided before anything is connected to.
@Suite("CLI argument parsing", .caseScoped)
struct CLIArgumentParsingTests {
    /// Parses `arguments` as the root command and returns what it resolved to.
    private func parse(_ arguments: [String]) throws -> ParsableCommand {
        try KernovaCommand.parseAsRoot(arguments)
    }

    // MARK: - list filters

    /// The query `arguments`, after `list`, put on the wire.
    private func listQuery(_ arguments: [String]) throws -> VMListQuery {
        let list = try #require(try parse(["list"] + arguments) as? KernovaCommand.List)
        guard case .list(let query) = try list.verb() else {
            Issue.record("list asked for something other than a listing")
            return VMListQuery()
        }
        return query
    }

    @Test("--state takes each state bucket by its name, and refuses any other")
    func stateTakesBucketNames() throws {
        for bucket in VMStateBucket.allCases {
            #expect(try listQuery(["--state", bucket.rawValue]).filter.states == [bucket])
        }
        #expect(
            VMStateBucket.allCases.map(\.rawValue)
                == ["running", "suspended", "stopped", "heldByAnotherCopy", "preparing"])
        #expect(throws: (any Error).self) { try parse(["list", "--state", "paused"]) }
        #expect(throws: (any Error).self) { try parse(["list", "--os", "windows"]) }
        #expect(throws: (any Error).self) { try parse(["list", "--agent", "current"]) }
    }

    @Test("--agent, --ephemeral and --has-snapshots each set their own attribute")
    func agentAndFlagsParse() throws {
        let query = try listQuery(["--agent", "neverConnected", "--agent", "upToDate", "--ephemeral"])
        #expect(query.filter == VMLibraryFilter(guestAgents: [.neverConnected, .upToDate], ephemeralOnly: true))
        #expect(try listQuery(["--has-snapshots"]).filter == VMLibraryFilter(withSnapshotsOnly: true))
    }

    @Test("--tag sends every value as typed, in order, for the app to read as a tag's name or identifier")
    func tagsGoAsTyped() throws {
        let typed = ["Work", "lab", "8D0C3F0E-8E1B-4F7B-9F61-0D7C4D6A1E21"]
        let query = try listQuery(typed.flatMap { ["--tag", $0] } + ["--os", "linux"])
        #expect(query.tags == typed)
        #expect(query.filter == VMLibraryFilter(guestOSes: [.linux]))
    }

    @Test("clone follows the app's preference unless an outcome flag says otherwise")
    func cloneParsesItsOutcomeFlags() throws {
        let byDefault = try #require(try parse(["clone", "Alpha"]) as? KernovaCommand.Clone)
        #expect(byDefault.outcome == nil)
        #expect(!byDefault.noWait)

        let fresh = try #require(
            try parse(["clone", "Alpha", "--new-machine"]) as? KernovaCommand.Clone)
        #expect(fresh.outcome?.outcome == .newMachine)

        let kept = try #require(
            try parse(["clone", "Alpha", "--exact-copy"]) as? KernovaCommand.Clone)
        #expect(kept.outcome?.outcome == .exactCopy)
    }

    @Test("clone and import take --no-wait, and wait for the copy without it")
    func copyingVerbsParseNoWait() throws {
        let clone = try #require(
            try parse(["clone", "Alpha", "--no-wait"]) as? KernovaCommand.Clone)
        #expect(clone.noWait)

        let waiting = try #require(
            try parse(["import", "/tmp/Alpha.kernova"]) as? KernovaCommand.Import)
        #expect(!waiting.noWait)

        let immediate = try #require(
            try parse(["import", "/tmp/Alpha.kernova", "--no-wait"]) as? KernovaCommand.Import)
        #expect(immediate.noWait)
        #expect(immediate.path == "/tmp/Alpha.kernova")
    }

    @Test("import takes --timeout, and waits as long as it takes without one")
    func importParsesTimeout() throws {
        // Absent is unbounded: the wait covers a permission panel a person is
        // answering, and no deadline can guess how long that takes.
        let bare = try #require(
            try parse(["import", "/tmp/Alpha.kernova"]) as? KernovaCommand.Import)
        #expect(bare.timeout == nil)

        let bounded = try #require(
            try parse(["import", "/tmp/Alpha.kernova", "--timeout", "90"])
                as? KernovaCommand.Import)
        #expect(bounded.timeout == 90)
    }

    @Test("A capture takes its name and note, and leaves both to Kernova when unnamed")
    func takeParsesItsNameAndNotes() throws {
        let unnamed = try #require(
            try parse(["snapshot", "take", "Alpha"]) as? KernovaCommand.Snapshot.Take)
        // Empty rather than a name computed here: the app holds the manifest
        // the default has to avoid colliding with.
        #expect(unnamed.name.isEmpty)
        #expect(unnamed.notes.isEmpty)

        let named = try #require(
            try parse([
                "snapshot", "take", "Alpha", "--name", "Before Upgrade", "--notes", "26.1 beta",
            ]) as? KernovaCommand.Snapshot.Take)
        #expect(named.name == "Before Upgrade")
        #expect(named.notes == "26.1 beta")
    }

    // MARK: - Named networks

    @Test("get --keys names no virtual machine, and refuses one that is named anyway")
    func getKeysNamesNoVirtualMachine() throws {
        let listing = try #require(try parse(["get", "--keys"]) as? KernovaCommand.Get)
        #expect(listing.listingKeys)
        #expect(listing.vm == nil)
        #expect(try listing.verb() == .configurationKeys)

        // The keyspace is the same for every virtual machine, so an argument
        // here is a line that meant something else.
        #expect(throws: (any Error).self) { try parse(["get", "--keys", "Alpha"]) }
        #expect(throws: (any Error).self) { try parse(["get", "--keys", "Alpha", "cpus"]) }
    }

    @Test("An assignment is split at its first =, and an empty value is a value")
    func assignmentsSplitAtTheFirstEquals() throws {
        #expect(
            try KernovaCommand.Set.entries(from: ["cpus=4", "network.mode=nat"]) == [
                ConfigurationEntry(key: "cpus", value: "4"),
                ConfigurationEntry(key: "network.mode", value: "nat"),
            ])
        // The first `=` and no other: a value carrying one arrives whole.
        #expect(
            try KernovaCommand.Set.entries(from: ["notes=a=b"]) == [
                ConfigurationEntry(key: "notes", value: "a=b")
            ])
        // Empty is how the settings that take a spelled-out name are cleared.
        #expect(
            try KernovaCommand.Set.entries(from: ["network.mac="]) == [
                ConfigurationEntry(key: "network.mac", value: "")
            ])
    }

    @Test("set carries --yes as the consent one setting asks for")
    func setCarriesItsConsent() throws {
        let bare = try #require(try parse(["set", "Alpha", "cpus=4"]) as? KernovaCommand.Set)
        #expect(
            try bare.verb()
                == .setConfiguration(
                    .idOrName("Alpha"), assignments: [ConfigurationEntry(key: "cpus", value: "4")],
                    consent: .none))

        let consented = try #require(
            try parse(["set", "Alpha", "clipboard.passthrough=true", "--yes"])
                as? KernovaCommand.Set)
        #expect(
            try consented.verb()
                == .setConfiguration(
                    .idOrName("Alpha"),
                    assignments: [ConfigurationEntry(key: "clipboard.passthrough", value: "true")],
                    consent: .all))
    }

    @Test("A share is writable unless --read-only says otherwise, and its path is made absolute")
    func shareAddParsesItsFlags() throws {
        let writable = try #require(
            try parse(["share", "add", "Alpha", "/tmp/Work"]) as? KernovaCommand.Share.Add)
        #expect(!writable.readOnly)
        #expect(
            try writable.verb()
                == .editSharedDirectory(.idOrName("Alpha"), .add(path: "/tmp/Work", readOnly: false)))

        let readOnly = try #require(
            try parse(["share", "add", "Alpha", "/tmp/Work/", "--read-only"])
                as? KernovaCommand.Share.Add)
        #expect(readOnly.readOnly)
        #expect(
            try readOnly.verb()
                == .editSharedDirectory(.idOrName("Alpha"), .add(path: "/tmp/Work", readOnly: true)))
    }

    @Test("restart defaults to asking the guest, and takes each stop method with a deadline")
    func restartMethodsMapToDispositions() throws {
        let byDefault = try #require(try parse(["restart", "Alpha"]) as? KernovaCommand.Restart)
        #expect(byDefault.method == .normal)
        for (flag, disposition) in [
            ("--normal", StopDisposition.graceful), ("--force", .force), ("--anyway", .anyway),
        ] {
            let restart = try #require(
                try parse(["restart", "Alpha", flag, "--timeout", "5"]) as? KernovaCommand.Restart)
            #expect(restart.method.disposition == disposition, "\(flag)")
            #expect(restart.timeout == 5)
        }
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
        // Connected but out of date, or of unknown standing, is not what a
        // script waited for.
        for other in [
            "waiting", "connecting", "connected", "outdated", "unresponsive", "expectedMissing", "disconnected",
        ] {
            #expect(WaitCondition.agent.isSatisfied(byAgentStatus: other) == false, "\(other)")
        }
        // No session, so no agent to have arrived.
        #expect(WaitCondition.agent.isSatisfied(byAgentStatus: nil) == false)
    }

    // MARK: - Global options

    @Test("--no-launch parses on a verb that would otherwise start the app")
    func noLaunchParses() throws {
        let listing = try #require(try parse(["list", "--no-launch"]) as? KernovaCommand.List)
        #expect(listing.options.noLaunch)

        let start = try #require(
            try parse(["start", "Alpha", "--no-launch"]) as? KernovaCommand.Start)
        #expect(start.options.noLaunch)
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
}
