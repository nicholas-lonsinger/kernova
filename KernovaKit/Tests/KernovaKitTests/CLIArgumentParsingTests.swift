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

    // MARK: - Subcommand resolution

    @Test("Each read verb parses to its own subcommand")
    func readVerbsResolve() throws {
        #expect(try parse(["list"]) is KernovaCommand.List)
        #expect(try parse(["info", "Alpha"]) is KernovaCommand.Info)
        #expect(try parse(["ip", "Alpha"]) is KernovaCommand.IP)
        #expect(try parse(["version"]) is KernovaCommand.Version)
    }

    @Test("Each snapshot verb parses to its own subcommand under `snapshot`")
    func snapshotVerbsResolve() throws {
        #expect(try parse(["snapshot", "list", "Alpha"]) is KernovaCommand.Snapshot.List)
        #expect(try parse(["snapshot", "take", "Alpha"]) is KernovaCommand.Snapshot.Take)
        #expect(
            try parse(["snapshot", "revert", "Alpha", "Base"]) is KernovaCommand.Snapshot.Revert)
        #expect(
            try parse(["snapshot", "delete", "Alpha", "Base"]) is KernovaCommand.Snapshot.Delete)
        #expect(
            try parse(["snapshot", "rename", "Alpha", "Base", "Older"])
                is KernovaCommand.Snapshot.Rename)
        // The library verbs of the same name stay themselves.
        #expect(try parse(["delete", "Alpha"]) is KernovaCommand.Delete)
        #expect(try parse(["list"]) is KernovaCommand.List)
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

    @Test("--sort takes each order by its name and defaults to the manual order")
    func sortParses() throws {
        for sort in VMLibrarySort.allCases {
            #expect(try listQuery(["--sort", sort.rawValue]).sort == sort)
        }
        #expect(throws: (any Error).self) { try parse(["list", "--sort", "size"]) }
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

    @Test("Every clone outcome flag maps onto a wire outcome, and each outcome has a flag")
    func everyCloneOutcomeMaps() {
        let mapped = Set(KernovaCommand.CloneOutcomeFlag.allCases.map(\.outcome))
        #expect(mapped == Set(CloneOutcome.allCases))
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

    @Test("A revert takes no snapshot of its own, so --no-checkpoint is no flag of it")
    func revertTakesNoCheckpointFlag() throws {
        let revert = try #require(
            try parse(["snapshot", "revert", "Alpha", "Base", "--yes"])
                as? KernovaCommand.Snapshot.Revert)
        #expect(revert.snapshot == "Base")
        #expect(revert.options.yes)
        for flag in ["--checkpoint", "--no-checkpoint"] {
            #expect(throws: (any Error).self, "\(flag)") {
                try parse(["snapshot", "revert", "Alpha", "Base", flag])
            }
        }
    }

    @Test("A refusal's routes render as the command lines that take each step")
    func stepRoutesRenderAsCommandLines() {
        func vm(_ name: String) -> VMSummary {
            VMSummary(
                id: UUID(), name: name, status: "paused", ipAddress: .unavailable, heldByAnotherCopy: false)
        }
        #expect(
            CommandLineSpelling.routes(
                of: StepRequirement(
                    message: "",
                    routes: [StepRoute(title: "Resume", steps: [.resume(vm: vm("My VM"))], ending: .refusedVerb)]))
                == "Resume with: kernova resume 'My VM'")
        #expect(
            CommandLineSpelling.routes(
                of: StepRequirement(
                    message: "",
                    routes: [
                        StepRoute(
                            title: "Use a New MAC Address",
                            steps: [
                                .discardSavedState(vm: vm("Alpha")),
                                .setConfiguration(
                                    vm: vm("Alpha"),
                                    assignments: [ConfigurationEntry(key: "network.mac", value: "new")]),
                            ], ending: .refusedVerb)
                    ]))
                == "Use a New MAC Address with:\n  kernova stop Alpha --yes\n  kernova set Alpha network.mac=new")
        #expect(
            CommandLineSpelling.line(
                for: .setConfiguration(
                    vm: vm("Bob's VM"),
                    assignments: [ConfigurationEntry(key: "ephemeral", value: "false")]))
                == #"kernova set 'Bob'\''s VM' ephemeral=false"#)
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

    @Test("--id reads both arguments of a snapshot verb as identifiers")
    func snapshotVerbsCarryTheIDFlag() throws {
        let rename = try #require(
            try parse(["snapshot", "rename", "Alpha", "Base", "Older", "--id"])
                as? KernovaCommand.Snapshot.Rename)
        #expect(rename.options.id)
        #expect(rename.newName == "Older")
    }

    @Test("A relative path argument is made absolute, and a standardized one stays as it is")
    func pathArgumentsAreAbsoluteAndStandardized() {
        // The shell's directory, not the process's: a sandboxed tool's own is
        // its container.
        #expect(
            PathParsing.wirePath(
                for: "VMs/../VMs/Alpha.kernova", workingDirectory: "/Users/me/Desktop")
                == "/Users/me/Desktop/VMs/Alpha.kernova")
        let fallback = PathParsing.wirePath(for: "Alpha.kernova", workingDirectory: nil)
        #expect(fallback == FileManager.default.currentDirectoryPath + "/Alpha.kernova")
        // Nothing is read: the tool is sandboxed, so a path naming no file
        // still crosses the wire for the app to answer for.
        #expect(
            PathParsing.wirePath(
                for: "/a/b/../c/Alpha.kernova", workingDirectory: "/Users/me/Desktop")
                == "/a/c/Alpha.kernova")
    }

    // MARK: - USB accessories

    @Test("A USB listing asks a guest's own accessories only when a guest is named")
    func usbListNamesItsSubject() throws {
        let free = try #require(try parse(["usb", "list"]) as? KernovaCommand.USB.List)
        #expect(free.vm == nil)
        #expect(try free.verb() == .availableUSBAccessories)

        let held = try #require(try parse(["usb", "list", "Alpha"]) as? KernovaCommand.USB.List)
        #expect(held.vm == "Alpha")
        #expect(try held.verb() == .usbAccessories(.idOrName("Alpha")))
    }

    @Test("An accessory is attached by its own identifier and detached by the attachment's")
    func usbEditsNameTheirHandles() throws {
        // An IORegistry ID runs past what 32 bits can name.
        let attach = try #require(
            try parse(["usb", "attach", "Alpha", "4294967296"]) as? KernovaCommand.USB.Attach)
        #expect(
            try attach.verb()
                == .editUSBAccessory(.idOrName("Alpha"), .attach(accessory: 4_294_967_296)))

        let device = UUID()
        let detach = try #require(
            try parse(["usb", "detach", "Alpha", device.uuidString]) as? KernovaCommand.USB.Detach)
        #expect(
            try detach.verb() == .editUSBAccessory(.idOrName("Alpha"), .detach(device: device)))
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

    @Test("get without --keys refuses without a virtual machine")
    func getNeedsAVirtualMachineWithoutTheKeysFlag() {
        #expect(throws: (any Error).self) { try parse(["get"]) }
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

    @Test("An argument that is not a key=value assignment exits 2, naming what was typed")
    func malformedAssignmentsAreUsageErrors() {
        for argument in ["cpus", "", "=4", "=", " "] {
            do {
                _ = try KernovaCommand.Set.entries(from: ["cpus=4", argument])
                Issue.record("expected a usage refusal for \u{201C}\(argument)\u{201D}")
            } catch let failure as CLIFailure {
                #expect(failure.code == .usage)
                #expect(argument.isEmpty || failure.message.contains(argument))
            } catch {
                Issue.record("expected a CLIFailure, got \(error)")
            }
        }
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

    @Test("A share is dropped by the path that names it, standardized the same way")
    func shareRemoveNamesThePath() throws {
        let command = try #require(
            try parse(["share", "remove", "Alpha", "/tmp/../tmp/Work"])
                as? KernovaCommand.Share.Remove)
        #expect(
            try command.verb()
                == .editSharedDirectory(.idOrName("Alpha"), .removePath(path: "/tmp/Work")))
    }

    @Test("--id reads a configuration verb's virtual machine as an identifier")
    func configurationVerbsCarryTheIDFlag() throws {
        let identifier = UUID()
        let command = try #require(
            try parse(["get", identifier.uuidString, "cpus", "--id"]) as? KernovaCommand.Get)
        #expect(try command.verb() == .configuration(.id(identifier), keys: ["cpus"]))

        let named = try #require(try parse(["get", "Alpha", "--id"]) as? KernovaCommand.Get)
        #expect(throws: CLIFailure.self) { try named.verb() }
    }

    @Test("quit parses, and names no virtual machine")
    func quitResolves() throws {
        #expect(try parse(["quit"]) is KernovaCommand.Quit)
        #expect(throws: (any Error).self) { try parse(["quit", "Alpha"]) }
    }

    @Test("A deadline that names no wait is a usage error on every verb that takes one")
    func everyTimeoutRefusesANonPositiveDeadline() {
        let lines: [[String]] = [
            ["stop", "Alpha", "--timeout", "0"],
            ["stop", "Alpha", "--timeout", "-5"],
            ["restart", "Alpha", "--timeout", "0"],
            ["restart", "Alpha", "--timeout", "-5"],
            ["wait", "Alpha", "--until", "stopped", "--timeout", "0"],
            ["ip", "Alpha", "--wait", "--timeout", "-1"],
            ["import", "/tmp/Alpha.kernova", "--timeout", "0"],
            ["import", "/tmp/Alpha.kernova", "--timeout", "-5"],
        ]
        for line in lines {
            #expect(throws: (any Error).self, "\(line)") { try parse(line) }
        }
    }

    @Test("Two stop methods at once is a usage error, not a silent winner, for stop and restart alike")
    func stopMethodsAreExclusive() {
        for verb in ["stop", "restart"] {
            #expect(throws: (any Error).self) { try parse([verb, "Alpha", "--force", "--normal"]) }
            #expect(throws: (any Error).self) { try parse([verb, "Alpha", "--anyway", "--force"]) }
            #expect(throws: (any Error).self) { try parse([verb, "Alpha", "--anyway", "--normal"]) }
        }
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

    @Test("The options default to the human-readable table")
    func optionsDefaultToTable() throws {
        let command = try #require(try parse(["list"]) as? KernovaCommand.List)
        #expect(command.options.format == .table)
        #expect(!command.options.quiet)
        #expect(!command.options.id)
        #expect(!command.options.yes)
        // Starting the app to answer is the default; --no-launch opts out.
        #expect(!command.options.noLaunch)
    }

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
