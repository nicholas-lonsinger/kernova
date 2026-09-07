import AppIntents
import Foundation
import KernovaKit

/// Copies a bundle a workflow holds into the library.
///
/// The one action here that waits for its copy. A clone reads a bundle the app
/// already owns and can carry on writing after the action reports; an import
/// reads a file outside the container, through an authority that lasts only as
/// long as this call — so the VM it answers is the settled one.
struct ImportVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Import Virtual Machine"
    static let description: IntentDescription? = IntentDescription(
        "Copies a virtual machine bundle into the library and returns the imported virtual machine once the copy is complete.",
        categoryName: "Virtual Machines",
        resultValueName: "Virtual Machine")

    /// The bundle to copy. What a workflow may hand it is
    /// ``VMBundleFile/supportedContentTypes``, which is the whole of what an
    /// import accepts — there is nothing narrower for this parameter to say.
    @Parameter(title: "Virtual Machine Bundle")
    var file: VMBundleFile

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Import \(\.$file)")
    }

    /// A file the framework can name but not locate is the one failure worded
    /// here: the read that would say why answered `nil` rather than throwing,
    /// so there is no system reason to pass on.
    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<VMEntity> {
        guard let url = try await file.id.fileURL else {
            throw CommandError.operationFailed(
                verb: .importVM,
                message:
                    "The chosen virtual machine bundle could not be opened. Choose it again in "
                    + "this shortcut, then run it.")
        }
        return .result(value: try await gateway.importVM(from: url))
    }
}

struct CloneVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Clone Virtual Machine"
    // The copy is dispatched and the new row answered immediately, so this
    // action reports while the bundle is still being written, and says so.
    static let description: IntentDescription? = IntentDescription(
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
        .result(value: try await gateway.clone(vm.id, machineIdentity: identity.identity))
    }
}

struct RenameVMIntent: AppIntent {
    static let title: LocalizedStringResource = "Rename Virtual Machine"
    static let description: IntentDescription? = IntentDescription(
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
    static let description: IntentDescription? = IntentDescription(
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
        try await runWithConsent { confirmed in
            try await gateway.delete(vm.id, confirmed: confirmed)
        }
        return .result()
    }
}

struct CancelPreparingIntent: AppIntent {
    static let title: LocalizedStringResource = "Cancel Virtual Machine Copy"
    static let description: IntentDescription? = IntentDescription(
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
        try await runWithConsent { confirmed in
            try await gateway.cancelPreparing(vm.id, confirmed: confirmed)
        }
        return .result()
    }
}

struct CancelGuestSetupIntent: AppIntent {
    static let title: LocalizedStringResource = "Cancel Guest Setup"
    static let description: IntentDescription? = IntentDescription(
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
        try await runWithConsent { confirmed in
            try await gateway.cancelGuestSetup(vm.id, confirmed: confirmed)
        }
        return .result()
    }
}
