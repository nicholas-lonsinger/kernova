import AppKit
import Testing

@testable import Kernova

/// Covers `MainMenuController.validate(_:)` — the one decision behind every menu
/// command's enablement and the titles that name what the command will do.
///
/// The controller is built but never installed: `install()` writes
/// `NSApp.mainMenu` in the shared test host.
@Suite("MainMenuController validation", .serialized, .admissionGated)
@MainActor
struct MainMenuValidationTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.mainmenuvalidation")

    /// The controller under test with what it holds weakly — the host — kept
    /// alive alongside it.
    private struct Fixture {
        let controller: MainMenuController
        let host: StubMenuHost
        let viewModel: VMLibraryViewModel
    }

    private func makeFixture(
        instance: VMInstance?, hasBundledGuestAgentDisk: Bool = true
    ) -> Fixture {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        let controller = MainMenuController(
            viewModel: viewModel, preferences: preferences, hasSoftQuit: true,
            hasBundledGuestAgentDisk: hasBundledGuestAgentDisk)
        let host = StubMenuHost(instance: instance)
        controller.host = host
        return Fixture(controller: controller, host: host, viewModel: viewModel)
    }

    @Test("App-level commands stay enabled with no VM to act on")
    func appLevelCommandsIgnoreSelection() {
        let fixture = makeFixture(instance: nil)

        #expect(fixture.controller.validate(makeMenuItem(#selector(AppDelegate.showLibrary(_:)))))
        #expect(fixture.controller.validate(makeMenuItem(#selector(AppDelegate.newVM(_:)))))
        #expect(fixture.controller.validate(makeMenuItem(#selector(AppDelegate.quitCompletely(_:)))))
    }

    @Test("A VM command with nothing selected is disabled")
    func vmCommandWithoutSelection() {
        let fixture = makeFixture(instance: nil)

        #expect(!fixture.controller.validate(makeMenuItem(#selector(AppDelegate.startVM(_:)))))
    }

    @Test("Start takes its title from the VM's start action")
    func startRetitlesForPendingInstall() {
        let instance = makeMenuInstance()
        instance.configuration.installContext = MacOSInstallContext(source: .localFile)
        let fixture = makeFixture(instance: instance)
        let item = makeMenuItem(#selector(AppDelegate.startVM(_:)))

        #expect(fixture.controller.validate(item))
        #expect(item.title == instance.startAction.label)
        #expect(item.title == "Install")
    }

    @Test("A cold-paused VM's stop item discards the saved state")
    func stopRetitlesForColdPausedVM() {
        let instance = makeMenuInstance(phase: .suspended)
        let fixture = makeFixture(instance: instance)
        let item = makeMenuItem(#selector(AppDelegate.stopVM(_:)))

        // The graceful stop is unavailable and the discard is what the VM
        // admits, so the item is enabled through the second capability alone.
        #expect(!fixture.viewModel.capabilities.isAvailable(.stop, on: instance))
        #expect(fixture.viewModel.capabilities.isAvailable(.discardSavedState, on: instance))
        #expect(fixture.controller.validate(item))
        #expect(item.title == VMInstance.stopActionMenuTitle(discardingSavedState: true))
    }

    @Test("A build with no bundled guest-agent disk withholds the command")
    func guestAgentDiskWithoutBundledImage() {
        let instance = makeMenuInstance(phase: .running(sessionID: UUID()))
        let fixture = makeFixture(instance: instance, hasBundledGuestAgentDisk: false)
        let item = makeMenuItem(#selector(AppDelegate.toggleGuestAgentDisk(_:)))

        #expect(fixture.viewModel.capabilities.isAvailable(.toggleGuestAgentDisk, on: instance))
        #expect(!fixture.controller.validate(item))
        #expect(item.title == GuestAgentDiskMenuItem.unavailableTitle)
    }

    @Test("A bundled guest-agent disk hands title and enablement to the item model")
    func guestAgentDiskWithBundledImage() {
        let instance = makeMenuInstance(phase: .running(sessionID: UUID()))
        let fixture = makeFixture(instance: instance)
        let item = makeMenuItem(#selector(AppDelegate.toggleGuestAgentDisk(_:)))
        let model = GuestAgentDiskMenuItem.model(
            status: instance.agentStatus,
            isInstallerMounted: instance.hasGuestAgentInstallerMounted)

        #expect(fixture.controller.validate(item) == model.isEnabled)
        #expect(item.title == model.title)
    }

    @Test("The clone alternate names the preference with no VM selected")
    func cloneAlternateTitleWithoutSelection() {
        preferences.cloneGeneratesNewMachineID = true
        let fixture = makeFixture(instance: nil)
        let item = makeMenuItem(#selector(AppDelegate.cloneVMAlternate(_:)))

        #expect(!fixture.controller.validate(item))
        #expect(item.title == preferences.cloneAlternateMenuTitle)
    }

    @Test("The pop-out title follows where the display lives")
    func popOutTitleFollowsDisplayMode() {
        let instance = makeMenuInstance(phase: .running(sessionID: UUID()))
        let fixture = makeFixture(instance: instance)
        let item = makeMenuItem(#selector(AppDelegate.togglePopOut(_:)))

        #expect(fixture.controller.validate(item))
        #expect(item.title == "Pop Out Display")

        instance.displayMode = .popOut
        #expect(fixture.controller.validate(item))
        #expect(item.title == "Pop In Display")
    }

    @Test("The fullscreen title follows whether the VM is fullscreen")
    func fullscreenTitleFollowsDisplayMode() {
        let instance = makeMenuInstance(phase: .running(sessionID: UUID()))
        let fixture = makeFixture(instance: instance)
        let item = makeMenuItem(#selector(AppDelegate.toggleFullscreen(_:)))

        #expect(fixture.controller.validate(item))
        #expect(item.title == "Fullscreen Display")

        instance.displayMode = .fullscreen
        #expect(fixture.controller.validate(item))
        #expect(item.title == "Exit Fullscreen Display")
    }

    @Test("Every Virtual Machine menu command maps to a capability")
    func everyVMCommandIsGated() {
        let fixture = makeFixture(instance: nil)
        let vmMenu = submenu(titled: "Virtual Machine", in: fixture.controller.makeMainMenu())

        // A parent item is skipped: AppKit assigns `submenuAction:` to any item
        // carrying a submenu, and opening one invokes no command.
        let ungated = (vmMenu?.items ?? [])
            .filter { $0.action != nil && $0.submenu == nil }
            .filter { MainMenuController.capability(for: $0.action) == nil }
        #expect(ungated.isEmpty, "Ungated: \(ungated.map(\.title))")
    }
}
