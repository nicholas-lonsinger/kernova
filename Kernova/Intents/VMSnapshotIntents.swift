import AppIntents
import Foundation
import KernovaKit

struct FindSnapshotsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Snapshots"
    static let description = IntentDescription(
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
        gateway.beginIntent()
        defer { gateway.endIntent() }
        return .result(value: try await gateway.snapshots(ofVM: vm.id))
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
    static let description = IntentDescription(
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
        gateway.beginIntent()
        defer { gateway.endIntent() }
        try await runWithConsent(asking: checkpointAwareConfirmation) { confirmed in
            try await gateway.revertToSnapshot(
                vm.id, snapshot: snapshot.id, takingCheckpoint: takeCheckpoint,
                confirmed: confirmed)
        }
        return .result()
    }

    /// The confirmation's accept label, or the refusal for a VM that cannot
    /// take the checkpoint this action was configured to take.
    ///
    /// The refusal is raised here rather than left to the capture: the core
    /// takes the checkpoint after consent, and what it throws then is an
    /// invalid-state refusal that lists Revert to Snapshot among the verbs the
    /// VM does accept and never names the checkpoint as what blocked it. The
    /// state this covers is real — a VM that failed to start can be reverted
    /// but cannot be captured, and reverting is how a user gets out of it — so
    /// the refusal has to name the toggle that is in the way.
    private func checkpointAwareConfirmation(_ prompt: ConfirmationPrompt) throws -> String {
        guard
            let action = VMIntentConsent.revertAction(prompt, takingCheckpoint: takeCheckpoint)
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
    static let description = IntentDescription(
        "Moves one snapshot's saved state and disk copies to the Trash, asking first.",
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
        gateway.beginIntent()
        defer { gateway.endIntent() }
        try await runWithConsent { confirmed in
            try await gateway.deleteSnapshot(
                vm.id, snapshot: snapshot.id, confirmed: confirmed)
        }
        return .result()
    }
}

struct RenameSnapshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Rename Snapshot"
    static let description = IntentDescription(
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
        gateway.beginIntent()
        defer { gateway.endIntent() }
        try await gateway.renameSnapshot(vm.id, snapshot: snapshot.id, to: name)
        return .result()
    }
}

struct SetSnapshotNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Edit Snapshot Note"
    static let description = IntentDescription(
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
        gateway.beginIntent()
        defer { gateway.endIntent() }
        try await gateway.setSnapshotNotes(vm.id, snapshot: snapshot.id, notes: notes)
        return .result()
    }
}
