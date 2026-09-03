import Foundation
import Testing

@testable import KernovaKit

/// The wire envelope's whole job: every request and every response survives a
/// round trip unchanged, so a transport carries what the facade said and not an
/// approximation of it.
@Suite("VM Command Envelope Tests")
struct VMCommandEnvelopeTests {
    private let selector = VMSelector.idOrName("Alpha")
    // Built from their bytes rather than parsed: a literal that has to be
    // unwrapped is a literal that can be mistyped into a crash.
    private let vmID = UUID(uuid: (1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5))
    private let snapshotID = UUID(uuid: (6, 6, 7, 7, 8, 8, 9, 9, 0, 0, 0, 0, 0, 0, 0, 0))
    private let diskID = UUID(uuid: (2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6))

    private var summary: VMSummary {
        VMSummary(id: vmID, name: "Alpha", status: "running")
    }

    private var info: VMInfo {
        VMInfo(
            id: vmID, name: "Alpha", status: "running", guestOS: "macOS", cpuCount: 4,
            memoryBytes: 8_589_934_592, diskSizeInGB: 64, networkMode: "shared",
            macAddress: "aa:bb:cc:dd:ee:ff", ipAddress: "192.168.66.2", agentStatus: "current",
            hasSavedState: true, isEphemeral: false, snapshotCount: 2,
            bundlePath: "/Users/somebody/VMs/Alpha.kernova")
    }

    private var snapshot: SnapshotSummary {
        SnapshotSummary(
            id: snapshotID, name: "Clean install", notes: "before anything",
            kind: "warm", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isCurrent: true, isEphemeralBaseline: false)
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    // MARK: - Selectors

    @Test("Every selector shape round-trips")
    func selectorsRoundTrip() throws {
        for selector: VMSelector in [.id(vmID), .name("Alpha"), .idOrName("Alpha")] {
            #expect(try roundTrip(selector) == selector)
        }
    }

    @Test("A selector reads back the text a message would name it by")
    func selectorDisplayText() {
        #expect(VMSelector.id(vmID).displayText == vmID.uuidString)
        #expect(VMSelector.name("Alpha").displayText == "Alpha")
        #expect(VMSelector.idOrName("Alpha").displayText == "Alpha")
    }

    // MARK: - Requests

    @Test("Every request verb round-trips, and reports which verb it is")
    func everyRequestRoundTrips() throws {
        let verbs: [VMCommandRequest.Verb] = [
            .list,
            .info(selector),
            .ipAddress(selector),
            .snapshots(selector),
            .start(selector, recovery: true),
            .cancelGuestSetup(selector, confirmed: false),
            .cancelGuestSetup(selector, confirmed: true),
            .stop(selector, disposition: .graceful, confirmed: false),
            .stop(selector, disposition: .resumeThenShutDown, confirmed: true),
            .stop(selector, disposition: .force, confirmed: true),
            .pause(selector),
            .resume(selector),
            .suspend(selector),
            .restart(selector),
            .open(selector),
            .takeSnapshot(selector, name: "Fresh", notes: "a note"),
            .revertToSnapshot(
                selector, snapshot: snapshotID, takingCheckpoint: true, confirmed: true),
            .deleteSnapshot(selector, snapshot: snapshotID, confirmed: true),
            .renameSnapshot(selector, snapshot: snapshotID, newName: "Renamed"),
            .setSnapshotNotes(selector, snapshot: snapshotID, notes: "annotated"),
            .clone(selector, machineIdentity: .keep),
            .rename(selector, newName: "Beta"),
            .delete(selector, permanently: true, alsoRemoving: [snapshotID], confirmed: true),
            .importVM(path: "/Users/somebody/Downloads/Alpha.kernova"),
            .cancelPreparing(selector, confirmed: true),
            .editStorageDisk(selector, .create(sizeInGB: 32)),
            .editStorageDisk(selector, .remove(disk: diskID, trashFile: true, confirmed: false)),
            .editStorageDisk(selector, .rename(disk: diskID, newLabel: "Scratch")),
            .editStorageDisk(selector, .setNotes(disk: diskID, notes: "the build cache")),
            .editStorageDisk(selector, .setReadOnly(disk: diskID, readOnly: true)),
            .editStorageDisk(selector, .reorder(order: [diskID, snapshotID])),
            .editRemovableMedia(
                selector, .remove(item: diskID, trashFile: false, confirmed: true)),
            .editRemovableMedia(selector, .eject(item: diskID)),
            .editRemovableMedia(selector, .rename(item: diskID, newLabel: "Installer")),
            .editRemovableMedia(selector, .setNotes(item: diskID, notes: "from the mirror")),
            .editRemovableMedia(selector, .setReadOnly(item: diskID, readOnly: false)),
            .editSharedDirectory(selector, .remove(directory: diskID)),
            .editSharedDirectory(selector, .setReadOnly(directory: diskID, readOnly: true)),
            .guestAgentDisk(selector, .mount),
            .guestAgentDisk(selector, .unmount),
        ]
        // Every case of the vocabulary is represented, so a verb added without a
        // round trip fails here rather than shipping unencodable. `create` is
        // the one verb the wire does not offer: it takes the configuration the
        // wizard assembles, including security bookmarks only an in-process
        // pick can mint. Every other verb round-trips.
        #expect(Set(verbs.map(\.verb)) == Set(VMVerb.allCases).subtracting([.create]))

        for verb in verbs {
            let request = VMCommandRequest(verb: verb)
            let decoded = try roundTrip(request)
            #expect(decoded == request)
            #expect(decoded.verb.verb == verb.verb)
            #expect(decoded.protocolVersion == VMCommandRequest.currentProtocolVersion)
        }
    }

    // MARK: - Responses

    /// Every storage-disk edit the wire offers, named exhaustively.
    ///
    /// An attach added to the payload stops compiling here: a pick carries a
    /// security-scoped bookmark only an in-process panel can mint, and no
    /// transport can supply one. A create is offered because the image it
    /// writes lands inside the VM's own bundle, needing no grant at all.
    private func name(of edit: StorageDiskEdit) -> String {
        switch edit {
        case .create: "create"
        case .remove: "remove"
        case .rename: "rename"
        case .setNotes: "setNotes"
        case .setReadOnly: "setReadOnly"
        case .reorder: "reorder"
        }
    }

    /// Every removable-media edit the wire offers, named exhaustively for the
    /// reason ``name(of:)`` states — and with no create either, because the
    /// user picks that disk's destination.
    private func name(of edit: RemovableMediaEdit) -> String {
        switch edit {
        case .remove: "remove"
        case .eject: "eject"
        case .rename: "rename"
        case .setNotes: "setNotes"
        case .setReadOnly: "setReadOnly"
        }
    }

    /// Every shared-directory edit the wire offers, named exhaustively for the
    /// reason ``name(of:)`` states — an add is what needs the panel grant here.
    private func name(of edit: SharedDirectoryEdit) -> String {
        switch edit {
        case .remove: "remove"
        case .setReadOnly: "setReadOnly"
        }
    }

    @Test("No attachment payload offers an operation that needs a live panel grant")
    func picksStayOffTheWire() {
        #expect(name(of: .create(sizeInGB: 32)) == "create")
        #expect(name(of: .eject(item: diskID)) == "eject")
        #expect(name(of: .remove(directory: diskID)) == "remove")
        #expect(GuestAgentDiskEdit.allCases == [.mount, .unmount])
    }

    @Test("Every response result round-trips")
    func everyResponseRoundTrips() throws {
        let results: [VMCommandResponse.Result] = [
            .ok,
            .summaries([summary]),
            .summary(summary),
            .info(info),
            .ipAddress("192.168.66.2"),
            .ipAddress(nil),
            .snapshots([snapshot]),
            .snapshot(snapshot),
            .event(.added(summary)),
            .event(.removed(id: vmID, name: "Alpha")),
            .event(.statusChanged(id: vmID, name: "Alpha", from: "stopped", to: "running")),
            .event(.agentStatusChanged(id: vmID, name: "Alpha", status: "current")),
            .event(.failure(id: vmID, name: "Alpha", message: "the disk went away")),
        ]
        for result in results {
            let response = VMCommandResponse(result: result)
            #expect(try roundTrip(response) == response)
        }
    }

    @Test("Every failure round-trips, and reads back as the response's failure")
    func everyFailureRoundTrips() throws {
        let prompt = ConfirmationPrompt(
            kind: .stopPaused,
            title: "Stop Paused Virtual Machine",
            message: "Resume it to send a graceful shutdown, or force stop it.",
            confirmTitle: "Resume and Shut Down",
            dismissTitle: "Cancel",
            alternatives: [
                ConfirmationAlternative(title: "Force Stop", disposition: .force),
                ConfirmationAlternative(title: "Take Snapshot, Then Revert", takesCheckpoint: true),
            ])
        let failures: [CommandErrorDTO] = [
            .notFound(selector: selector),
            .ambiguous(selector: selector, candidates: [summary, summary]),
            .invalidState(vm: summary, current: "running", allowed: [.stop, .pause, .suspend]),
            .busy(vm: summary, operation: "taking snapshot"),
            .confirmationRequired(prompt: prompt),
            .unsupported(capability: "starting in macOS Recovery"),
            .conflict(vm: summary, with: summary, reason: .machineIdentity),
            .conflict(vm: summary, with: summary, reason: .macAddress),
            .operationFailed(
                verb: .start, title: nil, message: "could not open the disk", recovery: nil),
            .operationFailed(
                verb: .start, title: "Couldn\u{2019}t Start \u{201C}Alpha\u{201D}",
                message: "could not open the disk", recovery: nil),
            .operationFailed(
                verb: .start, title: nil, message: "could not open the disk",
                recovery: .removeStartFailedAttachment(id: snapshotID, label: "Installer")),
        ]
        for failure in failures {
            let response = VMCommandResponse(result: .failure(failure))
            let decoded = try roundTrip(response)
            #expect(decoded == response)
            #expect(decoded.failure == failure)
        }
    }

    @Test("A failure's own heading survives the wire")
    func operationFailureTitleRoundTrips() throws {
        let heading = "Couldn\u{2019}t Start \u{201C}Alpha\u{201D}"
        let response = VMCommandResponse(
            result: .failure(
                .operationFailed(
                    verb: .start, title: heading, message: "the limit was reached",
                    recovery: nil)))

        guard case .operationFailed(_, let title, _, _) = try #require(roundTrip(response).failure)
        else {
            Issue.record("expected an operation failure")
            return
        }
        #expect(title == heading)
    }

    @Test("A successful response carries no failure")
    func successCarriesNoFailure() {
        #expect(VMCommandResponse(result: .ok).failure == nil)
    }
}
