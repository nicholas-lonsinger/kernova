import AppIntents
import Foundation
import KernovaKit

/// Writes one configuration key, the value spelled as `kernova set` takes it.
///
/// One action over the whole keyspace rather than one per setting, so a key
/// the registry adds is addressable here the moment it exists.
struct SetVMSettingIntent: ConsentingIntent {
    static let title: LocalizedStringResource = "Change Virtual Machine Setting"
    static let description: IntentDescription? = IntentDescription(
        "Changes one of a virtual machine's settings, the value written as the setting's description names it. Returns the value the setting ends up holding. On a virtual machine in Ephemeral Mode, changes to most of its System, Storage, Network and Sharing settings go back to its baseline snapshot at the next shutdown. Confirm Before Changing asks before a change that turns on automatic clipboard passthrough, or turns on Ephemeral Mode or changes its baseline.",
        categoryName: "Virtual Machines",
        resultValueName: "Value")

    @Parameter(title: "Virtual Machine")
    var vm: VMEntity

    @Parameter(title: "Setting")
    var setting: VMSettingKeyEntity

    @Parameter(title: "Value")
    var value: String

    @Parameter(title: "Confirm Before Changing", default: true)
    var confirmsFirst: Bool

    @Dependency private var gateway: VMIntentGateway

    static var parameterSummary: some ParameterSummary {
        Summary("Set \(\.$setting) of \(\.$vm) to \(\.$value)") {
            \.$confirmsFirst
        }
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
