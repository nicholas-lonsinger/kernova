import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

/// Covers `AlertWindowScene.destination(about:)` — which window an alert goes
/// to — over scenes built from named windows.
@Suite("AlertWindowScene routing", .caseScoped)
struct AlertWindowSceneTests {
    private static let vmX = UUID()
    private static let vmY = UUID()

    private static let seen = WindowStanding(isVisible: true, isMiniaturized: false, isOnActiveSpace: true)

    /// A scene with X's display window popped out and the library window open,
    /// every window visible to the user unless `states` says otherwise.
    private func scene(
        working: [(window: String, vmIDs: Set<UUID>)],
        displayWindows: [UUID: String] = [vmX: "display X"],
        library: String? = "library",
        states: [String: WindowStanding] = [:]
    ) -> AlertWindowScene<String> {
        var all: [String: WindowStanding] = [:]
        for window in working.map(\.window) + displayWindows.values + [library].compactMap({ $0 }) {
            all[window] = states[window] ?? Self.seen
        }
        return AlertWindowScene(
            working: working, displayWindows: displayWindows, library: library, states: all)
    }

    /// The library window, which can act on every VM it lists.
    private static let library: (window: String, vmIDs: Set<UUID>) = ("library", [vmX, vmY])

    @Test("The main window answers when the key window shows another VM")
    func mainWindowAnswersBehindTheKeyWindow() {
        let scene = scene(
            working: [("display Y", [Self.vmY]), ("clipboard X", [Self.vmX])],
            displayWindows: [Self.vmY: "display Y"])

        #expect(scene.destination(about: Self.vmX) == "clipboard X")
    }

    @Test("A miniaturized display window is not a target; the library takes its alert")
    func miniaturizedWindowIsNoTarget() {
        let scene = scene(
            working: [],
            states: ["display X": WindowStanding(isVisible: true, isMiniaturized: true, isOnActiveSpace: true)])

        #expect(scene.destination(about: Self.vmX) == "library")
    }

    @Test("With no window the user can see, an alert is held")
    func noVisibleWindowHolds() {
        let hidden = WindowStanding(isVisible: true, isMiniaturized: false, isOnActiveSpace: false)
        let scene = scene(
            working: [],
            states: [
                "display X": hidden,
                "library": WindowStanding(isVisible: true, isMiniaturized: true, isOnActiveSpace: true),
            ])

        #expect(scene.destination(about: Self.vmX) == nil)
        #expect(scene.destination(about: nil) == nil)
    }
}
