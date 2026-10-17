import AppIntents
import Foundation
import KernovaKit

/// Answers a VM's runtime state as the wire name every other front door
/// reports, with the words a person reads carried in the spoken dialog.
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
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = Self.answer(for: try await gateway.info(vm.id))
        return .result(value: answer.value, dialog: IntentDialog("\(answer.dialog)"))
    }

    /// The value this intent returns for `info`, and the sentence its dialog
    /// speaks.
    static func answer(for info: VMInfo) -> (value: String, dialog: String) {
        let state = VMStatus.phrase(forWireName: info.status, heldByAnotherCopy: info.heldByAnotherCopy)
        return (info.status, "\(info.name) is \(state).")
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
