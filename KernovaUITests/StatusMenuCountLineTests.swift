import AppKit
import Testing

@testable import KernovaUI

/// Unit tests for `StatusMenuCountLine` — a status-item dropdown line counting
/// alerts held for want of a window, exercised as the undone-start line.
///
/// `rebuild(count:)` covers the from-scratch path `menuNeedsUpdate` runs on each
/// open; `sync(to:after:)` covers the in-place edits applied while the menu is
/// on screen, where the line has to land in its slot under the anchor and keep
/// its identity across a retitle.
@Suite("StatusMenuCountLine", .caseScoped)
@MainActor
struct StatusMenuCountLineTests {
    private final class ActionTarget: NSObject {
        @objc func undoneStartsTapped(_: NSMenuItem) {}
    }

    /// Builds a menu shaped like the real dropdown — the anchor above, more
    /// items below — with the section rebuilt for `count`.
    private func makeSection(
        count: Int
    ) -> (
        menu: NSMenu, section: StatusMenuCountLine, anchor: NSMenuItem,
        target: ActionTarget
    ) {
        let menu = NSMenu()
        let target = ActionTarget()
        let section = StatusMenuCountLine(
            menu: menu, target: target, action: #selector(ActionTarget.undoneStartsTapped(_:)),
            title: StatusMenuCountLine.undoneStartTitle(count:))
        let anchor = NSMenuItem(title: "Open Kernova", action: nil, keyEquivalent: "")
        menu.addItem(anchor)
        section.rebuild(count: count)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Kernova", action: nil, keyEquivalent: ""))
        return (menu, section, anchor, target)
    }

    // MARK: - Title

    @Test("Waiting alerts title their line by count, and none produce no line")
    func waitingAlertTitles() {
        #expect(StatusMenuCountLine.waitingAlertTitle(count: 0) == nil)
        #expect(StatusMenuCountLine.waitingAlertTitle(count: 1) == "1 Alert Waiting\u{2026}")
        #expect(StatusMenuCountLine.waitingAlertTitle(count: 3) == "3 Alerts Waiting\u{2026}")
    }

    // MARK: - Sync

    @Test("A first undone start while the menu is open inserts the line under the anchor")
    func syncInsertsTheLine() {
        let (menu, section, anchor, target) = makeSection(count: 0)

        section.sync(to: 1, after: anchor)

        #expect(
            menu.items.map(\.title) == [
                "Open Kernova", "1 VM Didn\u{2019}t Start\u{2026}", "", "Quit Kernova",
            ])
        #expect(menu.items[1].target === target)
    }

    @Test("A further undone start retitles the line rather than replacing it")
    func syncRetitlesInPlace() {
        let (menu, section, anchor, _) = makeSection(count: 1)
        let line = menu.items[1]

        section.sync(to: 2, after: anchor)

        #expect(menu.items[1] === line)
        #expect(line.title == "2 VMs Didn\u{2019}t Start\u{2026}")
    }

    @Test("A line removed and earned again lands back in its slot")
    func syncReinsertsAfterRemoval() {
        let (menu, section, anchor, _) = makeSection(count: 1)

        section.sync(to: 0, after: anchor)
        section.sync(to: 1, after: anchor)

        #expect(
            menu.items.map(\.title) == [
                "Open Kernova", "1 VM Didn\u{2019}t Start\u{2026}", "", "Quit Kernova",
            ])
    }
}
