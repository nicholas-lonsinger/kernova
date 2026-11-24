import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// What each verb whose whole request its command line decides actually puts on
/// the wire, against a real socket.
@Suite("CLI verb wire", .caseScoped)
struct CLIVerbWireTests {
    private let alpha = VMSummary(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
        name: "Alpha", status: "running", ipAddress: .observed("192.168.64.4"), heldByAnotherCopy: false)

    private var info: VMInfo {
        VMInfo(
            id: alpha.id, name: "Alpha", status: "running", guestOS: "macOS", cpuCount: 4,
            memoryBytes: 8 << 30, networkMode: "nat", networkMembership: "common",
            networkName: nil, macAddress: "aa:bb:cc:dd:ee:ff",
            ipAddress: .observed("192.168.64.4"),
            agentStatus: "current", hasSavedState: false, savedStateKernovaVersion: nil, isEphemeral: true,
            snapshotCount: 2, hasSnapshots: false,
            guestAgent: nil, stateBucket: .stopped,
            bundlePath: "/Users/somebody/VMs/Alpha.kernova", heldByAnotherCopy: false)
    }

    /// The answer the verbs that print nothing are given.
    private let accepted = VMCommandResponse(result: .ok)

    // MARK: - Reads

    @Test("list crosses as one query: repeated flags an include-set, different flags each constraining")
    func listSendsItsFilter() async throws {
        let exchanged = try await CLIWire.exchange(
            [
                "list", "--os", "linux", "--state", "running", "--state", "heldByAnotherCopy",
                "--network", "nat", "--network", "unlisted", "--network", "Lab",
                "--agent", "olderVersion", "--ephemeral", "--has-snapshots",
                "--smart-group", "Linux Lab", "--sort", "dateCreated",
            ],
            answering: VMCommandResponse(result: .summaries([alpha])))

        let expected = VMListQuery(
            filter: VMLibraryFilter(
                guestOSes: [.linux], states: [.running, .heldByAnotherCopy],
                guestAgents: [.olderVersion], ephemeralOnly: true, withSnapshotsOnly: true),
            networks: ["nat", "unlisted", "Lab"], tags: [],
            groups: [VMGroupReference(.smartGroup, named: "Linux Lab")], sort: .dateCreated)
        #expect(exchanged.sent == [.list(expected)])
        #expect(try exchanged.answer.payload() == .summaries([alpha]))
    }

    @Test("info asks for the VM its argument names, then its disks by the identifier that answered")
    func infoAsksForTheVMThenItsDisks() async throws {
        let disks = [
            StorageDiskSummary(
                id: alpha.id, label: "Main Disk", kind: "virtio", readOnly: false,
                path: "/Users/somebody/VMs/Alpha.kernova/Disk.asif", notes: "",
                capacityBytes: 100_000_000_000, usedBytes: 10_100_000_000)
        ]
        let answers = [VMCommandResponse(result: .info(info)), VMCommandResponse(result: .storageDisks(disks))]

        let named = try await infoExchange(["info", "Alpha"], answering: answers)
        #expect(named.sent == [.info(.idOrName("Alpha")), .storageDisks(.id(alpha.id))])
        #expect(named.printed.contains("Main Disk: 100 GB, 10.1 GB used"))

        let byID = try await infoExchange(["info", alpha.id.uuidString, "--id"], answering: answers)
        #expect(byID.sent == [.info(.id(alpha.id)), .storageDisks(.id(alpha.id))])

        let json = try await infoExchange(["info", "Alpha", "--format", "json", "--quiet"], answering: answers)
        #expect(json.sent == [.info(.idOrName("Alpha")), .storageDisks(.id(alpha.id))])
        #expect(json.printed.contains("\"storageDisks\""))
    }

    @Test("--quiet on info prints the name alone, and reads no disks for it")
    func quietInfoIsTheNameAlone() async throws {
        let quiet = try await infoExchange(
            ["info", "Alpha", "--quiet"], answering: [VMCommandResponse(result: .info(info))])

        #expect(quiet.sent == [.info(.idOrName("Alpha"))])
        #expect(quiet.printed == "Alpha")
    }

    /// What `info` with `arguments` asks a double answering `answers` for, and
    /// what it would print.
    private func infoExchange(
        _ arguments: [String], answering answers: [VMCommandResponse]
    ) async throws -> (sent: [VMCommandRequest.Verb], printed: String) {
        let command = try #require(try KernovaCommand.parseAsRoot(arguments) as? KernovaCommand.Info)
        let listener = try TestCommandSocket()
        defer { listener.close() }
        let client = try VMCommandClient(socketPath: listener.path)
        defer { client.close() }
        client.waitForFrames(upTo: testWaitBackstop)
        listener.serve(answers)

        let printed = try command.output(for: try command.selector(), from: client)
        return (try await listener.requests().map(\.verb), printed)
    }

    @Test("info --id on something that is not an identifier refuses as a usage error before it connects")
    func infoRefusesANonIdentifierBeforeConnecting() throws {
        let command = try #require(
            try KernovaCommand.parseAsRoot(["info", "not-a-uuid", "--id"]) as? KernovaCommand.Info)

        do {
            _ = try command.selector()
            Issue.record("expected a usage refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == .usage)
            #expect(failure.message.contains("not-a-uuid"))
        }
    }

    // MARK: - Lifecycle

    @Test("start crosses carrying --recovery when the line asks for it, and --yes as every consent")
    func startSendsItsRecoveryFlag() async throws {
        let plain = try await CLIWire.exchange(["start", "Alpha"], answering: accepted)
        #expect(
            plain.sent == [
                .start(.idOrName("Alpha"), recovery: false, consent: .none)
            ])
        #expect(try plain.answer.payload() == .ok)

        let recovery = try await CLIWire.exchange(
            ["start", "Alpha", "--recovery"], answering: accepted)
        #expect(
            recovery.sent == [
                .start(.idOrName("Alpha"), recovery: true, consent: .none)
            ])

        let anyway = try await CLIWire.exchange(["start", "Alpha", "--yes"], answering: accepted)
        #expect(
            anyway.sent == [
                .start(.idOrName("Alpha"), recovery: false, consent: .all)
            ])
    }

    @Test("stop crosses with the disposition its method names, its consent, and its deadline")
    func stopSendsItsDispositionAndDeadline() async throws {
        let graceful = try await CLIWire.exchange(["stop", "Alpha"], answering: accepted)
        #expect(
            graceful.sent == [
                .stop(
                    .idOrName("Alpha"), disposition: .graceful, consent: .none, timeout: nil)
            ])

        let forced = try await CLIWire.exchange(
            ["stop", "Alpha", "--force", "--yes", "--timeout", "30"], answering: accepted)
        #expect(
            forced.sent == [
                .stop(.idOrName("Alpha"), disposition: .force, consent: .all, timeout: 30)
            ])
    }

    @Test("resume crosses as the verb that lets a paused guest run again, --yes as every consent")
    func resumeSendsItsVerb() async throws {
        let exchanged = try await CLIWire.exchange(
            ["resume", "Alpha"], answering: accepted)
        #expect(exchanged.sent == [.resume(.idOrName("Alpha"), consent: .none)])

        let anyway = try await CLIWire.exchange(["resume", "Alpha", "--yes"], answering: accepted)
        #expect(anyway.sent == [.resume(.idOrName("Alpha"), consent: .all)])
    }

    @Test("restart crosses with the deadline bounding its shutdown half")
    func restartSendsItsDeadline() async throws {
        let bare = try await CLIWire.exchange(["restart", "Alpha"], answering: accepted)
        #expect(
            bare.sent == [
                .restart(.idOrName("Alpha"), disposition: .graceful, timeout: nil, consent: .none)
            ])

        let bounded = try await CLIWire.exchange(
            ["restart", "Alpha", "--timeout", "45"], answering: accepted)
        #expect(
            bounded.sent == [
                .restart(.idOrName("Alpha"), disposition: .graceful, timeout: 45, consent: .none)
            ])

        let anyway = try await CLIWire.exchange(["restart", "Alpha", "--yes"], answering: accepted)
        #expect(
            anyway.sent == [
                .restart(.idOrName("Alpha"), disposition: .graceful, timeout: nil, consent: .all)
            ])
    }

    // MARK: - Library

    @Test("delete crosses to the Trash unless --permanent, and takes no external file with it")
    func deleteSendsItsDisposalAndConsent() async throws {
        let trashed = try await CLIWire.exchange(
            ["delete", "Alpha", "--yes"], answering: accepted)
        #expect(
            trashed.sent == [
                .delete(
                    .idOrName("Alpha"), permanently: false, alsoRemoving: [], consent: .all)
            ])

        let permanent = try await CLIWire.exchange(
            ["delete", "Alpha", "--permanent"], answering: accepted)
        #expect(
            permanent.sent == [
                .delete(
                    .idOrName("Alpha"), permanently: true, alsoRemoving: [], consent: .none)
            ])
    }

    // MARK: - Named networks

    private var lab: NetworkSummary {
        NetworkSummary(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID(), name: "Lab",
            kind: .hostOnly, members: [alpha])
    }

    @Test("network create crosses with its name and kind, the kind nat unless --kind names one")
    func networkCreateSendsItsKind() async throws {
        let answered = VMCommandResponse(result: .network(lab))

        let plain = try await CLIWire.exchange(["network", "create", "Lab"], answering: answered)
        #expect(plain.sent == [.createNetwork(name: "Lab", kind: .nat)])
        #expect(try plain.answer.payload() == .network(lab))

        let hostOnly = try await CLIWire.exchange(
            ["network", "create", "Lab", "--kind", "hostOnly"], answering: answered)
        #expect(hostOnly.sent == [.createNetwork(name: "Lab", kind: .hostOnly)])
    }
}
