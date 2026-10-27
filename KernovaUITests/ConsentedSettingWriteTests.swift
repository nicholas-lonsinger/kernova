import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// The confirmation outcomes of the write path every setting that can ask for
/// consent goes through, on every surface offering it.
@Suite("ConsentedSettingWrite", .caseScoped)
@MainActor
struct ConsentedSettingWriteTests {
    private let preferences = makeTestPreferences()

    private func makeSetting(
        _ mutate: (inout VMConfiguration) -> Void
    ) -> (setting: ConsentedSettingWrite, instance: VMInstance, refreshes: () -> Int) {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let instance = viewModel.library.registerFixture(
            name: "Clipboard VM", guestOS: .macOS, mutate: mutate)
        var refreshes = 0
        let setting = ConsentedSettingWrite(
            instance: instance, viewModel: viewModel, refresh: { refreshes += 1 })
        return (setting, instance, { refreshes })
    }

    @Test("Confirming the passthrough prompt turns passthrough on")
    func confirmPassthroughEnables() {
        let (setting, instance, refreshes) = makeSetting { $0.clipboardSharingEnabled = true }

        setting.write(
            VMConfigurationKeyRegistry.clipboardPassthrough.assigning(true), confirmingIn: nil,
            consent: Consent([.enableClipboardPassthrough]))

        #expect(instance.configuration.clipboardPassthroughEnabled)
        #expect(refreshes() == 0)
    }

    @Test("Confirming sharing over a passthrough flag already set starts passthrough")
    func confirmSharingOverAStalePassthroughFlag() {
        let (setting, instance, _) = makeSetting { $0.clipboardPassthroughEnabled = true }
        #expect(!instance.configuration.clipboardPassthroughIsEffective)

        setting.write(
            VMConfigurationKeyRegistry.clipboardSharing.assigning(true), confirmingIn: nil,
            consent: Consent([.enableClipboardPassthrough]))

        #expect(instance.configuration.clipboardSharingEnabled)
        #expect(instance.configuration.clipboardPassthroughIsEffective)
    }

    @Test("A write asking for consent with no window to ask in writes nothing and re-renders every surface")
    func unconfirmableWriteWritesNothingAndRefreshes() {
        let (setting, instance, refreshes) = makeSetting { $0.clipboardSharingEnabled = true }

        setting.write(
            VMConfigurationKeyRegistry.clipboardPassthrough.assigning(true), confirmingIn: nil)

        #expect(!instance.configuration.clipboardPassthroughEnabled)
        #expect(refreshes() == 1)
    }
}
