import Testing

@testable import Kernova

/// The confirmation outcomes of the clipboard flags' one write path, which
/// every surface offering either switch goes through.
@Suite("ClipboardPassthroughSetting", .caseScoped)
@MainActor
struct ClipboardPassthroughSettingTests {
    private let preferences = makeTestPreferences()

    private func makeSetting(
        _ mutate: (inout VMConfiguration) -> Void
    ) -> (setting: ClipboardPassthroughSetting, instance: VMInstance, refreshes: () -> Int) {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let instance = viewModel.library.registerFixture(
            name: "Clipboard VM", guestOS: .macOS, mutate: mutate)
        var refreshes = 0
        let setting = ClipboardPassthroughSetting(
            instance: instance, viewModel: viewModel, refresh: { refreshes += 1 })
        return (setting, instance, { refreshes })
    }

    @Test("Confirming the passthrough prompt turns passthrough on")
    func confirmPassthroughEnables() {
        let (setting, instance, refreshes) = makeSetting { $0.clipboardSharingEnabled = true }

        setting.confirm(.passthrough(true))

        #expect(instance.configuration.clipboardPassthroughEnabled)
        #expect(refreshes() == 0)
    }

    @Test("Confirming sharing over a passthrough flag already set starts passthrough")
    func confirmSharingOverAStalePassthroughFlag() {
        let (setting, instance, _) = makeSetting { $0.clipboardPassthroughEnabled = true }
        #expect(!instance.configuration.clipboardPassthroughIsEffective)

        setting.confirm(.sharing(true))

        #expect(instance.configuration.clipboardSharingEnabled)
        #expect(instance.configuration.clipboardPassthroughIsEffective)
    }

    @Test("Cancelling the prompt writes nothing and re-renders every surface")
    func cancelWritesNothingAndRefreshes() {
        let (setting, instance, refreshes) = makeSetting { $0.clipboardSharingEnabled = true }

        setting.cancel()

        #expect(!instance.configuration.clipboardPassthroughEnabled)
        #expect(refreshes() == 1)
    }
}
