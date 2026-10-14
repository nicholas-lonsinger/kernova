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
struct RevertToSnapshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Revert to Snapshot"
    static let description: IntentDescription? = IntentDescription(
        "Returns a virtual machine to a snapshot, asking first. Take a snapshot before it to keep the current state.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Snapshot")
    var snapshot: SnapshotEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Revert \(\.$vm) to \(\.$snapshot)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await runWithConsent { consent in
            try await gateway.revertToSnapshot(vm.id, snapshot: snapshot.id, consent: consent)
        }
        return .result()
    }
}

struct DeleteSnapshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Snapshot"
    static let description: IntentDescription? = IntentDescription(
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
