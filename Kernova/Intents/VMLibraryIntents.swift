import AppIntents
import Foundation
import KernovaKit

struct CloneVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Clone Virtual Machine"
    // The copy is dispatched and the new row answered immediately, so this
    // action reports while the bundle is still being written, and says so.
    static let description = IntentDescription(
        "Copies a virtual machine's bundle into a new one — a copy that carries on after this reports.",
        categoryName: "Virtual Machines",
        resultValueName: "Virtual Machine")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Machine Identity", default: .followPreference)
    var identity: VMCloneIdentity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Clone \(\.$vm)") {
            \.$identity
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<VMEntity> {
        gateway.beginIntent()
        defer { gateway.endIntent() }
        return .result(value: try await gateway.clone(vm.id, machineIdentity: identity.identity))
    }
}

struct RenameVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Rename Virtual Machine"
    static let description = IntentDescription(
        "Gives a virtual machine a new display name.", categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Name")
    var name: String

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Rename \(\.$vm) to \(\.$name)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        gateway.beginIntent()
        defer { gateway.endIntent() }
        try await gateway.rename(vm.id, to: name)
        return .result()
    }
}

/// Moves a VM's bundle to the Trash.
///
/// The narrowest of the deletes the core offers, and deliberately so: no
/// permanent delete, because bypassing the Trash is a choice the user makes at
/// a sheet that spells out what it costs, and no external files, because a
/// Shortcut never showed the user which files those are.
struct DeleteVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Virtual Machine"
    static let description = IntentDescription(
        "Moves a virtual machine's bundle to the Trash, asking first. Files stored outside the bundle are left alone.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Delete \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        gateway.beginIntent()
        defer { gateway.endIntent() }
        try await runWithConsent { confirmed in
            try await gateway.delete(vm.id, confirmed: confirmed)
        }
        return .result()
    }
}

struct CancelPreparingIntent: AppIntent {
    static let title: LocalizedStringResource = "Cancel Virtual Machine Copy"
    static let description = IntentDescription(
        "Stops a create, clone, or import that is still writing, removing what it has written.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Cancel the copy of \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        gateway.beginIntent()
        defer { gateway.endIntent() }
        try await runWithConsent { confirmed in
            try await gateway.cancelPreparing(vm.id, confirmed: confirmed)
        }
        return .result()
    }
}

struct CancelGuestSetupIntent: AppIntent {
    static let title: LocalizedStringResource = "Cancel Guest Setup"
    static let description = IntentDescription(
        "Interrupts the install, download, or verification a virtual machine's first start is running.",
        categoryName: "Virtual Machines")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Cancel the guest setup of \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        gateway.beginIntent()
        defer { gateway.endIntent() }
        try await runWithConsent { confirmed in
            try await gateway.cancelGuestSetup(vm.id, confirmed: confirmed)
        }
        return .result()
    }
}
