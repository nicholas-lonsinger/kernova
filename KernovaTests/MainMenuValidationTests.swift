import AppKit
import Testing

@testable import Kernova
@testable import KernovaCore

/// Covers `MainMenuController.validate(_:)` — the one decision behind every menu
/// command's enablement and the titles that name what the command will do.
///
/// The controller is built but never installed: `install()` writes
/// `NSApp.mainMenu` in the shared test host.
@Suite("MainMenuController validation", .serialized, .caseScoped)
@MainActor
struct MainMenuValidationTests {
    private let preferences = makeTestPreferences()

    /// The controller under test, over a library a test selects the VM in
    /// (``makeMenuInstance(in:guestOS:name:phase:mutate:)``), which each check
    /// takes as the VM the working window shows.
    private struct Fixture {
        let controller: MainMenuController
        let viewModel: VMLibraryViewModel

        /// Validates `item` with the VM ``makeMenuInstance(in:guestOS:name:phase:mutate:)``
        /// selected as the one the working window shows.
        @MainActor
        func validate(_ item: NSMenuItem) -> Bool {
            controller.validate(item, workingInstance: viewModel.selectedInstance)
        }
    }

    private func makeFixture(hasBundledGuestAgentDisk: Bool = true) -> Fixture {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        let controller = MainMenuController(
            viewModel: viewModel, windows: makeWindowRegistry(viewModel),
            hasBundledGuestAgentDisk: hasBundledGuestAgentDisk)
        return Fixture(controller: controller, viewModel: viewModel)
    }

    @Test("App-level commands stay enabled with no VM to act on")
    func appLevelCommandsIgnoreSelection() {
        let fixture = makeFixture()

        #expect(fixture.validate(makeMenuItem(#selector(AppDelegate.showLibrary(_:)))))
        #expect(fixture.validate(makeMenuItem(#selector(AppDelegate.newVM(_:)))))
        #expect(fixture.validate(makeMenuItem(#selector(AppDelegate.quitCompletely(_:)))))
    }

    @Test("A VM command with nothing selected is disabled")
    func vmCommandWithoutSelection() {
        let fixture = makeFixture()

        #expect(!fixture.validate(makeMenuItem(#selector(AppDelegate.startVM(_:)))))
    }

    @Test("Start takes its title from the VM's start action")
    func startRetitlesForPendingInstall() {
        let fixture = makeFixture()
        let instance = makeMenuInstance(in: fixture.viewModel) {
            $0.installContext = MacOSInstallContext(source: .localFile)
        }
        let item = makeMenuItem(#selector(AppDelegate.startVM(_:)))

        #expect(fixture.validate(item))
        #expect(item.title == instance.startAction.label)
        #expect(item.title == "Install")
    }

    @Test("A suspended VM's stop item discards the saved state")
    func stopRetitlesForSuspendedVM() throws {
        let fixture = makeFixture()
        let instance = makeMenuInstance(in: fixture.viewModel, phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)
        let item = makeMenuItem(#selector(AppDelegate.stopVM(_:)))

        // The graceful stop is unavailable and the discard is what the VM
        // admits, so the item is enabled through the second capability alone.
        #expect(!fixture.viewModel.capabilities.isAvailable(.stop, on: instance))
        #expect(fixture.viewModel.capabilities.isAvailable(.discardSavedState, on: instance))
        #expect(fixture.validate(item))
        #expect(item.title == VMInstance.StopAction.discardSavedState.menuTitle)
    }

    /// Menu validation is where a VM mid-operation used to offer a termination
    /// Virtualization would refuse; the item is greyed for those seconds now,
    /// as any unavailable command is.
    @Test(
        "Force Stop is enabled only where Virtualization takes a termination",
        arguments: [
            (PhaseFixture.settled(.running(sessionID: UUID())), true),
            (.settled(.livePaused(sessionID: UUID())), true),
            (
                .operating(
                    .bringUp(.guestStart(.starting(recovery: false))), from: .stopped, boundSession: UUID()),
                false
            ),
            (.operating(.saving, from: .running(sessionID: UUID())), false),
            (.operating(.bringUp(.guestStart(.restoringSavedState)), from: .suspended, boundSession: UUID()), false),
            (.operating(.capturingSnapshot(.live), from: .running(sessionID: UUID())), false),
            (.settled(.stopped), false),
        ])
    func forceStopValidationFollowsTheStoppableStates(
        phase: PhaseFixture, isEnabled: Bool
    ) {
        let fixture = makeFixture()
        makeMenuInstance(in: fixture.viewModel, phase: phase.phase)
        let item = makeMenuItem(#selector(AppDelegate.forceStopVM(_:)))

        #expect(fixture.validate(item) == isEnabled, "\(phase)")
    }

    @Test("A build with no bundled guest-agent disk withholds the command")
    func guestAgentDiskWithoutBundledImage() {
        let fixture = makeFixture(hasBundledGuestAgentDisk: false)
        let instance = makeMenuInstance(in: fixture.viewModel, phase: .running(sessionID: UUID()))
        let item = makeMenuItem(#selector(AppDelegate.toggleGuestAgentDisk(_:)))

        #expect(fixture.viewModel.capabilities.isAvailable(.toggleGuestAgentDisk, on: instance))
        #expect(!fixture.validate(item))
        #expect(item.title == GuestAgentDiskControl.unavailableTitle)
    }

    @Test("A bundled guest-agent disk hands title and enablement to the item model")
    func guestAgentDiskWithBundledImage() {
        let fixture = makeFixture()
        let instance = makeMenuInstance(in: fixture.viewModel, phase: .running(sessionID: UUID()))
        let item = makeMenuItem(#selector(AppDelegate.toggleGuestAgentDisk(_:)))
        let model = GuestAgentDiskControl.model(for: instance)

        #expect(fixture.validate(item) == model.isEnabled)
        #expect(item.title == model.title)
    }

    @Test("The Clone items name the preference with no VM selected")
    func cloneTitlesWithoutSelection() {
        preferences.cloneOutcome = .newMachine
        let fixture = makeFixture()
        let clone = makeMenuItem(#selector(AppDelegate.cloneVM(_:)))
        let alternate = makeMenuItem(#selector(AppDelegate.cloneVMAlternate(_:)))

        #expect(!fixture.validate(clone))
        #expect(!fixture.validate(alternate))
        #expect(clone.title == "Clone as New Machine")
        #expect(alternate.title == "Clone as Exact Copy")
        #expect(!alternate.isHidden)
    }

    @Test("A guest running macOS 12 shows only Clone as Exact Copy")
    func cloneTitlesForAMontereyGuest() {
        preferences.cloneOutcome = .newMachine
        let fixture = makeFixture()
        makeMenuInstance(in: fixture.viewModel) { $0.lastSeenGuestOSVersion = "12.7.6" }
        let clone = makeMenuItem(#selector(AppDelegate.cloneVM(_:)))
        let alternate = makeMenuItem(#selector(AppDelegate.cloneVMAlternate(_:)))

        _ = fixture.validate(clone)
        _ = fixture.validate(alternate)
        #expect(clone.title == "Clone as Exact Copy")
        #expect(alternate.isHidden)
    }

    @Test(
        "Clone is enabled for a stopped, suspended, paused or running VM, and greyed while an operation holds it",
        arguments: [
            (PhaseFixture.settled(.stopped), true),
            (.settled(.suspended), true),
            (.settled(.running(sessionID: UUID())), true),
            (.settled(.livePaused(sessionID: UUID())), true),
            (.operating(.saving, from: .running(sessionID: UUID())), false),
            (.operating(.copyingOut(.live), from: .running(sessionID: UUID())), false),
        ])
    func cloneValidationFollowsTheCloneableStates(phase: PhaseFixture, isEnabled: Bool) throws {
        let fixture = makeFixture()
        let instance = makeMenuInstance(in: fixture.viewModel, phase: phase.phase)
        if phase.phase == .suspended { try VMInstanceFixture.writeSaveFile(for: instance) }

        #expect(
            fixture.validate(makeMenuItem(#selector(AppDelegate.cloneVM(_:)))) == isEnabled,
            "\(phase)")
    }

    @Test("Take Snapshot is greyed for a running VM whose guest can write an external disk, and enabled once stopped")
    func takeSnapshotValidationWithAWritableExternalDisk() {
        let writable: (inout VMConfiguration) -> Void = {
            $0.removableMedia = [RemovableMediaItem(path: "/Volumes/Data/Scratch.img", readOnly: false)]
        }
        let item = makeMenuItem(#selector(AppDelegate.takeSnapshot(_:)))

        let runningFixture = makeFixture()
        let running = makeMenuInstance(
            in: runningFixture.viewModel, phase: .running(sessionID: UUID()), mutate: writable)
        #expect(
            runningFixture.viewModel.capabilities.decision(.takeSnapshot, on: running, posture: .offer)
                == .refuse(.takesStoppedVM(.snapshotWritingOutsideBundle)))
        #expect(!runningFixture.validate(item))
        let stoppedFixture = makeFixture()
        makeMenuInstance(in: stoppedFixture.viewModel, phase: .stopped, mutate: writable)
        #expect(stoppedFixture.validate(item))
    }

    @Test("Clone is greyed for a running VM whose guest can write an external disk, and enabled once stopped")
    func cloneValidationWithAWritableExternalDisk() {
        let writable: (inout VMConfiguration) -> Void = {
            $0.storageDisks = [
                StorageDisk(path: "Disk.asif", isInternal: true),
                StorageDisk(path: "/Volumes/Data/Shared.asif", readOnly: false),
            ]
        }
        let item = makeMenuItem(#selector(AppDelegate.cloneVM(_:)))

        let runningFixture = makeFixture()
        let running = makeMenuInstance(
            in: runningFixture.viewModel, phase: .running(sessionID: UUID()), mutate: writable)
        #expect(
            runningFixture.viewModel.capabilities.decision(.clone, on: running, posture: .offer)
                == .refuse(.takesStoppedVM(.cloneWritingOutsideBundle)))
        #expect(!runningFixture.validate(item))
        let stoppedFixture = makeFixture()
        makeMenuInstance(in: stoppedFixture.viewModel, phase: .stopped, mutate: writable)
        #expect(stoppedFixture.validate(item))
    }

    @Test("The pop-out title follows where the display lives")
    func popOutTitleFollowsDisplayMode() {
        let fixture = makeFixture()
        let instance = makeMenuInstance(in: fixture.viewModel, phase: .running(sessionID: UUID()))
        let item = makeMenuItem(#selector(AppDelegate.togglePopOut(_:)))

        #expect(fixture.validate(item))
        #expect(item.title == "Pop Out Display")

        instance.displayMode = .popOut
        #expect(fixture.validate(item))
        #expect(item.title == "Pop In Display")
    }

    @Test("The fullscreen title follows whether the VM is fullscreen")
    func fullscreenTitleFollowsDisplayMode() {
        let fixture = makeFixture()
        let instance = makeMenuInstance(in: fixture.viewModel, phase: .running(sessionID: UUID()))
        let item = makeMenuItem(#selector(AppDelegate.toggleFullscreen(_:)))

        #expect(fixture.validate(item))
        #expect(item.title == "Fullscreen Display")

        instance.displayMode = .fullscreen
        #expect(fixture.validate(item))
        #expect(item.title == "Exit Fullscreen Display")
    }

    @Test("Every Virtual Machine menu command maps to a capability")
    func everyVMCommandIsGated() {
        let fixture = makeFixture()
        let vmMenu = submenu(titled: "Virtual Machine", in: fixture.controller.makeMainMenu())

        // A parent item is skipped: AppKit assigns `submenuAction:` to any item
        // carrying a submenu, and opening one invokes no command.
        let ungated = (vmMenu?.items ?? [])
            .filter { $0.action != nil && $0.submenu == nil }
            .filter { MainMenuController.capability(for: $0.action) == nil }
        #expect(ungated.isEmpty, "Ungated: \(ungated.map(\.title))")
    }
}
