import Foundation
import Testing

@testable import Kernova

/// Covers `AlertWindowScene.destination(about:)` — which window an alert goes
/// to — over scenes built from named windows.
@Suite("AlertWindowScene routing", .caseScoped)
struct AlertWindowSceneTests {
    private static let vmX = UUID()
    private static let vmY = UUID()

    private static let seen = AlertWindowState(isVisible: true, isMiniaturized: false, isOnActiveSpace: true)

    /// A scene with X's display window popped out and the library window open,
    /// every window visible to the user unless `states` says otherwise.
    private func scene(
        working: [(window: String, vmID: UUID?)],
        displayWindows: [UUID: String] = [vmX: "display X"],
        library: String? = "library",
        states: [String: AlertWindowState] = [:]
    ) -> AlertWindowScene<String> {
        var all: [String: AlertWindowState] = [:]
        for window in working.map(\.window) + displayWindows.values + [library].compactMap({ $0 }) {
            all[window] = states[window] ?? Self.seen
        }
        return AlertWindowScene(
            working: working, displayWindows: displayWindows, library: library, states: all)
    }

    @Test("An alert about X raised from X's display window goes to that window")
    func workingDisplayWindowTakesItsVMsAlert() {
        let scene = scene(working: [("display X", Self.vmX), ("library", Self.vmY)])

        // The #1581 Force Stop and the #1580 agent-disk notice both route here,
        // whatever the library window is doing.
        #expect(scene.destination(about: Self.vmX) == "display X")
    }

    @Test("An alert about X raised from the library window showing X goes to the library")
    func workingLibraryTakesItsSelectionsAlert() {
        let scene = scene(working: [("library", Self.vmX)])

        #expect(scene.destination(about: Self.vmX) == "library")
    }

    @Test("A working window showing X wins over X's display window")
    func workingWindowShowingTheVMWins() {
        let scene = scene(working: [("clipboard X", Self.vmX)])

        #expect(scene.destination(about: Self.vmX) == "clipboard X")
    }

    @Test("The main window answers when the key window shows another VM")
    func mainWindowAnswersBehindTheKeyWindow() {
        let scene = scene(
            working: [("display Y", Self.vmY), ("clipboard X", Self.vmX)],
            displayWindows: [Self.vmY: "display Y"])

        #expect(scene.destination(about: Self.vmX) == "clipboard X")
    }

    @Test("With the working window showing another VM, X's display window takes X's alert")
    func displayWindowWhenTheWorkingWindowShowsAnotherVM() {
        let scene = scene(working: [("library", Self.vmY)])

        #expect(scene.destination(about: Self.vmX) == "display X")
    }

    @Test("A VM with no display window and no working window has its alerts go to the library")
    func libraryForAVMWithNoWindowOfItsOwn() {
        let scene = scene(working: [], displayWindows: [:])

        #expect(scene.destination(about: Self.vmX) == "library")
    }

    @Test("An alert about no VM goes to the library, even from a display window")
    func libraryForAnAlertAboutNoVM() {
        let scene = scene(working: [("display X", Self.vmX)])

        #expect(scene.destination(about: nil) == "library")
    }

    @Test("A miniaturized display window is not a target; the library takes its alert")
    func miniaturizedWindowIsNoTarget() {
        let scene = scene(
            working: [],
            states: ["display X": AlertWindowState(isVisible: true, isMiniaturized: true, isOnActiveSpace: true)])

        #expect(scene.destination(about: Self.vmX) == "library")
    }

    @Test("A display window on another Space is not a target; the library takes its alert")
    func otherSpaceWindowIsNoTarget() {
        let scene = scene(
            working: [],
            states: ["display X": AlertWindowState(isVisible: true, isMiniaturized: false, isOnActiveSpace: false)])

        #expect(scene.destination(about: Self.vmX) == "library")
    }

    @Test("With no window the user can see, an alert is held")
    func noVisibleWindowHolds() {
        let hidden = AlertWindowState(isVisible: true, isMiniaturized: false, isOnActiveSpace: false)
        let scene = scene(
            working: [],
            states: [
                "display X": hidden,
                "library": AlertWindowState(isVisible: true, isMiniaturized: true, isOnActiveSpace: true),
            ])

        #expect(scene.destination(about: Self.vmX) == nil)
        #expect(scene.destination(about: nil) == nil)
    }

    @Test("With the library window closed and the VM headless, an alert is held")
    func closedLibraryAndHeadlessVMHolds() {
        let scene = scene(
            working: [], displayWindows: [:],
            states: ["library": AlertWindowState(isVisible: false, isMiniaturized: false, isOnActiveSpace: true)])

        #expect(scene.destination(about: Self.vmX) == nil)
    }
}
