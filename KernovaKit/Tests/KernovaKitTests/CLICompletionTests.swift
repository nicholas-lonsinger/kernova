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

    private var checkpoint: SnapshotSummary {
        SnapshotSummary(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee") ?? UUID(),
            name: "Before Update", notes: "", kind: "warm", createdAt: Date(timeIntervalSince1970: 0),
            isCurrent: true, isEphemeralBaseline: false)
    }

    /// A channel onto `listener`, with the generous deadline every wait in this
    /// bundle uses rather than the two seconds a person at a keyboard gets.
    private func channel(to listener: TestCommandSocket) -> CompletionChannel {
        CompletionChannel(
            connect: { try VMCommandClient(socketPath: listener.path) },
            deadline: testWaitBackstop)
    }

    // MARK: - Reading the line back

    @Test("A snapshot completion recovers the virtual machine named before it")
    func snapshotCompletionReadsTheVM() throws {
        let subject = CompletionLine.snapshotSubject(
            in: ["kernova", "snapshot", "revert", "Alpha", ""], completingAt: 4)

        #expect(subject?.vm == "Alpha")
        #expect(subject?.byIdentifier == false)
    }

    @Test("Flags on either side of the virtual machine do not hide it")
    func snapshotCompletionReadsPastFlags() throws {
        let leading = CompletionLine.snapshotSubject(
            in: ["kernova", "snapshot", "delete", "--yes", "Alpha", ""], completingAt: 5)
        #expect(leading?.vm == "Alpha")

        let trailing = CompletionLine.snapshotSubject(
            in: ["kernova", "snapshot", "revert", "Alpha", "--no-checkpoint", ""], completingAt: 5)
        #expect(trailing?.vm == "Alpha")
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

        let subject = CompletionLine.snapshotSubject(
            in: ["kernova", "snapshot", "delete", "--id", alpha.id.uuidString, ""],
            completingAt: 5)
        #expect(subject?.byIdentifier == true)
    }

    @Test("A line the grammar does not accept completes nothing")
    func anUnparseableLineHasNoSubject() throws {
        #expect(
            CompletionLine.command(from: ["kernova", "nonsense", ""], completingAt: 2) == nil)
        // `snapshot list` takes one positional, so nothing on it names a
        // snapshot to complete.
        #expect(
            CompletionLine.snapshotSubject(
                in: ["kernova", "snapshot", "list", "Alpha", ""], completingAt: 4) == nil)
        // A snapshot argument reached before its virtual machine was typed.
        #expect(
            CompletionLine.snapshotSubject(
                in: ["kernova", "snapshot", "revert", ""], completingAt: 3) == nil)
    }

    // MARK: - Asking the app

    @Test("Nothing listening is no candidates, not a refusal")
    func aStoppedAppOffersNothing() throws {
        let unreachable = CompletionChannel(
            connect: { throw CLIFailure(.unavailable, "no app group") }, deadline: testWaitBackstop)

        #expect(CompletionSource.vmNames(byIdentifier: false, over: unreachable).isEmpty)
        #expect(
            CompletionSource.snapshotNames(ofVM: "Alpha", byIdentifier: false, over: unreachable)
                .isEmpty)
        #expect(CompletionSource.configurationKeys(over: unreachable).isEmpty)
    }

    @Test("The library listing is what a virtual machine argument offers")
    func vmNamesComeFromTheLibrary() throws {
        let listener = try TestCommandSocket(tag: "cmp-vms")
        defer { listener.close() }
        listener.serve([VMCommandResponse(result: .summaries([alpha, beta]))])

        let names = CompletionSource.vmNames(byIdentifier: false, over: channel(to: listener))

        #expect(names == ["Alpha", "Beta"])
        #expect(listener.requests().map(\.verb) == [.list])
    }

    @Test("--id offers the identifiers the same listing carries")
    func vmIdentifiersComeFromTheSameListing() throws {
        let listener = try TestCommandSocket(tag: "cmp-vm-ids")
        defer { listener.close() }
        listener.serve([VMCommandResponse(result: .summaries([alpha]))])

        let names = CompletionSource.vmNames(byIdentifier: true, over: channel(to: listener))

        #expect(names == [alpha.id.uuidString])
    }

    @Test("A snapshot argument offers the named machine's own restore points")
    func snapshotNamesComeFromTheMachine() throws {
        let listener = try TestCommandSocket(tag: "cmp-snaps")
        defer { listener.close() }
        listener.serve([VMCommandResponse(result: .snapshots([checkpoint]))])

        let names = CompletionSource.snapshotNames(
            ofVM: "Alpha", byIdentifier: false, over: channel(to: listener))

        #expect(names == ["Before Update"])
        // The listing alone: the size walk a `snapshot list` performs would
        // spend a second round trip on a column nobody is completing.
        #expect(listener.requests().map(\.verb) == [.snapshots(.idOrName("Alpha"))])
    }

    @Test("Under --id a virtual machine argument that is not one asks nothing")
    func anUnparseableIdentifierAsksNothing() throws {
        let opened = ConnectionCount()
        let counting = CompletionChannel(
            connect: {
                opened.value += 1
                return nil
            }, deadline: testWaitBackstop)

        let names = CompletionSource.snapshotNames(
            ofVM: "Alpha", byIdentifier: true, over: counting)

        #expect(names.isEmpty)
        // The selector is refused client-side, so the app is never reached.
        #expect(opened.value == 0)
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
        #expect(CompletionSource.configurationKeys(over: channel(to: plain)) == ["cpus"])
        #expect(plain.requests().map(\.verb) == [.configurationKeys])

        let assigning = try TestCommandSocket(tag: "cmp-keys-eq")
        defer { assigning.close() }
        assigning.serve([VMCommandResponse(result: .configurationKeys(keyspace))])
        #expect(
            CompletionSource.configurationKeys(suffix: "=", over: channel(to: assigning))
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
