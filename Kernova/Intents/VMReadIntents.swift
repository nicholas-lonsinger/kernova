import AppIntents
import Foundation
import KernovaKit

struct ListVMsIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Virtual Machines"
    static let description = IntentDescription(
        "Answers with every virtual machine in the library.",
        categoryName: "Virtual Machines",
        resultValueName: "Virtual Machines")

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Find virtual machines")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[VMEntity]> {
        gateway.beginIntent()
        defer { gateway.endIntent() }
        return .result(value: await gateway.vms())
    }
}

/// Answers a VM's runtime state as the wire name every other front door
/// reports, with the words a person reads carried in the spoken dialog.
struct GetVMStateIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Virtual Machine State"
    static let description = IntentDescription(
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
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        gateway.beginIntent()
        defer { gateway.endIntent() }
        let info = try await gateway.info(vm.id)
        let spoken = VMEntity.statusDisplayName(info.status)
        return .result(
            value: info.status,
            dialog: IntentDialog("\(info.name) is \(spoken.lowercased())."))
    }
}

struct GetVMIPAddressIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Virtual Machine IP Address"
    static let description = IntentDescription(
        "Answers the address Kernova reserved for a virtual machine's guest, if it has one.",
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
        gateway.beginIntent()
        defer { gateway.endIntent() }
        return .result(value: try await gateway.ipAddress(of: vm.id))
    }
}

struct TakeSnapshotIntent: AppIntent {
    static let title: LocalizedStringResource = "Take Snapshot"
    static let description = IntentDescription(
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
        gateway.beginIntent()
        defer { gateway.endIntent() }
        let snapshot = try await gateway.takeSnapshot(vm.id, name: name, notes: notes)
        return .result(value: snapshot.name)
    }
}
