import AppIntents
import Foundation
import KernovaCommandModel

/// Answers a VM's runtime state as the wire name every other front door
/// reports.
struct GetVMStateIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Virtual Machine State"
    static let description: IntentDescription? = IntentDescription(
        "Answers a virtual machine's current state.",
        categoryName: "Virtual Machines",
        resultValueName: "State")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Get the state of \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await gateway.info(vm.id).status)
    }
}

struct GetVMIPAddressIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Virtual Machine IP Address"
    static let description: IntentDescription? = IntentDescription(
        "Answers the address Kernova last saw a virtual machine's guest use on its network, if it has seen one.",
        categoryName: "Virtual Machines",
        resultValueName: "IP Address")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Get the IP address of \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String?> {
        .result(value: try await gateway.ipAddress(of: vm.id))
    }
}

struct FindStorageDisksIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Disks"
    static let description: IntentDescription? = IntentDescription(
        "Answers every disk a virtual machine attaches, in the order it attaches them, with each image's size as read now.",
        categoryName: "Virtual Machines",
        resultValueName: "Disks")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Find the disks of \(\.$vm)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[StorageDiskEntity]> {
        .result(value: try await gateway.storageDisks(ofVM: vm.id))
    }
}

struct TakeSnapshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Take Snapshot"
    static let description: IntentDescription? = IntentDescription(
        "Captures a named restore point for a virtual machine.",
        categoryName: "Virtual Machines",
        resultValueName: "Snapshot Name")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Notes", default: "")
    var notes: String

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Take a snapshot of \(\.$vm) named \(\.$name)") {
            \.$notes
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let snapshot = try await gateway.takeSnapshot(vm.id, name: name, notes: notes)
        return .result(value: snapshot.name)
    }
}
