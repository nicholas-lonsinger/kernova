import AppIntents
import Foundation
import KernovaKit

/// Writes one configuration key, the value spelled as `kernova set` takes it.
///
/// One action over the whole keyspace rather than one per setting, so a key
/// the registry adds is addressable here the moment it exists.
struct SetVMSettingIntent: AppIntent {
    static let title: LocalizedStringResource = "Change Virtual Machine Setting"
    static let description: IntentDescription? = IntentDescription(
        "Changes one of a virtual machine's settings, the value written as the setting's description names it. Returns the value the setting ends up holding.",
        categoryName: "Virtual Machines",
        resultValueName: "Value")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Setting")
    var setting: VMSettingKeyEntity

    @Parameter(title: "Value")
    var value: String

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$setting) of \(\.$vm) to \(\.$value)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        var held = ""
        try await runWithConsent { consent in
            held = try await gateway.setConfiguration(
                vm.id, key: setting.id, value: value, consent: consent)
        }
        return .result(value: held)
    }
}
