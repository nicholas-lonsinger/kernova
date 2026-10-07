import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Covers `MainMenuController.validate(_:)` — the one decision behind every menu
/// command's enablement and the titles that name what the command will do.
///
/// The controller is built but never installed: `install()` writes
/// `NSApp.mainMenu` in the shared test host.
@Suite("MainMenuController validation", .serialized, .caseScoped)
@MainActor
struct MainMenuValidationTests {
    private let preferences = makeTestPreferences()

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
            viewModel: viewModel, hasBundledGuestAgentDisk: hasBundledGuestAgentDisk)
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
        let instance = makeMenuInstance {
            $0.installContext = MacOSInstallContext(source: .localFile)
        }
        let fixture = makeFixture(instance: instance)
        let item = makeMenuItem(#selector(AppDelegate.startVM(_:)))

        #expect(fixture.controller.validate(item))
        #expect(item.title == instance.startAction.label)
        #expect(item.title == "Install")
    }

    @Test("A suspended VM's stop item discards the saved state")
    func stopRetitlesForSuspendedVM() throws {
        let instance = makeMenuInstance(phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)
        let fixture = makeFixture(instance: instance)
        let item = makeMenuItem(#selector(AppDelegate.stopVM(_:)))

        // The graceful stop is unavailable and the discard is what the VM
        // admits, so the item is enabled through the second capability alone.
        #expect(!fixture.viewModel.capabilities.isAvailable(.stop, on: instance))
        #expect(fixture.viewModel.capabilities.isAvailable(.discardSavedState, on: instance))
        #expect(fixture.controller.validate(item))
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
        let instance = makeMenuInstance(phase: phase.phase)
        let fixture = makeFixture(instance: instance)
        let item = makeMenuItem(#selector(AppDelegate.forceStopVM(_:)))

        #expect(fixture.controller.validate(item) == isEnabled, "\(phase)")
    }

    @Test("A build with no bundled guest-agent disk withholds the command")
    func guestAgentDiskWithoutBundledImage() {
        let instance = makeMenuInstance(phase: .running(sessionID: UUID()))
        let fixture = makeFixture(instance: instance, hasBundledGuestAgentDisk: false)
        let item = makeMenuItem(#selector(AppDelegate.toggleGuestAgentDisk(_:)))

        #expect(fixture.viewModel.capabilities.isAvailable(.toggleGuestAgentDisk, on: instance))
        #expect(!fixture.controller.validate(item))
        #expect(item.title == GuestAgentDiskControl.unavailableTitle)
    }

    @Test("A bundled guest-agent disk hands title and enablement to the item model")
    func guestAgentDiskWithBundledImage() {
        let instance = makeMenuInstance(phase: .running(sessionID: UUID()))
        let fixture = makeFixture(instance: instance)
        let item = makeMenuItem(#selector(AppDelegate.toggleGuestAgentDisk(_:)))
        let model = GuestAgentDiskControl.model(for: instance)

        #expect(fixture.controller.validate(item) == model.isEnabled)
        #expect(item.title == model.title)
    }

    @Test("The Clone items name the preference with no VM selected")
    func cloneTitlesWithoutSelection() {
        preferences.cloneOutcome = .newMachine
        let fixture = makeFixture(instance: nil)
        let clone = makeMenuItem(#selector(AppDelegate.cloneVM(_:)))
        let alternate = makeMenuItem(#selector(AppDelegate.cloneVMAlternate(_:)))

        #expect(!fixture.controller.validate(clone))
        #expect(!fixture.controller.validate(alternate))
        #expect(clone.title == "Clone as New Machine")
        #expect(alternate.title == "Clone as Exact Copy")
        #expect(!alternate.isHidden)
    }

    @Test("A guest running macOS 12 shows only Clone as Exact Copy")
    func cloneTitlesForAMontereyGuest() {
        preferences.cloneOutcome = .newMachine
        let instance = makeMenuInstance { $0.lastSeenGuestOSVersion = "12.7.6" }
        let fixture = makeFixture(instance: instance)
        let clone = makeMenuItem(#selector(AppDelegate.cloneVM(_:)))
        let alternate = makeMenuItem(#selector(AppDelegate.cloneVMAlternate(_:)))

        _ = fixture.controller.validate(clone)
        _ = fixture.controller.validate(alternate)
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
        let instance = makeMenuInstance(phase: phase.phase)
        if phase.phase == .suspended { try VMInstanceFixture.writeSaveFile(for: instance) }
        let fixture = makeFixture(instance: instance)

        #expect(
            fixture.controller.validate(makeMenuItem(#selector(AppDelegate.cloneVM(_:)))) == isEnabled,
            "\(phase)")
    }

    @Test("Take Snapshot is greyed for a running VM whose guest can write an external disk, and enabled once stopped")
    func takeSnapshotValidationWithAWritableExternalDisk() {
        let writable: (inout VMConfiguration) -> Void = {
            $0.removableMedia = [RemovableMediaItem(path: "/Volumes/Data/Scratch.img", readOnly: false)]
        }
        let item = makeMenuItem(#selector(AppDelegate.takeSnapshot(_:)))

        // Each fixture is held for the validation: the controller's host is weak.
        let running = makeMenuInstance(phase: .running(sessionID: UUID()), mutate: writable)
        let runningFixture = makeFixture(instance: running)
        #expect(
            runningFixture.viewModel.capabilities.decision(.takeSnapshot, on: running, posture: .offer)
                == .refuse(.takesStoppedVM(.snapshotWritingOutsideBundle)))
        #expect(!runningFixture.controller.validate(item))
        let stopped = makeMenuInstance(phase: .stopped, mutate: writable)
        let stoppedFixture = makeFixture(instance: stopped)
        #expect(stoppedFixture.controller.validate(item))
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

        // Each fixture is held for the validation: the controller's host is weak.
        let running = makeMenuInstance(phase: .running(sessionID: UUID()), mutate: writable)
        let runningFixture = makeFixture(instance: running)
        #expect(
            runningFixture.viewModel.capabilities.decision(.clone, on: running, posture: .offer)
                == .refuse(.takesStoppedVM(.cloneWritingOutsideBundle)))
        #expect(!runningFixture.controller.validate(item))
        let stopped = makeMenuInstance(phase: .stopped, mutate: writable)
        let stoppedFixture = makeFixture(instance: stopped)
        #expect(stoppedFixture.controller.validate(item))
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
