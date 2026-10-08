import AppIntents
import Foundation
import KernovaKit

struct FindSnapshotsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Snapshots"
    static let description: IntentDescription? = IntentDescription(
        "Answers every named restore point a virtual machine holds, newest first.",
        categoryName: "Virtual Machines",
        resultValueName: "Snapshots")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Find the snapshots of \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[SnapshotEntity]> {
        .result(value: try await gateway.snapshots(ofVM: vm.id))
    }
}

/// Returns a VM to a snapshot.
///
/// The checkpoint is an explicit parameter rather than the alternative the
/// core's confirmation offers: a Shortcut says up front which of the two it
/// means, so confirming performs exactly what was asked. It defaults on, the
/// same safe path the app's own alert makes the default button — and because
/// the choice is made before the confirmation is raised, the confirmation is
/// labelled with the route that was chosen rather than the core's default.
struct RevertToSnapshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Revert to Snapshot"
    static let description: IntentDescription? = IntentDescription(
        "Returns a virtual machine to a snapshot, taking one of its current state first unless you turn that off.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Snapshot")
    var snapshot: SnapshotEntity

    @Parameter(title: "Take Snapshot First", default: true)
    var takeCheckpoint: Bool

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Revert \(\.$vm) to \(\.$snapshot)") {
            \.$takeCheckpoint
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runBringUpWithConsent(asking: checkpointAwareConfirmation) { consent, remedy in
            try await gateway.revertToSnapshot(
                vm.id, snapshot: snapshot.id, takingCheckpoint: takeCheckpoint,
                consent: consent, macAddressRemedy: remedy)
        }
        return .result()
    }

    /// The confirmation's accept action, or a refusal for a prompt that offers
    /// no checkpoint when this action was configured to take one.
    ///
    /// The core refuses a checkpoint Take Snapshot would refuse before it asks
    /// (``VMCommandCore``'s `checkpointRefusal(on:)`), naming the reason; this
    /// names the toggle for any prompt that still arrives without one.
    private func checkpointAwareConfirmation(
        _ prompt: ConfirmationPrompt
    ) throws -> (title: String, isDestructive: Bool) {
        guard
            let action = VMConsentPolicy.revertAction(prompt, takingCheckpoint: takeCheckpoint)
        else {
            throw CommandError.operationFailed(
                verb: .revertToSnapshot,
                message:
                    "\u{201C}\(vm.name)\u{201D} cannot take a snapshot in its current state, so it "
                    + "cannot be reverted with Take Snapshot First turned on. Turn that off to "
                    + "revert without one."
            )
        }
        return action
    }
}

struct DeleteSnapshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Snapshot"
    static let description: IntentDescription? = IntentDescription(
        "Moves one snapshot's saved state and disk copies to the Trash, asking first. Deleting the snapshot Ephemeral Mode returns to also turns Ephemeral Mode off.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Snapshot")
    var snapshot: SnapshotEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Delete \(\.$snapshot) from \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runWithConsent { consent in
            try await gateway.deleteSnapshot(
                vm.id, snapshot: snapshot.id, consent: consent)
        }
        return .result()
    }
}

struct RenameSnapshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Rename Snapshot"
    static let description: IntentDescription? = IntentDescription(
        "Gives one of a virtual machine's snapshots a new name.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Snapshot")
    var snapshot: SnapshotEntity

    @Parameter(title: "Name")
    var name: String

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Rename \(\.$snapshot) of \(\.$vm) to \(\.$name)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await gateway.renameSnapshot(vm.id, snapshot: snapshot.id, to: name)
        return .result()
    }
}

struct SetSnapshotNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Edit Snapshot Note"
    static let description: IntentDescription? = IntentDescription(
        "Replaces the note on one of a virtual machine's snapshots; an empty note clears it.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Snapshot")
    var snapshot: SnapshotEntity

    @Parameter(title: "Note", default: "")
    var notes: String

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Set the note on \(\.$snapshot) of \(\.$vm) to \(\.$notes)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await gateway.setSnapshotNotes(vm.id, snapshot: snapshot.id, notes: notes)
        return .result()
    }
}
