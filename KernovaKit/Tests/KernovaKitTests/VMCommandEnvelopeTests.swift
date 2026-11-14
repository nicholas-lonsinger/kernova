import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCommandModel

/// The wire envelope's whole job: every request and every response survives a
/// round trip unchanged, so a transport carries what the core said and not an
/// approximation of it.
@Suite("VM Command Envelope Tests", .caseScoped)
struct VMCommandEnvelopeTests {
    private let selector = VMSelector.idOrName("Alpha")
    // Built from their bytes rather than parsed: a literal that has to be
    // unwrapped is a literal that can be mistyped into a crash.
    private let vmID = UUID(uuid: (1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5))
    private let snapshotID = UUID(uuid: (6, 6, 7, 7, 8, 8, 9, 9, 0, 0, 0, 0, 0, 0, 0, 0))
    private let diskID = UUID(uuid: (2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6))

    private var summary: VMSummary {
        VMSummary(id: vmID, name: "Alpha", status: "running", ipAddress: .unavailable, heldByAnotherCopy: false)
    }

    private var info: VMInfo {
        VMInfo(
            id: vmID, name: "Alpha", status: "running", guestOS: "macOS", cpuCount: 4,
            memoryBytes: 8_589_934_592, networkMode: "nat", networkMembership: "common",
            networkName: nil, macAddress: "aa:bb:cc:dd:ee:ff",
            ipAddress: .observed("192.168.66.2"),
            agentStatus: "current",
            hasSavedState: true, savedStateKernovaVersion: "0.10.0 (412)", isEphemeral: false, snapshotCount: 2,
            hasSnapshots: false, guestAgent: nil,
            stateBucket: .stopped,
            bundlePath: "/Users/somebody/VMs/Alpha.kernova", heldByAnotherCopy: false)
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

    // MARK: - Requests

    @Test("Every request verb round-trips, and reports which verb it is")
    func everyRequestRoundTrips() throws {
        let verbs: [VMCommandRequest.Verb] = [
            .list(),
            .list(
                VMListQuery(
                    filter: VMLibraryFilter(
                        guestOSes: [.linux], states: [.running, .heldByAnotherCopy],
                        networks: [.unlisted, VMLibraryFilter.Network(.nat) { _, _ in true }],
                        guestAgents: [.olderVersion], ephemeralOnly: true, withSnapshotsOnly: true),
                    networks: ["Lab"], groups: [VMGroupReference(.smartGroup, named: "Linux Lab")],
                    sort: .dateCreated)),
            .list(VMListQuery(groups: [VMGroupReference(.folder, named: "Client Project")])),
            .groups,
            .info(selector),
            .ipAddress(selector),
            .snapshots(selector),
            .snapshotSizes(selector),
            .sharedDirectories(selector),
            .storageDisks(selector),
            .usbAccessories(selector),
            .availableUSBAccessories,
            .events,
            .start(selector, recovery: true, consent: .none),
            .start(selector, recovery: false, consent: Consent([.startBesideSharedMachineIdentity])),
            .cancelGuestSetup(selector, consent: .none),
            .cancelGuestSetup(selector, consent: .all),
            .stop(selector, disposition: .graceful, consent: .none, timeout: nil),
            .stop(selector, disposition: .graceful, consent: .none, timeout: 90),
            .stop(selector, disposition: .force, consent: .all, timeout: 0.5),
            .pause(selector),
            .resume(selector, consent: .none),
            .resume(selector, consent: .all),
            .suspend(selector),
            .restart(selector, disposition: .graceful, timeout: nil, consent: .none),
            .restart(selector, disposition: .graceful, timeout: 120, consent: .none),
            .restart(selector, disposition: .force, timeout: nil, consent: .all),
            .restart(selector, disposition: .anyway, timeout: 30, consent: .all),
            .groupAction(.start, group: VMGroupReference(.folder, named: "Client Project")),
            .groupAction(.stop, group: VMGroupReference(.smartGroup, named: "Linux Lab")),
            .open(selector),
            .reveal(selector),
            .showInFinder(selector),
            .takeSnapshot(selector, name: "Fresh", notes: "a note"),
            .revertToSnapshot(selector, snapshot: snapshotID, consent: .all),
            .deleteSnapshot(selector, snapshot: snapshotID, consent: .all),
            .renameSnapshot(selector, snapshot: snapshotID, newName: "Renamed"),
            .setSnapshotNotes(selector, snapshot: snapshotID, notes: "annotated"),
            .clone(selector, outcome: .exactCopy, waitForOutcome: true),
            .clone(selector, outcome: .newMachine, waitForOutcome: false),
            .clone(selector, outcome: nil, waitForOutcome: false),
            .rename(selector, newName: "Beta"),
            .delete(selector, permanently: true, alsoRemoving: [snapshotID], consent: .all),
            .importVM(path: "/Users/somebody/Downloads/Alpha.kernova", waitForOutcome: true),
            .importVM(path: "/Users/somebody/Downloads/Alpha.kernova", waitForOutcome: false),
            .cancelPreparing(selector, consent: .all),
            .editStorageDisk(selector, .create(sizeInGB: 32)),
            .editStorageDisk(selector, .remove(disk: diskID, trashFile: true, consent: .none)),
            .editStorageDisk(selector, .rename(disk: diskID, newLabel: "Scratch")),
            .editStorageDisk(selector, .setNotes(disk: diskID, notes: "the build cache")),
            .editStorageDisk(selector, .setReadOnly(disk: diskID, readOnly: true)),
            .editStorageDisk(selector, .reorder(order: [diskID, snapshotID])),
            .editRemovableMedia(
                selector, .remove(item: diskID, trashFile: false, consent: .all)),
            .editRemovableMedia(selector, .eject(item: diskID)),
            .editRemovableMedia(selector, .rename(item: diskID, newLabel: "Installer")),
            .editRemovableMedia(selector, .setNotes(item: diskID, notes: "from the mirror")),
            .editRemovableMedia(selector, .setReadOnly(item: diskID, readOnly: false)),
            .editSharedDirectory(selector, .add(path: "/Users/somebody/Sites", readOnly: false)),
            .editSharedDirectory(selector, .remove(directory: diskID)),
            .editSharedDirectory(selector, .removePath(path: "/Users/somebody/Sites")),
            .editSharedDirectory(selector, .setReadOnly(directory: diskID, readOnly: true)),
            // An IORegistry ID runs past what 32 bits can name, so the width is
            // part of what has to survive the trip.
            .editUSBAccessory(selector, .attach(accessory: 4_294_967_296)),
            .editUSBAccessory(selector, .detach(device: diskID)),
            .usbPairings(nil),
            .usbPairings(selector),
            // The key carries the `:` and `@` its two spellings are built from,
            // and is what the caller copied out of a listing, so it has to
            // cross untouched.
            .forgetUSBPairing(selector, key: "04e8:6300:0100@hub/Port-A@1"),
            .configurationKeys,
            .configuration(selector, keys: nil),
            .configuration(selector, keys: ["cpus", "memory"]),
            .setConfiguration(
                selector, assignments: [ConfigurationEntry(key: "cpus", value: "4")],
                consent: .all),
            .guestAgentDisk(selector, .mount(awaiting: nil)),
            .guestAgentDisk(selector, .mount(awaiting: [])),
            .guestAgentDisk(selector, .mount(awaiting: [.login, .system])),
            .guestAgentDisk(selector, .unmount),
            .networks,
            .createNetwork(name: "Lab", kind: .hostOnly),
            .renameNetwork(network: "Lab", newName: "Bench"),
            .deleteNetwork(network: snapshotID.uuidString),
            .quit,
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
    /// reason ``name(of:)`` states — the add is here because the app obtains
    /// the grant for the path itself.
    private func name(of edit: SharedDirectoryEdit) -> String {
        switch edit {
        case .add: "add"
        case .remove: "remove"
        case .removePath: "removePath"
        case .setReadOnly: "setReadOnly"
        }
    }

    @Test("A mount names the scopes it waits for, none meaning every scope the guest OS has")
    func guestAgentDiskMountScopes() throws {
        let selector = VMSelector.name("Ubuntu")
        // `nil` and the empty set are different requests: the guest's every
        // scope, and no scope at all.
        for awaiting: Set<GuestAgentScope>? in [nil, [], [.system]] {
            let request = VMCommandRequest(verb: .guestAgentDisk(selector, .mount(awaiting: awaiting)))
            #expect(try roundTrip(request).verb == .guestAgentDisk(selector, .mount(awaiting: awaiting)))
        }
        let wire = try JSONEncoder().encode(GuestAgentDiskEdit.mount(awaiting: [.system]))
        #expect(String(decoding: wire, as: UTF8.self) == #"{"mount":{"awaiting":["system"]}}"#)
        #expect(VMGuestOS.macOS.installedAgentScopes == [.login])
        #expect(VMGuestOS.linux.installedAgentScopes == [.login, .system])
    }

    @Test("Every failure round-trips, and reads back as the response's failure")
    func everyFailureRoundTrips() throws {
        let prompt = ConfirmationPrompt(
            kind: .forceStop,
            title: "Force Stop Virtual Machine",
            message: "Anything in the guest that isn\u{2019}t saved to disk will be lost.",
            confirmTitle: "Force Stop",
            dismissTitle: "Cancel",
            alternatives: [
                ConfirmationAlternative(title: "Stop", disposition: .graceful),
                ConfirmationAlternative(title: "Keep File", keepsFile: true),
            ])
        let failures: [CommandErrorDTO] = [
            .notFound(selector: selector),
            .ambiguous(selector: selector, candidates: [summary, summary]),
            .invalidState(vm: summary, current: "running", allowed: [.stop, .pause, .suspend]),
            .busy(vm: summary, operation: "taking snapshot"),
            .heldByAnotherCopy(vm: summary),
            .confirmationRequired(prompt: prompt),
            .stepRequired(
                requirement: StepRequirement(
                    title: "Duplicate MAC Address",
                    message: "Change \u{201C}Alpha\u{201D}\u{2019}s network first.",
                    routes: [
                        StepRoute(title: "Resume", steps: [.resume(vm: summary)], ending: .refusedVerb),
                        StepRoute(
                            title: "Use a New MAC Address",
                            steps: [
                                .discardSavedState(vm: summary),
                                .setConfiguration(
                                    vm: summary,
                                    assignments: [ConfigurationEntry(key: "network.mac", value: "new")]),
                            ], ending: .start(vm: summary)),
                    ])),
            .stepRequired(requirement: StepRequirement(message: "Take a snapshot first.")),
            .unsupported(capability: "starting in macOS Recovery"),
            .conflict(vm: summary, with: summary, reason: .machineIdentity(overrideSettingOn: false)),
            .conflict(vm: summary, with: summary, reason: .macAddress),
            .conflict(
                vm: summary, with: summary,
                reason: .macAddressInUse(
                    address: "aa:bb:cc:dd:ee:0f",
                    holding: .snapshots(HeldSnapshots(Self.before)), otherHolders: [])),
            .conflict(
                vm: summary, with: summary,
                reason: .macAddressInUse(
                    address: "aa:bb:cc:dd:ee:0f",
                    holding: .configurationAndSnapshots(HeldSnapshots(Self.before, [Self.baseline])),
                    otherHolders: [
                        MACAddressHolder(name: "Other", holding: .configuration),
                        MACAddressHolder(
                            name: "Third", holding: .snapshots(HeldSnapshots(Self.baseline))),
                    ])),
            .invalidArgument(message: "There is no setting called \u{201C}cpu\u{201D}."),
            .timedOut(vm: summary, verb: .stop, seconds: 60),
            .timedOut(vm: summary, verb: .restart, seconds: 12.5),
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

    private static let before = HeldSnapshot(name: "Before", isEphemeralBaseline: false)
    private static let after = HeldSnapshot(name: "After", isEphemeralBaseline: false)
    private static let baseline = HeldSnapshot(name: "Baseline", isEphemeralBaseline: true)

    private func inUse(
        _ holding: MACAddressHolding, others: [MACAddressHolder] = []
    ) -> CommandErrorDTO {
        let holder = VMSummary(
            id: vmID, name: "Holder", status: "stopped", ipAddress: .unavailable, heldByAnotherCopy: false)
        return .conflict(
            vm: summary, with: holder,
            reason: .macAddressInUse(
                address: "aa:bb:cc:dd:ee:0f", holding: holding, otherHolders: others))
    }

    @Test("An Ephemeral Mode baseline is named as one, and offered no delete")
    func macAddressInUseCopyOffersNoDeleteForABaseline() {
        let message = inUse(.snapshots(HeldSnapshots(Self.baseline))).message

        #expect(
            message
                == "\u{201C}Holder\u{201D} has a snapshot, \u{201C}Baseline\u{201D}, taken with aa:bb:cc:dd:ee:0f. "
                + "\u{201C}Baseline\u{201D} is its Ephemeral Mode baseline. "
                + "Each virtual machine needs its own MAC address.")
    }

    @Test("Every holder is named, and no single step is offered when several hold the address")
    func macAddressInUseCopyNamesEveryHolder() {
        let message = inUse(
            .configuration,
            others: [
                MACAddressHolder(name: "Other", holding: .snapshots(HeldSnapshots(Self.before)))
            ]
        ).message

        #expect(
            message
                == "\u{201C}Holder\u{201D} already uses aa:bb:cc:dd:ee:0f. "
                + "\u{201C}Other\u{201D} has a snapshot, \u{201C}Before\u{201D}, taken with aa:bb:cc:dd:ee:0f. "
                + "Each virtual machine needs its own MAC address.")
    }

    private func sharing(
        _ reason: ConflictReason, otherHeldByAnotherCopy: Bool
    ) -> CommandErrorDTO {
        let other = VMSummary(
            id: vmID, name: "Alpha Copy", status: "running", ipAddress: .unavailable,
            heldByAnotherCopy: otherHeldByAnotherCopy)
        return .conflict(vm: summary, with: other, reason: reason)
    }

    @Test("A shared machine ID is refused naming the active VM, and the setting while it is off")
    func machineIdentityCopyNamesTheSettingWhileOff() {
        let active = sharing(.machineIdentity(overrideSettingOn: false), otherHeldByAnotherCopy: false)
        #expect(active.title == "Duplicate Machine ID")
        #expect(
            active.message
                == "\u{201C}Alpha\u{201D} has the same machine ID as \u{201C}Alpha Copy\u{201D}, which is active. "
                + "Two virtual machines with the same machine ID must not run at once. "
                + "Stop \u{201C}Alpha Copy\u{201D} first. "
                + "You can change this in Settings \u{25B8} Advanced.")
        #expect(
            sharing(.machineIdentity(overrideSettingOn: false), otherHeldByAnotherCopy: true).message
                == "\u{201C}Alpha\u{201D} has the same machine ID as \u{201C}Alpha Copy\u{201D}, which another copy of Kernova is using. "
                + "Two virtual machines with the same machine ID must not run at once. "
                + "You can change this in Settings \u{25B8} Advanced.")
        // With the setting on, the refusal is one nobody could be asked about.
        #expect(
            sharing(.machineIdentity(overrideSettingOn: true), otherHeldByAnotherCopy: false).message
                == "\u{201C}Alpha\u{201D} has the same machine ID as \u{201C}Alpha Copy\u{201D}, which is active. "
                + "Two virtual machines with the same machine ID must not run at once. "
                + "Stop \u{201C}Alpha Copy\u{201D} first.")
    }

    @Test(
        "A disk image in use offers stopping the other VM only when this copy runs it, and names the VM that writes",
        arguments: [false, true], [false, true])
    func diskImageCopyOffersWhatFreesTheImage(otherHeldByAnotherCopy: Bool, writableThere: Bool) {
        let refusal = sharing(
            .diskImage(label: "Data", writableThere: writableThere), otherHeldByAnotherCopy: otherHeldByAnotherCopy)
        let message = refusal.message
        #expect(refusal.title == "Disk Image In Use")
        #expect(message.contains("Stop \u{201C}Alpha Copy\u{201D} first.") == !otherHeldByAnotherCopy)
        #expect(message.contains("another copy of Kernova") == otherHeldByAnotherCopy)
        let fact = message.components(separatedBy: ". ").first ?? ""
        #expect(fact.contains("can write to it") == writableThere)
        #expect(fact.contains("\u{201C}Alpha\u{201D} would write to it") == !writableThere)
    }

    @Test("A consent crosses as the set of confirmations given")
    func consentCoversWhatItNames() throws {
        let given = Consent([.revertToSnapshot])
        #expect(given.covers(.revertToSnapshot))
        #expect(!given.covers(.startBesideSharedMachineIdentity))
        #expect(given.adding(.startBesideSharedMachineIdentity).covers(.startBesideSharedMachineIdentity))
        #expect(ConfirmationKind.allCases.allSatisfy(Consent.all.covers))
        #expect(!ConfirmationKind.allCases.contains(where: Consent.none.covers))
        let decoded = try JSONDecoder().decode(Consent.self, from: JSONEncoder().encode(given))
        #expect(decoded == given)
    }

    @Test("A holding answers nil for neither, and its snapshots keep their order")
    func macAddressHoldingCannotBeNeither() {
        #expect(MACAddressHolding(configured: false, snapshots: []) == nil)
        #expect(MACAddressHolding(configured: true, snapshots: []) == .configuration)
        #expect(
            MACAddressHolding(configured: false, snapshots: [Self.before, Self.after])
                == .snapshots(HeldSnapshots(Self.before, [Self.after])))
        #expect(
            MACAddressHolding(configured: true, snapshots: [Self.baseline])
                == .configurationAndSnapshots(HeldSnapshots(Self.baseline)))
        #expect(HeldSnapshots(Self.before, [Self.after]).all == [Self.before, Self.after])
    }
}
