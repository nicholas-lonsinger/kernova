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

    @Test("Each library verb parses to its own subcommand")
    func libraryVerbsResolve() throws {
        #expect(try parse(["clone", "Alpha"]) is KernovaCommand.Clone)
        #expect(try parse(["rename", "Alpha", "Beta"]) is KernovaCommand.Rename)
        #expect(try parse(["delete", "Alpha"]) is KernovaCommand.Delete)
        #expect(try parse(["import", "/tmp/Alpha.kernova"]) is KernovaCommand.Import)
        #expect(try parse(["reveal", "Alpha"]) is KernovaCommand.Reveal)
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

    @Test("A snapshot verb this build does not have is a usage error")
    func unknownSnapshotVerbIsRefused() {
        #expect(throws: (any Error).self) { try parse(["snapshot", "restore", "Alpha", "Base"]) }
    }

    @Test("Every snapshot verb refuses without the arguments it acts on")
    func snapshotVerbsNeedTheirArguments() {
        let lines: [[String]] = [
            ["snapshot", "list"],
            ["snapshot", "take"],
            ["snapshot", "revert", "Alpha"],
            ["snapshot", "delete", "Alpha"],
            ["snapshot", "rename", "Alpha", "Base"],
            ["rename", "Alpha"],
            ["import"],
        ]
        for line in lines {
            #expect(throws: (any Error).self, "\(line)") { try parse(line) }
        }
    }

    @Test("clone follows the app's preference unless an identity flag says otherwise")
    func cloneParsesItsIdentityFlags() throws {
        let byDefault = try #require(try parse(["clone", "Alpha"]) as? KernovaCommand.Clone)
        #expect(byDefault.identity == nil)
        #expect(!byDefault.noWait)

        let fresh = try #require(
            try parse(["clone", "Alpha", "--new-identity"]) as? KernovaCommand.Clone)
        #expect(fresh.identity?.machineIdentity == .new)

        let kept = try #require(
            try parse(["clone", "Alpha", "--keep-identity"]) as? KernovaCommand.Clone)
        #expect(kept.identity?.machineIdentity == .keep)
    }

    @Test("Two clone identities at once is a usage error, not a silent winner")
    func cloneIdentitiesAreExclusive() {
        #expect(throws: (any Error).self) {
            try parse(["clone", "Alpha", "--new-identity", "--keep-identity"])
        }
    }

    @Test("Every clone identity flag maps onto a wire choice, and neither means the preference")
    func everyCloneIdentityMaps() {
        let mapped = Set(KernovaCommand.CloneIdentity.allCases.map(\.machineIdentity))
        #expect(mapped == Set(CloneMachineIdentity.allCases).subtracting([.followPreference]))
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
        // Absent is unbounded on purpose: the wait covers a permission panel a
        // person is answering, and no deadline can guess how long that takes.
        let bare = try #require(
            try parse(["import", "/tmp/Alpha.kernova"]) as? KernovaCommand.Import)
        #expect(bare.timeout == nil)

        let bounded = try #require(
            try parse(["import", "/tmp/Alpha.kernova", "--timeout", "90"])
                as? KernovaCommand.Import)
        #expect(bounded.timeout == 90)
    }

    @Test("delete moves the bundle to the Trash unless --permanent says otherwise")
    func deleteParsesPermanent() throws {
        let trashed = try #require(try parse(["delete", "Alpha"]) as? KernovaCommand.Delete)
        #expect(!trashed.permanent)
        #expect(!trashed.options.yes)

        let outright = try #require(
            try parse(["delete", "Alpha", "--permanent", "--yes"]) as? KernovaCommand.Delete)
        #expect(outright.permanent)
        #expect(outright.options.yes)
    }

    @Test("A revert check-points by default, and --no-checkpoint is how that is given up")
    func revertParsesItsCheckpoint() throws {
        let safe = try #require(
            try parse(["snapshot", "revert", "Alpha", "Base"]) as? KernovaCommand.Snapshot.Revert)
        #expect(safe.checkpoint)
        #expect(safe.snapshot == "Base")

        let asked = try #require(
            try parse(["snapshot", "revert", "Alpha", "Base", "--checkpoint"])
                as? KernovaCommand.Snapshot.Revert)
        #expect(asked.checkpoint)

        let bare = try #require(
            try parse(["snapshot", "revert", "Alpha", "Base", "--no-checkpoint", "--yes"])
                as? KernovaCommand.Snapshot.Revert)
        #expect(!bare.checkpoint)
        #expect(bare.options.yes)
    }

    @Test("Asking for both check-point answers at once is a usage error")
    func revertCheckpointIsExclusive() {
        #expect(throws: (any Error).self) {
            try parse(["snapshot", "revert", "Alpha", "Base", "--checkpoint", "--no-checkpoint"])
        }
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

    // MARK: - Configuration

    @Test("Each configuration verb parses to its own subcommand")
    func configurationVerbsResolve() throws {
        #expect(try parse(["get", "Alpha"]) is KernovaCommand.Get)
        #expect(try parse(["set", "Alpha", "cpus=4"]) is KernovaCommand.Set)
        #expect(try parse(["share", "list", "Alpha"]) is KernovaCommand.Share.List)
        #expect(try parse(["share", "add", "Alpha", "/tmp/Work"]) is KernovaCommand.Share.Add)
        #expect(
            try parse(["share", "remove", "Alpha", "/tmp/Work"]) is KernovaCommand.Share.Remove)
        #expect(try parse(["forward", "list", "Alpha"]) is KernovaCommand.Forward.List)
        #expect(try parse(["forward", "add", "Alpha", "8080:80"]) is KernovaCommand.Forward.Add)
        #expect(
            try parse(["forward", "remove", "Alpha", "8080:80"]) is KernovaCommand.Forward.Remove)
    }

    @Test("Each list verb reads its virtual machine and asks for that machine's own list")
    func listVerbsNameTheirVM() throws {
        let shares = try #require(
            try parse(["share", "list", "Alpha"]) as? KernovaCommand.Share.List)
        #expect(shares.vm == "Alpha")
        #expect(try shares.verb() == .sharedDirectories(.idOrName("Alpha")))

        let forwards = try #require(
            try parse(["forward", "list", "Alpha"]) as? KernovaCommand.Forward.List)
        #expect(forwards.vm == "Alpha")
        #expect(!forwards.udp)
        #expect(try forwards.verb() == .portForwardingRules(.idOrName("Alpha")))

        // The transport rides the same flag `forward remove` takes, and picks
        // among the rules one read answers rather than asking a second time.
        let udp = try #require(
            try parse(["forward", "list", "Alpha", "--udp"]) as? KernovaCommand.Forward.List)
        #expect(udp.udp)
        #expect(try udp.verb() == .portForwardingRules(.idOrName("Alpha")))
    }

    @Test("Every list verb refuses without the virtual machine it lists")
    func listVerbsNeedAVM() {
        #expect(throws: (any Error).self) { try parse(["share", "list"]) }
        #expect(throws: (any Error).self) { try parse(["forward", "list"]) }
    }

    // MARK: - USB accessories

    @Test("Each USB verb parses to its own subcommand")
    func usbVerbsResolve() throws {
        #expect(try parse(["usb", "list"]) is KernovaCommand.USB.List)
        #expect(try parse(["usb", "attach", "Alpha", "12"]) is KernovaCommand.USB.Attach)
        #expect(
            try parse(["usb", "detach", "Alpha", UUID().uuidString]) is KernovaCommand.USB.Detach)
    }

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

    @Test("Neither USB handle is a display name, so text that is not one never crosses the wire")
    func usbHandlesRefuseAnythingButAnIdentifier() throws {
        let attach = try #require(
            try parse(["usb", "attach", "Alpha", "hub"]) as? KernovaCommand.USB.Attach)
        #expect(throws: CLIFailure.self) { try attach.verb() }

        let detach = try #require(
            try parse(["usb", "detach", "Alpha", "hub"]) as? KernovaCommand.USB.Detach)
        #expect(throws: CLIFailure.self) { try detach.verb() }
    }

    @Test("get takes any number of keys, and all of them when given none")
    func getParsesItsKeys() throws {
        let everything = try #require(try parse(["get", "Alpha"]) as? KernovaCommand.Get)
        #expect(everything.vm == "Alpha")
        #expect(everything.keys.isEmpty)
        #expect(!everything.listingKeys)
        // Nothing named is the whole set, which is a different request from
        // naming zero keys explicitly — there is no way to type the latter.
        #expect(try everything.verb() == .configuration(.idOrName("Alpha"), keys: nil))

        let named = try #require(
            try parse(["get", "Alpha", "cpus", "memory"]) as? KernovaCommand.Get)
        #expect(named.keys == ["cpus", "memory"])
        #expect(
            try named.verb() == .configuration(.idOrName("Alpha"), keys: ["cpus", "memory"]))
    }

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
            try KernovaCommand.Set.entries(from: ["cpus=4", "network.mode=shared"]) == [
                ConfigurationEntry(key: "cpus", value: "4"),
                ConfigurationEntry(key: "network.mode", value: "shared"),
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

    @Test("set refuses a line that assigns nothing")
    func setNeedsAnAssignment() {
        #expect(throws: (any Error).self) { try parse(["set", "Alpha"]) }
        #expect(throws: (any Error).self) { try parse(["set"]) }
    }

    @Test("set carries --yes as the consent one setting asks for")
    func setCarriesItsConsent() throws {
        let bare = try #require(try parse(["set", "Alpha", "cpus=4"]) as? KernovaCommand.Set)
        #expect(
            try bare.verb()
                == .setConfiguration(
                    .idOrName("Alpha"), assignments: [ConfigurationEntry(key: "cpus", value: "4")],
                    confirmed: false))

        let consented = try #require(
            try parse(["set", "Alpha", "clipboard.passthrough=true", "--yes"])
                as? KernovaCommand.Set)
        #expect(
            try consented.verb()
                == .setConfiguration(
                    .idOrName("Alpha"),
                    assignments: [ConfigurationEntry(key: "clipboard.passthrough", value: "true")],
                    confirmed: true))
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

    @Test("A mapping is read as host:guest, on TCP unless --udp says otherwise")
    func forwardParsesItsMapping() throws {
        let tcp = try #require(
            try parse(["forward", "add", "Alpha", "8080:80"]) as? KernovaCommand.Forward.Add)
        #expect(!tcp.udp)
        #expect(
            try tcp.verb()
                == .editPortForwarding(
                    .idOrName("Alpha"),
                    .add(rule: PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 80))))

        let udp = try #require(
            try parse(["forward", "add", "Alpha", "5353:53", "--udp"])
                as? KernovaCommand.Forward.Add)
        #expect(udp.udp)
        #expect(
            try udp.verb()
                == .editPortForwarding(
                    .idOrName("Alpha"),
                    .add(rule: PortForwardingRule(transport: .udp, hostPort: 5353, guestPort: 53))))
    }

    @Test("A rule is dropped by its host-side claim, which the transport is half of")
    func forwardRemoveNamesTheHostClaim() throws {
        let tcp = try #require(
            try parse(["forward", "remove", "Alpha", "8080:80"]) as? KernovaCommand.Forward.Remove)
        #expect(
            try tcp.verb()
                == .editPortForwarding(
                    .idOrName("Alpha"),
                    .remove(claim: PortForwardingHostClaim(transport: .tcp, hostPort: 8080))))

        let udp = try #require(
            try parse(["forward", "remove", "Alpha", "5353:53", "--udp"])
                as? KernovaCommand.Forward.Remove)
        #expect(
            try udp.verb()
                == .editPortForwarding(
                    .idOrName("Alpha"),
                    .remove(claim: PortForwardingHostClaim(transport: .udp, hostPort: 5353))))
    }

    @Test("Every port a mapping names is one a service can answer on")
    func mappingsRefuseAPortNoServiceAnswersOn() throws {
        #expect(
            try PortMapping.rule(from: "1:65535", transport: .tcp)
                == PortForwardingRule(transport: .tcp, hostPort: 1, guestPort: 65535))

        // Port 0 addresses no service, so it is refused rather than clamped
        // into the range like the rest.
        for mapping in ["8080", "8080:", ":80", "8080:80:90", "a:80", "0:80", "80:0", "70000:80"] {
            do {
                _ = try PortMapping.rule(from: mapping, transport: .tcp)
                Issue.record("expected a usage refusal for \u{201C}\(mapping)\u{201D}")
            } catch let failure as CLIFailure {
                #expect(failure.code == .usage)
                #expect(failure.message.contains(mapping))
            } catch {
                Issue.record("expected a CLIFailure, got \(error)")
            }
        }
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

    @Test("stop takes --timeout, and waits for nothing without one")
    func stopParsesTimeout() throws {
        let bare = try #require(try parse(["stop", "Alpha"]) as? KernovaCommand.Stop)
        #expect(bare.timeout == nil)

        let bounded = try #require(
            try parse(["stop", "Alpha", "--timeout", "45"]) as? KernovaCommand.Stop)
        #expect(bounded.timeout == 45)
    }

    @Test("A deadline rides any stop method, including --force")
    func stopTimeoutRidesEveryMethod() throws {
        // The deadline bounds the wait for the guest to actually power off,
        // which every disposition has to travel — a force stop simply gets
        // there in one step.
        for method in ["--force", "--graceful", "--resume-first"] {
            let stop = try #require(
                try parse(["stop", "Alpha", method, "--timeout", "5"]) as? KernovaCommand.Stop)
            #expect(stop.timeout == 5)
        }
    }

    @Test("restart takes --timeout, and waits out the shutdown without one")
    func restartParsesTimeout() throws {
        let bare = try #require(try parse(["restart", "Alpha"]) as? KernovaCommand.Restart)
        #expect(bare.timeout == nil)

        let bounded = try #require(
            try parse(["restart", "Alpha", "--timeout", "20"]) as? KernovaCommand.Restart)
        #expect(bounded.timeout == 20)
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

    @Test("ip refuses a non-address in both formats, never exiting 0 on one")
    func ipRefusesANonAddressInEveryFormat() throws {
        // `--format json` renders the same value the table would; it must not
        // turn a refusal into a success just because JSON could describe it.
        for absent: GuestIPAddress in [.pending, .externallyAssigned, .unavailable] {
            #expect(throws: CLIFailure.self) {
                try KernovaCommand.IP.line(for: absent, vm: "Alpha")
            }
            // The JSON renderer itself never refuses — the classification above
            // is what both formats share, which is why it runs first.
            #expect(throws: Never.self) { try JSONRenderer.render(absent) }
        }
        #expect(try KernovaCommand.IP.line(for: .reserved("10.0.0.2"), vm: "Alpha") == "10.0.0.2")
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
