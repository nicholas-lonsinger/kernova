import Foundation
import KernovaKit
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
            memoryBytes: 8 << 30, diskSizeInGB: 64, networkMode: "shared", networkMembership: "common",
            networkName: nil, macAddress: "aa:bb:cc:dd:ee:ff", ipAddress: .observed("192.168.64.4"),
            agentStatus: "current", hasSavedState: false, isEphemeral: true, snapshotCount: 2,
            bundlePath: "/Users/somebody/VMs/Alpha.kernova", heldByAnotherCopy: false)
    }

    /// The answer the verbs that print nothing are given.
    private let accepted = VMCommandResponse(result: .ok)

    // MARK: - Reads

    @Test("list asks for the whole library and names no virtual machine")
    func listAsksForTheLibrary() throws {
        let exchanged = try CLIWire.exchange(
            ["list"], answering: VMCommandResponse(result: .summaries([alpha])))

        #expect(exchanged.sent == [.list])
        #expect(try exchanged.answer.payload() == .summaries([alpha]))
    }

    @Test("info crosses as the selector its argument names, and --id forces an identifier")
    func infoSendsItsSelector() throws {
        let answered = VMCommandResponse(result: .info(info))

        let named = try CLIWire.exchange(["info", "Alpha"], answering: answered)
        #expect(named.sent == [.info(.idOrName("Alpha"))])
        #expect(try named.answer.payload() == .info(info))

        let byID = try CLIWire.exchange(
            ["info", alpha.id.uuidString, "--id"], answering: answered)
        #expect(byID.sent == [.info(.id(alpha.id))])
    }

    @Test("ip asks for the guest's address once, the answer deciding whether it asks again")
    func ipAsksForTheAddress() throws {
        let exchanged = try CLIWire.exchange(
            ["ip", "Alpha"],
            answering: VMCommandResponse(result: .ipAddress(.observed("192.168.64.4"))))

        #expect(exchanged.sent == [.ipAddress(.idOrName("Alpha"))])
        #expect(try exchanged.answer.payload() == .ipAddress(.observed("192.168.64.4")))
    }

    // MARK: - Lifecycle

    @Test("start crosses carrying --recovery when the line asks for it, and --yes as every consent")
    func startSendsItsRecoveryFlag() throws {
        let plain = try CLIWire.exchange(["start", "Alpha"], answering: accepted)
        #expect(
            plain.sent == [
                .start(.idOrName("Alpha"), recovery: false, consent: .none, macAddressRemedy: nil)
            ])
        #expect(try plain.answer.payload() == .ok)

        let recovery = try CLIWire.exchange(
            ["start", "Alpha", "--recovery"], answering: accepted)
        #expect(
            recovery.sent == [
                .start(.idOrName("Alpha"), recovery: true, consent: .none, macAddressRemedy: nil)
            ])

        let anyway = try CLIWire.exchange(["start", "Alpha", "--yes"], answering: accepted)
        #expect(
            anyway.sent == [
                .start(.idOrName("Alpha"), recovery: false, consent: .all, macAddressRemedy: nil)
            ])
    }

    @Test("Each bring-up verb crosses carrying the change --resolve-mac-conflict names")
    func bringUpsSendTheirMACConflictRemedy() throws {
        let start = try CLIWire.exchange(
            ["start", "Alpha", "--resolve-mac-conflict", "own-network"], answering: accepted)
        #expect(
            start.sent == [
                .start(
                    .idOrName("Alpha"), recovery: false, consent: .none,
                    macAddressRemedy: .ownNetwork)
            ])

        let resume = try CLIWire.exchange(
            ["resume", "Alpha", "--resolve-mac-conflict", "new-address"], answering: accepted)
        #expect(
            resume.sent == [.resume(.idOrName("Alpha"), consent: .none, macAddressRemedy: .newAddress)])

        let restart = try CLIWire.exchange(
            ["restart", "Alpha", "--resolve-mac-conflict", "no-network"], answering: accepted)
        #expect(
            restart.sent == [
                .restart(
                    .idOrName("Alpha"), timeout: nil, consent: .none, macAddressRemedy: .noNetwork)
            ])

        #expect(throws: (any Error).self) {
            try KernovaCommand.parseAsRoot(["start", "Alpha", "--resolve-mac-conflict", "ownNetwork"])
        }
    }

    @Test("A MAC address refusal names the flag spelling of each change it offers, and what discards")
    func macAddressRefusalNamesTheFlag() throws {
        let other = VMSummary(
            id: UUID(), name: "Alpha Copy", status: "running", ipAddress: .unavailable,
            heldByAnotherCopy: false)
        let prompt = MACAddressRemedyPrompt(
            vm: alpha, other: other, verb: .resume, title: "Duplicate MAC Address",
            message: "Change its network:",
            offers: [
                MACAddressRemedyOffer(remedy: .ownNetwork, title: "Own", isDestructive: false),
                MACAddressRemedyOffer(remedy: .newAddress, title: "New", isDestructive: true),
                MACAddressRemedyOffer(remedy: .noNetwork, title: "None", isDestructive: true),
            ],
            dismissTitle: "Cancel")
        let exchanged = try CLIWire.exchange(
            ["resume", "Alpha"],
            answering: VMCommandResponse(result: .failure(.macAddressRemedyRequired(prompt: prompt))))

        do {
            _ = try exchanged.answer.payload()
            Issue.record("expected a MAC address refusal")
        } catch let failure as CLIFailure {
            #expect(failure.code == .refusedByState)
            #expect(failure.message.contains("which is active"))
            #expect(
                failure.message.hasSuffix(
                    "Pass --resolve-mac-conflict with own-network, new-address or no-network to "
                        + "change \u{201C}Alpha\u{201D}\u{2019}s network first. new-address and "
                        + "no-network discard its saved state."))
        }

        // A live mode switch's one offer is a key in the same `set`.
        let live = MACAddressRemedyPrompt(
            vm: alpha, other: other, verb: .setConfiguration, title: "Duplicate MAC Address",
            message: "", offers: [prompt.offers[0]], dismissTitle: "Cancel")
        #expect(
            VMCommandResponse.macAddressRemedyHint(live)
                == "Add network.membership=isolated to put \u{201C}Alpha\u{201D} on a network of its own instead.")
    }

    @Test("stop crosses with the disposition its method names, its consent, and its deadline")
    func stopSendsItsDispositionAndDeadline() throws {
        let graceful = try CLIWire.exchange(["stop", "Alpha"], answering: accepted)
        #expect(
            graceful.sent == [
                .stop(
                    .idOrName("Alpha"), disposition: .graceful, consent: .none, timeout: nil)
            ])

        let forced = try CLIWire.exchange(
            ["stop", "Alpha", "--force", "--yes", "--timeout", "30"], answering: accepted)
        #expect(
            forced.sent == [
                .stop(.idOrName("Alpha"), disposition: .force, consent: .all, timeout: 30)
            ])

        let resumeFirst = try CLIWire.exchange(
            ["stop", "Alpha", "--resume-first"], answering: accepted)
        #expect(
            resumeFirst.sent == [
                .stop(
                    .idOrName("Alpha"), disposition: .resumeThenShutDown, consent: .none,
                    timeout: nil)
            ])
    }

    @Test("suspend crosses as the verb that saves the session")
    func suspendSendsItsVerb() throws {
        let exchanged = try CLIWire.exchange(
            ["suspend", "Alpha"], answering: accepted)

        #expect(exchanged.sent == [.suspend(.idOrName("Alpha"))])
    }

    @Test("pause crosses as the verb that holds the guest in memory")
    func pauseSendsItsVerb() throws {
        let exchanged = try CLIWire.exchange(["pause", "Alpha"], answering: accepted)

        #expect(exchanged.sent == [.pause(.idOrName("Alpha"))])
    }

    @Test("resume crosses as the verb that lets a paused guest run again, --yes as every consent")
    func resumeSendsItsVerb() throws {
        let exchanged = try CLIWire.exchange(
            ["resume", "Alpha"], answering: accepted)
        #expect(exchanged.sent == [.resume(.idOrName("Alpha"), consent: .none, macAddressRemedy: nil)])

        let anyway = try CLIWire.exchange(["resume", "Alpha", "--yes"], answering: accepted)
        #expect(anyway.sent == [.resume(.idOrName("Alpha"), consent: .all, macAddressRemedy: nil)])
    }

    @Test("restart crosses with the deadline bounding its shutdown half")
    func restartSendsItsDeadline() throws {
        let bare = try CLIWire.exchange(["restart", "Alpha"], answering: accepted)
        #expect(
            bare.sent == [
                .restart(.idOrName("Alpha"), timeout: nil, consent: .none, macAddressRemedy: nil)
            ])

        let bounded = try CLIWire.exchange(
            ["restart", "Alpha", "--timeout", "45"], answering: accepted)
        #expect(
            bounded.sent == [
                .restart(.idOrName("Alpha"), timeout: 45, consent: .none, macAddressRemedy: nil)
            ])

        let anyway = try CLIWire.exchange(["restart", "Alpha", "--yes"], answering: accepted)
        #expect(
            anyway.sent == [
                .restart(.idOrName("Alpha"), timeout: nil, consent: .all, macAddressRemedy: nil)
            ])
    }

    @Test("open is the one verb that crosses asking for something to come forward")
    func openSendsItsVerb() throws {
        let exchanged = try CLIWire.exchange(["open", "Alpha"], answering: accepted)

        #expect(exchanged.sent == [.open(.idOrName("Alpha"))])
    }

    // MARK: - Library

    @Test("rename crosses with the label to apply")
    func renameSendsTheNewName() throws {
        let exchanged = try CLIWire.exchange(
            ["rename", "Alpha", "Beta"], answering: accepted)

        #expect(exchanged.sent == [.rename(.idOrName("Alpha"), newName: "Beta")])
    }

    @Test("delete crosses to the Trash unless --permanent, and takes no external file with it")
    func deleteSendsItsDisposalAndConsent() throws {
        let trashed = try CLIWire.exchange(
            ["delete", "Alpha", "--yes"], answering: accepted)
        #expect(
            trashed.sent == [
                .delete(
                    .idOrName("Alpha"), permanently: false, alsoRemoving: [], consent: .all)
            ])

        let permanent = try CLIWire.exchange(
            ["delete", "Alpha", "--permanent"], answering: accepted)
        #expect(
            permanent.sent == [
                .delete(
                    .idOrName("Alpha"), permanently: true, alsoRemoving: [], consent: .none)
            ])
    }

    @Test("A removal whose file stayed exits as a verb that did not complete, naming the file")
    func filesKeptExitsNamingTheFile() throws {
        let kept = try #require(
            FilesKept(
                .attachment(label: "Data", vm: "Alpha"),
                kept: [
                    FilesKept.File(
                        path: "/Volumes/Archive/data.img",
                        reason:
                            "\u{201C}data.img\u{201D} couldn\u{2019}t be moved to the trash because the volume \u{201C}Archive\u{201D} doesn\u{2019}t have one."
                    )
                ]))
        // Across the wire and back, as the tool receives it.
        let answer = try JSONDecoder().decode(
            VMCommandResponse.self,
            from: JSONEncoder().encode(VMCommandResponse(result: .failure(.filesKept(kept)))))

        do {
            _ = try answer.payload()
            Issue.record("expected the files-kept outcome")
        } catch let failure as CLIFailure {
            #expect(failure.code == .operationFailed)
            #expect(
                failure.message
                    == "\u{201C}Data\u{201D} was removed from \u{201C}Alpha\u{201D}. "
                    + "\u{201C}/Volumes/Archive/data.img\u{201D} was not moved to the Trash: "
                    + "\u{201C}data.img\u{201D} couldn\u{2019}t be moved to the trash because the "
                    + "volume \u{201C}Archive\u{201D} doesn\u{2019}t have one.")
        }
    }

    @Test("A removal that kept no file does not decode")
    func filesKeptNamingNoFileDoesNotDecode() {
        let json = Data(#"{"removal":{"vm":{"name":"Alpha","permanently":false}},"files":[]}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(FilesKept.self, from: json) }
    }

    @Test("reveal crosses as the Finder verb, not as the app's own bring-up")
    func revealSendsTheFinderVerb() throws {
        let exchanged = try CLIWire.exchange(
            ["reveal", "Alpha"], answering: accepted)

        #expect(exchanged.sent == [.showInFinder(.idOrName("Alpha"))])
    }

    @Test("usb rules names a machine only when the line did")
    func usbRulesSendsAnOptionalSelector() throws {
        let pairings = [
            USBPairingSummary(
                vm: "Alpha", key: "04e8:6300:0100:0373", name: "Samsung Type-C",
                pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
        ]
        let answered = VMCommandResponse(result: .usbPairings(pairings))

        let everyMachine = try CLIWire.exchange(["usb", "rules"], answering: answered)
        #expect(everyMachine.sent == [.usbPairings(nil)])
        #expect(try everyMachine.answer.payload() == .usbPairings(pairings))

        let named = try CLIWire.exchange(
            ["usb", "rules", "Alpha"], answering: answered)
        #expect(named.sent == [.usbPairings(.idOrName("Alpha"))])
    }

    @Test("usb forget crosses as the durable key, verbatim")
    func usbForgetSendsTheKey() throws {
        // The key is what the user copied out of a listing, `@` and `:` and
        // all, so nothing may reinterpret it on the way.
        let exchanged = try CLIWire.exchange(
            ["usb", "forget", "Alpha", "04e8:6300:0100@hub/Port-A@1"], answering: accepted)

        #expect(
            exchanged.sent
                == [.forgetUSBPairing(.idOrName("Alpha"), key: "04e8:6300:0100@hub/Port-A@1")])
    }

    // MARK: - Named networks

    private var lab: NetworkSummary {
        NetworkSummary(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE") ?? UUID(), name: "Lab",
            kind: .hostOnly, members: [alpha])
    }

    @Test("network list asks for the library's networks and names no virtual machine")
    func networkListAsksForTheNetworks() throws {
        let exchanged = try CLIWire.exchange(
            ["network", "list"], answering: VMCommandResponse(result: .networks([lab])))

        #expect(exchanged.sent == [.networks])
        #expect(try exchanged.answer.payload() == .networks([lab]))
    }

    @Test("network create crosses with its name and kind, the kind shared unless --kind names one")
    func networkCreateSendsItsKind() throws {
        let answered = VMCommandResponse(result: .network(lab))

        let plain = try CLIWire.exchange(["network", "create", "Lab"], answering: answered)
        #expect(plain.sent == [.createNetwork(name: "Lab", kind: .shared)])
        #expect(try plain.answer.payload() == .network(lab))

        let hostOnly = try CLIWire.exchange(
            ["network", "create", "Lab", "--kind", "hostOnly"], answering: answered)
        #expect(hostOnly.sent == [.createNetwork(name: "Lab", kind: .hostOnly)])
    }

    @Test("network rename and delete cross with the network as the line spelled it")
    func networkRenameAndDeleteSendTheirNetwork() throws {
        // The app matches a name or an identifier, so the argument crosses
        // verbatim either way.
        let renamed = try CLIWire.exchange(
            ["network", "rename", "Lab", "Bench"], answering: accepted)
        #expect(renamed.sent == [.renameNetwork(network: "Lab", newName: "Bench")])

        let deleted = try CLIWire.exchange(
            ["network", "delete", lab.id.uuidString], answering: accepted)
        #expect(deleted.sent == [.deleteNetwork(network: lab.id.uuidString)])
    }
}
