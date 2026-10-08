import AppIntents
import Foundation
import KernovaKit

struct CreateNetworkIntent: AppIntent {
    static let title: LocalizedStringResource = "Create Network"
    static let description: IntentDescription? = IntentDescription(
        "Creates a named network. The virtual machines on it reach each other, and no other guest, and every one runs in the network's kind.",
        categoryName: "Networks",
        resultValueName: "Network")

    @Parameter(title: "Name")
    var name: String

    @Parameter(title: "Kind", default: .nat)
    var kind: VMNetworkKind

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Create the network \(\.$name)") {
            \.$kind
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<NetworkEntity> {
        .result(value: try await gateway.createNetwork(name: name, kind: kind.kind))
    }
}

struct RenameNetworkIntent: AppIntent {
    static let title: LocalizedStringResource = "Rename Network"
    static let description: IntentDescription? = IntentDescription(
        "Gives a named network a new name. The virtual machines on it stay on it.",
        categoryName: "Networks")

    @Parameter(title: "Network")
    var network: NetworkEntity

    @Parameter(title: "Name")
    var name: String

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Rename \(\.$network) to \(\.$name)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await gateway.renameNetwork(network.id, to: name)
        return .result()
    }
}

struct DeleteNetworkIntent: AppIntent {
    static let title: LocalizedStringResource = "Delete Network"
    static let description: IntentDescription? = IntentDescription(
        "Deletes a named network, first moving each virtual machine on it to a network of its own.",
        categoryName: "Networks")

    @Parameter(title: "Network")
    var network: NetworkEntity

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Delete \(\.$network)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await gateway.deleteNetwork(network.id)
        return .result()
    }
}
