import ArgumentParser
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// How many times a completion opened a connection.
private final class ConnectionCount {
    var value = 0
}

/// What a Tab press reads back off the line, what it asks the app for, and how
/// it hands the answer to each shell.
@Suite("CLI completion", .caseScoped)
struct CLICompletionTests {
    private let alpha = VMSummary(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
        name: "Alpha", status: "running", ipAddress: .observed("192.168.64.4"), heldByAnotherCopy: false)
    private let beta = VMSummary(
        id: UUID(uuidString: "66666666-7777-8888-9999-000000000000") ?? UUID(),
        name: "Beta", status: "stopped", ipAddress: .unavailable, heldByAnotherCopy: false)

    private let shares = [
        SharedDirectorySummary(path: "/Users/somebody/Sites", readOnly: false),
        SharedDirectorySummary(path: "/Users/somebody/Reference", readOnly: true),
    ]
    private let accessories = [
        USBAccessorySummary(
            registryID: 4_294_967_296, name: "0403:6001 \u{00B7} Vendor-specific",
            vendorID: 0x0403, productID: 0x6001,
            deviceID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")),
        USBAccessorySummary(
            registryID: 12, name: "05ac:12a8 \u{00B7} Composite", vendorID: 0x05AC,
            productID: 0x12A8),
    ]

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
        // The list verb takes the machine and nothing of the machine's, and
        // a removal reached before its machine was typed names none.
        #expect(
            CompletionLine.vmSubject(
                in: ["kernova", "share", "list", "Alpha", ""], completingAt: 4) == nil)
        #expect(
            CompletionLine.vmSubject(
                in: ["kernova", "share", "remove", ""], completingAt: 3) == nil)
    }

    // MARK: - Asking the app

    @Test("zsh is told which of the shared folders the guest may write to")
    func sharedFoldersCarryTheirAccess() throws {
        let listener = try TestCommandSocket()
        defer { listener.close() }
        listener.serve([[VMCommandResponse(result: .sharedDirectories(shares))]])

        let paths = CompletionSource.sharedDirectoryPaths(
            ofVM: "Alpha", byIdentifier: false, in: context(to: listener, asking: .zsh))

        #expect(
            paths == [
                "/Users/somebody/Sites:read-write", "/Users/somebody/Reference:read-only",
            ])
    }

    @Test("A USB detachment offers only what the named machine is actually holding")
    func usbDevicesComeFromTheMachine() throws {
        let listener = try TestCommandSocket()
        defer { listener.close() }
        listener.serve([[VMCommandResponse(result: .usbAccessories(accessories))]])

        let devices = CompletionSource.usbAccessoryDevices(
            ofVM: "Alpha", byIdentifier: false, in: context(to: listener))

        // A row carrying no attachment is one no guest holds, so there is
        // nothing there to detach and nothing to offer.
        #expect(devices == ["AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"])
        #expect(try listener.requests().map(\.verb) == [.usbAccessories(.idOrName("Alpha"))])
    }

    @Test("A USB attachment offers the free accessories, described by what they are")
    func availableUSBAccessoriesComeFromTheHost() throws {
        let listener = try TestCommandSocket()
        defer { listener.close() }
        listener.serve([[VMCommandResponse(result: .usbAccessories([accessories[1]]))]])

        let offered = CompletionSource.availableUSBAccessories(
            in: context(to: listener, asking: .zsh))

        // Nothing tells two accessories apart by identifier, so the description
        // is what a person completes against.
        #expect(offered == ["12:05ac:12a8 \u{00B7} Composite"])
        #expect(try listener.requests().map(\.verb) == [.availableUSBAccessories])
    }

    @Test("Forgetting a USB accessory offers the keys the named machine remembers")
    func usbPairingKeysComeFromTheMachine() throws {
        let listener = try TestCommandSocket()
        defer { listener.close() }
        listener.serve([
            [
                VMCommandResponse(
                    result: .usbPairings([
                        USBPairingSummary(
                            vm: "Alpha", key: "04e8:6300:0100:0373", name: "Samsung Type-C",
                            pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
                    ]))
            ]
        ])

        let keys = CompletionSource.usbPairingKeys(
            ofVM: "Alpha", byIdentifier: false, in: context(to: listener, asking: .zsh))

        // The key carries colons, which zsh would otherwise read as the start
        // of the description.
        #expect(keys == ["04e8\\:6300\\:0100\\:0373:Samsung Type-C"])
        #expect(try listener.requests().map(\.verb) == [.usbPairings(.idOrName("Alpha"))])
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
        let paths = CompletionSource.sharedDirectoryPaths(
            ofVM: "Alpha", byIdentifier: true, in: counting)

        #expect(names.isEmpty)
        #expect(paths.isEmpty)
        // The selector is refused client-side, so the app is never reached.
        #expect(opened.value == 0)
    }

    @Test("zsh is answered with each value's description beside it")
    func zshGetsDescribedCandidates() throws {
        let listener = try TestCommandSocket()
        defer { listener.close() }
        listener.serve([[VMCommandResponse(result: .summaries([alpha, beta]))]])

        let names = CompletionSource.vmNames(
            byIdentifier: false, in: context(to: listener, asking: .zsh))

        #expect(names == ["Alpha:running", "Beta:stopped"])
    }

    @Test("get and set offer the keyspace, set with the = its value follows")
    func keysComeFromTheKeyspace() throws {
        let keyspace = [
            ConfigurationKeyDescriptor(
                name: "cpus", summary: "Virtual CPU cores.",
                editableWhileRunning: ["macOS": false, "linux": false])
        ]

        let plain = try TestCommandSocket()
        defer { plain.close() }
        plain.serve([[VMCommandResponse(result: .configurationKeys(keyspace))]])
        #expect(CompletionSource.configurationKeys(in: context(to: plain)) == ["cpus"])
        #expect(try plain.requests().map(\.verb) == [.configurationKeys])

        let assigning = try TestCommandSocket()
        defer { assigning.close() }
        assigning.serve([[VMCommandResponse(result: .configurationKeys(keyspace))]])
        #expect(
            CompletionSource.configurationKeys(suffix: "=", in: context(to: assigning))
                == ["cpus="])
    }

    @Test("--smart-group and --folder each offer their own kind's groups by name, described by their size")
    func groupNamesComeFromTheGroups() throws {
        let answer = VMCommandResponse(
            result: .groups([
                GroupSummary(id: UUID(), name: "Linux: Lab", kind: .smartGroup, members: [alpha, beta]),
                GroupSummary(id: UUID(), name: "Client", kind: .folder, members: [beta]),
            ]))
        let smart = try TestCommandSocket()
        defer { smart.close() }
        smart.serve([[answer]])
        let folders = try TestCommandSocket()
        defer { folders.close() }
        folders.serve([[answer]])

        #expect(
            CompletionSource.groupNames(of: .smartGroup, in: context(to: smart, asking: .zsh))
                == ["Linux\\: Lab:2 VMs"])
        #expect(CompletionSource.groupNames(of: .folder, in: context(to: folders, asking: .zsh)) == ["Client:1 VMs"])
        #expect(try smart.requests().map(\.verb) == [.groups])
        #expect(try folders.requests().map(\.verb) == [.groups])
    }

    @Test("A --network value offers every mode with no app to ask, then the named networks")
    func networkFilterOffersModesThenNames() throws {
        let unreachable = CompletionContext(
            connect: { throw CLIFailure(.unavailable, "no app group") }, deadline: testWaitBackstop,
            shell: nil)
        #expect(CompletionSource.networkFilterValues(in: unreachable) == VMLibraryFilter.Network.spellings)
        #expect(CompletionSource.groupNames(of: .smartGroup, in: unreachable).isEmpty)

        let listener = try TestCommandSocket()
        defer { listener.close() }
        listener.serve([
            [
                VMCommandResponse(
                    result: .networks([NetworkSummary(id: UUID(), name: "Lab", kind: .hostOnly, members: [])]))
            ]
        ])
        #expect(
            CompletionSource.networkFilterValues(in: context(to: listener))
                == VMLibraryFilter.Network.spellings + ["Lab"])
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
}
