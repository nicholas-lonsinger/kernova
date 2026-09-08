import ArgumentParser
import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// How many times a completion opened a connection.
private final class ConnectionCount {
    var value = 0
}

/// What a Tab press reads back off the line, what it asks the app for, and how
/// it hands the answer to each shell.
@Suite("CLI completion", .admissionGated)
struct CLICompletionTests {
    private let alpha = VMSummary(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
        name: "Alpha", status: "running", ipAddress: .reserved("192.168.64.4"))
    private let beta = VMSummary(
        id: UUID(uuidString: "66666666-7777-8888-9999-000000000000") ?? UUID(),
        name: "Beta", status: "stopped", ipAddress: .unavailable)

    private let shares = [
        SharedDirectorySummary(path: "/Users/somebody/Sites", readOnly: false),
        SharedDirectorySummary(path: "/Users/somebody/Reference", readOnly: true),
    ]
    private let rules = [
        PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 80),
        PortForwardingRule(transport: .udp, hostPort: 5353, guestPort: 53),
    ]

    private var checkpoint: SnapshotSummary {
        SnapshotSummary(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee") ?? UUID(),
            name: "Before Update", notes: "", kind: "warm", createdAt: Date(timeIntervalSince1970: 0),
            isCurrent: true, isEphemeralBaseline: false)
    }

    /// A context onto `listener`, with the generous deadline every wait in this
    /// bundle uses rather than the two seconds a person at a keyboard gets.
    private func context(
        to listener: TestCommandSocket, asking shell: CompletionShell? = nil
    ) -> CompletionContext {
        CompletionContext(
            connect: { try VMCommandClient(socketPath: listener.path) },
            deadline: testWaitBackstop, shell: shell)
    }

    // MARK: - Reading the line back

    @Test("A snapshot completion recovers the virtual machine named before it")
    func snapshotCompletionReadsTheVM() throws {
        let subject = CompletionLine.vmSubject(
            in: ["kernova", "snapshot", "revert", "Alpha", ""], completingAt: 4)

        #expect(subject?.vm == "Alpha")
        #expect(subject?.byIdentifier == false)
    }

    @Test("Flags on either side of the virtual machine do not hide it")
    func snapshotCompletionReadsPastFlags() throws {
        let leading = CompletionLine.vmSubject(
            in: ["kernova", "snapshot", "delete", "--yes", "Alpha", ""], completingAt: 5)
        #expect(leading?.vm == "Alpha")

        let trailing = CompletionLine.vmSubject(
            in: ["kernova", "snapshot", "revert", "Alpha", "--no-checkpoint", ""], completingAt: 5)
        #expect(trailing?.vm == "Alpha")
    }

    @Test("A share and a forward removal each recover the virtual machine named before them")
    func removalCompletionsReadTheVM() throws {
        let share = CompletionLine.vmSubject(
            in: ["kernova", "share", "remove", "Alpha", ""], completingAt: 4)
        #expect(share?.vm == "Alpha")
        #expect(share?.command is KernovaCommand.Share.Remove)

        let forward = CompletionLine.vmSubject(
            in: ["kernova", "forward", "remove", "Alpha", ""], completingAt: 4)
        #expect(forward?.vm == "Alpha")
        #expect(forward?.command is KernovaCommand.Forward.Remove)
    }

    @Test("A forward removal's transport flag is read back off the line with its machine")
    func forwardRemovalReadsItsTransport() throws {
        let tcp = CompletionLine.vmSubject(
            in: ["kernova", "forward", "remove", "Alpha", ""], completingAt: 4)
        #expect((tcp?.command as? KernovaCommand.Forward.Remove)?.udp == false)

        let udp = CompletionLine.vmSubject(
            in: ["kernova", "forward", "remove", "Alpha", "--udp", ""], completingAt: 5)
        #expect((udp?.command as? KernovaCommand.Forward.Remove)?.udp == true)
    }

    @Test("--id is read off the line, wherever it sits")
    func theLineCarriesItsIdentifierFlag() throws {
        #expect(
            CompletionLine.forcesIdentifiers(in: ["kernova", "start", ""], completingAt: 2) == false)
        #expect(
            CompletionLine.forcesIdentifiers(in: ["kernova", "start", "--id", ""], completingAt: 3))
        // The virtual machine is still unwritten here, so the line only parses
        // once the arguments after the cursor are stood in for.
        #expect(
            CompletionLine.forcesIdentifiers(
                in: ["kernova", "snapshot", "rename", "--id", ""], completingAt: 4))

        let subject = CompletionLine.vmSubject(
            in: ["kernova", "snapshot", "delete", "--id", alpha.id.uuidString, ""],
            completingAt: 5)
        #expect(subject?.byIdentifier == true)
    }

    @Test("A quoted virtual machine name arrives without its quotes")
    func aQuotedNameIsDequoted() throws {
        // The shell hands the word over verbatim, and every clone is named
        // "<base> Copy", so this is the ordinary case rather than a corner.
        let singleQuoted = CompletionLine.vmSubject(
            in: ["kernova", "snapshot", "revert", "'Alpha Copy'", ""], completingAt: 4)
        #expect(singleQuoted?.vm == "Alpha Copy")

        let doubleQuoted = CompletionLine.vmSubject(
            in: ["kernova", "snapshot", "revert", "\"Alpha Copy\"", ""], completingAt: 4)
        #expect(doubleQuoted?.vm == "Alpha Copy")

        let escaped = CompletionLine.vmSubject(
            in: ["kernova", "snapshot", "revert", "Alpha\\ Copy", ""], completingAt: 4)
        #expect(escaped?.vm == "Alpha Copy")

        // A backslash inside single quotes is a character like any other.
        let literal = CompletionLine.vmSubject(
            in: ["kernova", "snapshot", "revert", "'Alpha\\Copy'", ""], completingAt: 4)
        #expect(literal?.vm == "Alpha\\Copy")
    }

    @Test("A set assignment offers keys before the = and nothing after it")
    func anAssignmentStopsOfferingKeysAtTheSeparator() throws {
        #expect(
            !CompletionLine.isPastAnAssignmentKey(
                in: ["kernova", "set", "Alpha", "cpu"], completingAt: 3, prefix: "cpu"))
        #expect(
            CompletionLine.isPastAnAssignmentKey(
                in: ["kernova", "set", "Alpha", "cpus=4"], completingAt: 3, prefix: "cpus="))
        // bash holds `=` in COMP_WORDBREAKS, so `cpus=` reaches the tool as
        // three words and the prefix carries none of the key.
        #expect(
            CompletionLine.isPastAnAssignmentKey(
                in: ["kernova", "set", "Alpha", "cpus", "=", ""], completingAt: 5, prefix: ""))
    }

    @Test("A line the grammar does not accept completes nothing")
    func anUnparseableLineHasNoSubject() throws {
        #expect(
            CompletionLine.command(from: ["kernova", "nonsense", ""], completingAt: 2) == nil)
        // `snapshot list` takes one positional, so nothing on it names a
        // snapshot to complete.
        #expect(
            CompletionLine.vmSubject(
                in: ["kernova", "snapshot", "list", "Alpha", ""], completingAt: 4) == nil)
        // A snapshot argument reached before its virtual machine was typed.
        #expect(
            CompletionLine.vmSubject(
                in: ["kernova", "snapshot", "revert", ""], completingAt: 3) == nil)
        // The list verbs take the machine and nothing of the machine's, and
        // both removals reached before their machine was typed name none.
        #expect(
            CompletionLine.vmSubject(
                in: ["kernova", "share", "list", "Alpha", ""], completingAt: 4) == nil)
        #expect(
            CompletionLine.vmSubject(
                in: ["kernova", "share", "remove", ""], completingAt: 3) == nil)
        #expect(
            CompletionLine.vmSubject(
                in: ["kernova", "forward", "remove", ""], completingAt: 3) == nil)
    }

    // MARK: - Asking the app

    @Test("Nothing listening is no candidates, not a refusal")
    func aStoppedAppOffersNothing() throws {
        let unreachable = CompletionContext(
            connect: { throw CLIFailure(.unavailable, "no app group") }, deadline: testWaitBackstop,
            shell: .zsh)

        #expect(CompletionSource.vmNames(byIdentifier: false, in: unreachable).isEmpty)
        #expect(
            CompletionSource.snapshotNames(ofVM: "Alpha", byIdentifier: false, in: unreachable)
                .isEmpty)
        #expect(
            CompletionSource.sharedDirectoryPaths(
                ofVM: "Alpha", byIdentifier: false, in: unreachable
            ).isEmpty)
        #expect(
            CompletionSource.portMappings(
                ofVM: "Alpha", byIdentifier: false, transport: .tcp, in: unreachable
            ).isEmpty)
        #expect(CompletionSource.configurationKeys(in: unreachable).isEmpty)
    }

    @Test("The library listing is what a virtual machine argument offers")
    func vmNamesComeFromTheLibrary() throws {
        let listener = try TestCommandSocket(tag: "cmp-vms")
        defer { listener.close() }
        listener.serve([VMCommandResponse(result: .summaries([alpha, beta]))])

        let names = CompletionSource.vmNames(byIdentifier: false, in: context(to: listener))

        #expect(names == ["Alpha", "Beta"])
        #expect(listener.requests().map(\.verb) == [.list])
    }

    @Test("--id offers the identifiers the same listing carries")
    func vmIdentifiersComeFromTheSameListing() throws {
        let listener = try TestCommandSocket(tag: "cmp-vm-ids")
        defer { listener.close() }
        listener.serve([VMCommandResponse(result: .summaries([alpha]))])

        let names = CompletionSource.vmNames(byIdentifier: true, in: context(to: listener))

        #expect(names == [alpha.id.uuidString])
    }

    @Test("A snapshot argument offers the named machine's own restore points")
    func snapshotNamesComeFromTheMachine() throws {
        let listener = try TestCommandSocket(tag: "cmp-snaps")
        defer { listener.close() }
        listener.serve([VMCommandResponse(result: .snapshots([checkpoint]))])

        let names = CompletionSource.snapshotNames(
            ofVM: "Alpha", byIdentifier: false, in: context(to: listener))

        #expect(names == ["Before Update"])
        // The listing alone: the size walk a `snapshot list` performs would
        // spend a second round trip on a column nobody is completing.
        #expect(listener.requests().map(\.verb) == [.snapshots(.idOrName("Alpha"))])
    }

    @Test("A share removal offers the folders that machine actually shares")
    func sharedDirectoryPathsComeFromTheMachine() throws {
        let listener = try TestCommandSocket(tag: "cmp-shares")
        defer { listener.close() }
        listener.serve([VMCommandResponse(result: .sharedDirectories(shares))])

        let paths = CompletionSource.sharedDirectoryPaths(
            ofVM: "Alpha", byIdentifier: false, in: context(to: listener))

        #expect(paths == ["/Users/somebody/Sites", "/Users/somebody/Reference"])
        #expect(listener.requests().map(\.verb) == [.sharedDirectories(.idOrName("Alpha"))])
    }

    @Test("zsh is told which of the shared folders the guest may write to")
    func sharedFoldersCarryTheirAccess() throws {
        let listener = try TestCommandSocket(tag: "cmp-shares-zsh")
        defer { listener.close() }
        listener.serve([VMCommandResponse(result: .sharedDirectories(shares))])

        let paths = CompletionSource.sharedDirectoryPaths(
            ofVM: "Alpha", byIdentifier: false, in: context(to: listener, asking: .zsh))

        #expect(
            paths == [
                "/Users/somebody/Sites:read-write", "/Users/somebody/Reference:read-only",
            ])
    }

    @Test("A forward removal offers only the mappings on the transport it will drop from")
    func portMappingsAreFilteredByTransport() throws {
        let tcp = try TestCommandSocket(tag: "cmp-fwd-tcp")
        defer { tcp.close() }
        tcp.serve([VMCommandResponse(result: .portForwardingRules(rules))])
        #expect(
            CompletionSource.portMappings(
                ofVM: "Alpha", byIdentifier: false, transport: .tcp, in: context(to: tcp))
                == ["8080:80"])
        #expect(tcp.requests().map(\.verb) == [.portForwardingRules(.idOrName("Alpha"))])

        let udp = try TestCommandSocket(tag: "cmp-fwd-udp")
        defer { udp.close() }
        udp.serve([VMCommandResponse(result: .portForwardingRules(rules))])
        #expect(
            CompletionSource.portMappings(
                ofVM: "Alpha", byIdentifier: false, transport: .udp, in: context(to: udp))
                == ["5353:53"])
    }

    @Test("A mapping's colon is escaped for zsh, which reads an unescaped one as the description")
    func portMappingsKeepTheirColonForZsh() throws {
        let listener = try TestCommandSocket(tag: "cmp-fwd-zsh")
        defer { listener.close() }
        listener.serve([VMCommandResponse(result: .portForwardingRules(rules))])

        let mappings = CompletionSource.portMappings(
            ofVM: "Alpha", byIdentifier: false, transport: .udp,
            in: context(to: listener, asking: .zsh))

        #expect(mappings == ["5353\\:53:UDP"])
    }

    @Test("Under --id a virtual machine argument that is not one asks nothing")
    func anUnparseableIdentifierAsksNothing() throws {
        let opened = ConnectionCount()
        let counting = CompletionContext(
            connect: {
                opened.value += 1
                return nil
            }, deadline: testWaitBackstop, shell: nil)

        let names = CompletionSource.snapshotNames(
            ofVM: "Alpha", byIdentifier: true, in: counting)

        #expect(names.isEmpty)
        // The selector is refused client-side, so the app is never reached.
        #expect(opened.value == 0)
    }

    @Test("A refusal is no candidates, not a refusal printed into the line")
    func aRefusedReadOffersNothing() throws {
        let listener = try TestCommandSocket(tag: "cmp-refused")
        defer { listener.close() }
        listener.serve([
            VMCommandResponse(
                result: .failure(.ambiguous(selector: .idOrName("Alpha"), candidates: [alpha, beta])))
        ])

        let names = CompletionSource.snapshotNames(
            ofVM: "Alpha", byIdentifier: false, in: context(to: listener))

        #expect(names.isEmpty)
    }

    @Test("An app that takes the request and never answers offers nothing")
    func aSilentAppOffersNothing() throws {
        let listener = try TestCommandSocket(tag: "cmp-silent")
        defer { listener.close() }
        // Answers nothing and keeps the connection, which is the app that is
        // running but not getting back to it. The deadline is short because it
        // is what is under test.
        listener.serve([], holdingOpen: true)
        let silent = CompletionContext(
            connect: { try VMCommandClient(socketPath: listener.path) }, deadline: 0.5, shell: nil)

        #expect(CompletionSource.vmNames(byIdentifier: false, in: silent).isEmpty)
        #expect(listener.requests().map(\.verb) == [.list])
    }

    @Test("zsh is answered with each value's description beside it")
    func zshGetsDescribedCandidates() throws {
        let listener = try TestCommandSocket(tag: "cmp-zsh")
        defer { listener.close() }
        listener.serve([VMCommandResponse(result: .summaries([alpha, beta]))])

        let names = CompletionSource.vmNames(
            byIdentifier: false, in: context(to: listener, asking: .zsh))

        #expect(names == ["Alpha:running", "Beta:stopped"])
    }

    @Test("get and set offer the keyspace, set with the = its value follows")
    func keysComeFromTheKeyspace() throws {
        let keyspace = [
            ConfigurationKeyDescriptor(
                name: "cpus", summary: "Virtual CPU cores.", editableWhileRunning: false)
        ]

        let plain = try TestCommandSocket(tag: "cmp-keys")
        defer { plain.close() }
        plain.serve([VMCommandResponse(result: .configurationKeys(keyspace))])
        #expect(CompletionSource.configurationKeys(in: context(to: plain)) == ["cpus"])
        #expect(plain.requests().map(\.verb) == [.configurationKeys])

        let assigning = try TestCommandSocket(tag: "cmp-keys-eq")
        defer { assigning.close() }
        assigning.serve([VMCommandResponse(result: .configurationKeys(keyspace))])
        #expect(
            CompletionSource.configurationKeys(suffix: "=", in: context(to: assigning))
                == ["cpus="])
    }

    // MARK: - Handing them to a shell

    @Test("zsh takes a description beside each value; bash and fish take the value")
    func onlyZshIsGivenDescriptions() {
        #expect(CompletionSource.candidate("Alpha", describedBy: "running", for: .zsh) == "Alpha:running")
        #expect(CompletionSource.candidate("Alpha", describedBy: "running", for: .bash) == "Alpha")
        #expect(CompletionSource.candidate("Alpha", describedBy: "running", for: .fish) == "Alpha")
        #expect(CompletionSource.candidate("Alpha", describedBy: "running", for: nil) == "Alpha")
    }

    @Test("A colon inside a zsh value is escaped rather than left to split it")
    func zshValuesKeepTheirColons() {
        // `_describe` reads the first unescaped colon as the end of the value,
        // so an unescaped one would offer "Beta" described as "Two".
        #expect(
            CompletionSource.candidate("Beta:Two", describedBy: "stopped", for: .zsh)
                == "Beta\\:Two:stopped")
        #expect(
            CompletionSource.candidate("Back\\slash", describedBy: "stopped", for: .zsh)
                == "Back\\\\slash:stopped")
        #expect(CompletionSource.candidate("Beta:Two", describedBy: "stopped", for: .bash) == "Beta:Two")
    }

    @Test("A value with nothing to say about it carries no empty description")
    func anEmptyDescriptionIsOmitted() {
        #expect(CompletionSource.candidate("Alpha", describedBy: "", for: .zsh) == "Alpha")
    }
}
