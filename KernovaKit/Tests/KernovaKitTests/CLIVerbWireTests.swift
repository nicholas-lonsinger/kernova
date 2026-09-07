import Foundation
import KernovaKit
import Testing

@testable import KernovaCLICore

/// What each verb whose whole request its command line decides actually puts on
/// the wire, against a real socket.
@Suite("CLI verb wire", .admissionGated)
struct CLIVerbWireTests {
    private let alpha = VMSummary(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555") ?? UUID(),
        name: "Alpha", status: "running", ipAddress: .reserved("192.168.64.4"))

    private var info: VMInfo {
        VMInfo(
            id: alpha.id, name: "Alpha", status: "running", guestOS: "macOS", cpuCount: 4,
            memoryBytes: 8 << 30, diskSizeInGB: 64, networkMode: "shared",
            macAddress: "aa:bb:cc:dd:ee:ff", ipAddress: .reserved("192.168.64.4"),
            agentStatus: "current", hasSavedState: false, isEphemeral: true, snapshotCount: 2,
            bundlePath: "/Users/somebody/VMs/Alpha.kernova")
    }

    /// The answer the verbs that print nothing are given.
    private let accepted = VMCommandResponse(result: .ok)

    // MARK: - Reads

    @Test("list asks for the whole library and names no virtual machine")
    func listAsksForTheLibrary() throws {
        let exchanged = try CLIWire.exchange(
            ["list"], answering: VMCommandResponse(result: .summaries([alpha])), tag: "list")

        #expect(exchanged.sent == [.list])
        #expect(try exchanged.answer.payload() == .summaries([alpha]))
    }

    @Test("info crosses as the selector its argument names, and --id forces an identifier")
    func infoSendsItsSelector() throws {
        let answered = VMCommandResponse(result: .info(info))

        let named = try CLIWire.exchange(["info", "Alpha"], answering: answered, tag: "info")
        #expect(named.sent == [.info(.idOrName("Alpha"))])
        #expect(try named.answer.payload() == .info(info))

        let byID = try CLIWire.exchange(
            ["info", alpha.id.uuidString, "--id"], answering: answered, tag: "info-id")
        #expect(byID.sent == [.info(.id(alpha.id))])
    }

    @Test("ip asks for the guest's address once, the answer deciding whether it asks again")
    func ipAsksForTheAddress() throws {
        let exchanged = try CLIWire.exchange(
            ["ip", "Alpha"],
            answering: VMCommandResponse(result: .ipAddress(.reserved("192.168.64.4"))),
            tag: "ip")

        #expect(exchanged.sent == [.ipAddress(.idOrName("Alpha"))])
        #expect(try exchanged.answer.payload() == .ipAddress(.reserved("192.168.64.4")))
    }

    // MARK: - Lifecycle

    @Test("start crosses headless, carrying --recovery when the line asks for it")
    func startSendsAHeadlessBoot() throws {
        let plain = try CLIWire.exchange(["start", "Alpha"], answering: accepted, tag: "start")
        #expect(
            plain.sent == [.start(.idOrName("Alpha"), recovery: false, presentation: .headless)])
        #expect(try plain.answer.payload() == .ok)

        let recovery = try CLIWire.exchange(
            ["start", "Alpha", "--recovery"], answering: accepted, tag: "start-rec")
        #expect(
            recovery.sent == [.start(.idOrName("Alpha"), recovery: true, presentation: .headless)])
    }

    @Test("stop crosses with the disposition its method names, its consent, and its deadline")
    func stopSendsItsDispositionAndDeadline() throws {
        let graceful = try CLIWire.exchange(["stop", "Alpha"], answering: accepted, tag: "stop")
        #expect(
            graceful.sent == [
                .stop(
                    .idOrName("Alpha"), disposition: .graceful, confirmed: false, timeout: nil)
            ])

        let forced = try CLIWire.exchange(
            ["stop", "Alpha", "--force", "--yes", "--timeout", "30"], answering: accepted,
            tag: "stop-force")
        #expect(
            forced.sent == [
                .stop(.idOrName("Alpha"), disposition: .force, confirmed: true, timeout: 30)
            ])

        let resumeFirst = try CLIWire.exchange(
            ["stop", "Alpha", "--resume-first"], answering: accepted, tag: "stop-resume")
        #expect(
            resumeFirst.sent == [
                .stop(
                    .idOrName("Alpha"), disposition: .resumeThenShutDown, confirmed: false,
                    timeout: nil)
            ])
    }

    @Test("suspend crosses as the verb that saves the session")
    func suspendSendsItsVerb() throws {
        let exchanged = try CLIWire.exchange(
            ["suspend", "Alpha"], answering: accepted, tag: "suspend")

        #expect(exchanged.sent == [.suspend(.idOrName("Alpha"))])
    }

    @Test("pause crosses as the verb that holds the guest in memory")
    func pauseSendsItsVerb() throws {
        let exchanged = try CLIWire.exchange(["pause", "Alpha"], answering: accepted, tag: "pause")

        #expect(exchanged.sent == [.pause(.idOrName("Alpha"))])
    }

    @Test("resume crosses headless, the way start does")
    func resumeSendsAHeadlessResume() throws {
        let exchanged = try CLIWire.exchange(
            ["resume", "Alpha"], answering: accepted, tag: "resume")

        #expect(exchanged.sent == [.resume(.idOrName("Alpha"), presentation: .headless)])
    }

    @Test("restart crosses headless with the deadline bounding its shutdown half")
    func restartSendsItsDeadline() throws {
        let bare = try CLIWire.exchange(["restart", "Alpha"], answering: accepted, tag: "restart")
        #expect(
            bare.sent == [.restart(.idOrName("Alpha"), presentation: .headless, timeout: nil)])

        let bounded = try CLIWire.exchange(
            ["restart", "Alpha", "--timeout", "45"], answering: accepted, tag: "restart-t")
        #expect(
            bounded.sent == [.restart(.idOrName("Alpha"), presentation: .headless, timeout: 45)])
    }

    @Test("open is the one verb that crosses asking for something to come forward")
    func openSendsItsVerb() throws {
        let exchanged = try CLIWire.exchange(["open", "Alpha"], answering: accepted, tag: "open")

        #expect(exchanged.sent == [.open(.idOrName("Alpha"))])
    }

    // MARK: - Library

    @Test("rename crosses with the label to apply")
    func renameSendsTheNewName() throws {
        let exchanged = try CLIWire.exchange(
            ["rename", "Alpha", "Beta"], answering: accepted, tag: "rename")

        #expect(exchanged.sent == [.rename(.idOrName("Alpha"), newName: "Beta")])
    }

    @Test("delete crosses to the Trash unless --permanent, and takes no external file with it")
    func deleteSendsItsDisposalAndConsent() throws {
        let trashed = try CLIWire.exchange(
            ["delete", "Alpha", "--yes"], answering: accepted, tag: "delete")
        #expect(
            trashed.sent == [
                .delete(
                    .idOrName("Alpha"), permanently: false, alsoRemoving: [], confirmed: true)
            ])

        let permanent = try CLIWire.exchange(
            ["delete", "Alpha", "--permanent"], answering: accepted, tag: "delete-perm")
        #expect(
            permanent.sent == [
                .delete(
                    .idOrName("Alpha"), permanently: true, alsoRemoving: [], confirmed: false)
            ])
    }

    @Test("reveal crosses as the Finder verb, not as the app's own bring-up")
    func revealSendsTheFinderVerb() throws {
        let exchanged = try CLIWire.exchange(
            ["reveal", "Alpha"], answering: accepted, tag: "reveal")

        #expect(exchanged.sent == [.showInFinder(.idOrName("Alpha"))])
    }
}
