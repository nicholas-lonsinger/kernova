import AppKit
import Foundation
import KernovaKit
import Testing

@testable import Kernova
@testable import KernovaCore

/// The check window's layout and keys, over a source the test drives.
@Suite("Config check window", .caseScoped)
@MainActor
struct ConfigCheckViewControllerTests {
    private let preferences = makeTestPreferences()
    private let scratch = TestScratchDirectory(prefix: "ConfigCheckViewControllerTests")

    @Test("Return closes the check window; Use Defaults takes a click")
    func returnCloses() throws {
        let controller = ConfigCheckViewController(source: makeSettingsViewModel(preferences: preferences))
        controller.loadViewIfNeeded()

        #expect(try #require(findButton(titled: "Close", in: controller.view)).keyEquivalent == "\r")
        #expect(try #require(findButton(titled: "Use Defaults", in: controller.view)).keyEquivalent == "")
    }

    @Test("Close sits at the bottom-right whether every file reads or the window shows a report")
    func closeStaysAtTheBottomEdge() async throws {
        let source = GatedConfigCheckSource()
        let controller = ConfigCheckViewController(source: source)
        let root = controller.view
        root.frame = NSRect(x: 0, y: 0, width: 620, height: 420)
        let close = try #require(findButton(titled: "Close", in: root))
        let reportScrollView = try #require(firstSubview(NSScrollView.self, in: root))

        func expectCloseAtBottomRight() {
            root.layoutSubtreeIfNeeded()
            let frame = close.convert(close.bounds, to: root)
            #expect(frame.minY == Spacing.large)
            #expect(frame.maxX == root.bounds.maxX - Spacing.large)
        }

        controller.runCheck()
        try await waitForChange { source.checks.count == 1 }
        source.checks[0].resume(returning: [])
        try await waitForChange { controller.session.report?.files == [] }
        // The view's apply is enqueued by the change itself, so it has run.
        await Task { @MainActor in }.value
        #expect(findLabel(withText: "Kernova read every config file.", in: root) != nil)
        #expect(reportScrollView.isHidden)
        expectCloseAtBottomRight()

        let unrepairable = UnreadableConfigFile(
            location: .networkList(scratch.url.appendingPathComponent("Networks.json")),
            owner: .networkList,
            problems: [ConfigProblem(path: ConfigValuePath([.key("networks")]), issue: .missing)])
        controller.runCheck()
        try await waitForChange { source.checks.count == 2 }
        source.checks[1].resume(returning: [unrepairable])
        try await waitForChange { controller.session.report?.files == [unrepairable] }
        await Task { @MainActor in }.value
        #expect(!reportScrollView.isHidden)
        expectCloseAtBottomRight()
        // The report fills the height the button row leaves it.
        let reportFrame = reportScrollView.convert(reportScrollView.bounds, to: root)
        #expect(reportFrame.minY - close.convert(close.bounds, to: root).maxY <= Spacing.large)
    }
}
