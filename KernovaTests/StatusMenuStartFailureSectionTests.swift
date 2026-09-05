import AppKit
import Testing

@testable import Kernova

/// Unit tests for `StatusMenuStartFailureSection` — the status-item dropdown's
/// failed-start line, the one report a headless launch can make.
///
/// `rebuild(count:)` covers the from-scratch path `menuNeedsUpdate` runs on each
/// open; `sync(to:after:)` covers the in-place edits applied while the menu is
/// on screen, where the line has to land in its slot under the anchor and keep
/// its identity across a retitle.
@Suite("StatusMenuStartFailureSection", .admissionGated)
@MainActor
struct StatusMenuStartFailureSectionTests {
    private final class ActionTarget: NSObject {
        private(set) var tapCount = 0
        @objc func failuresTapped(_: NSMenuItem) { tapCount += 1 }
    }

    /// Builds a menu shaped like the real dropdown — the anchor above, more
    /// items below — with the section rebuilt for `count`.
    private func makeSection(
        count: Int
    ) -> (
        menu: NSMenu, section: StatusMenuStartFailureSection, anchor: NSMenuItem,
        target: ActionTarget
    ) {
        let menu = NSMenu()
        let target = ActionTarget()
        let section = StatusMenuStartFailureSection(
            menu: menu, target: target, action: #selector(ActionTarget.failuresTapped(_:)))
        let anchor = NSMenuItem(title: "Open Kernova", action: nil, keyEquivalent: "")
        menu.addItem(anchor)
        section.rebuild(count: count)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Kernova", action: nil, keyEquivalent: ""))
        return (menu, section, anchor, target)
    }

    // MARK: - Title

    @Test("No failures produce no line")
    func titleForNone() {
        #expect(StatusMenuStartFailureSection.title(count: 0) == nil)
    }

    @Test("One failure titles the line in the singular")
    func titleForOne() {
        #expect(StatusMenuStartFailureSection.title(count: 1) == "1 VM Failed to Start\u{2026}")
    }

    @Test("Several failures title the line in the plural, counted")
    func titleForSeveral() {
        #expect(StatusMenuStartFailureSection.title(count: 4) == "4 VMs Failed to Start\u{2026}")
    }

    // MARK: - Rebuild

    @Test("Rebuild with no failures adds nothing")
    func rebuildEmpty() {
        let (menu, _, _, _) = makeSection(count: 0)

        #expect(menu.items.map(\.title) == ["Open Kernova", "", "Quit Kernova"])
    }

    @Test("Rebuild puts the line directly under the item above it")
    func rebuildAddsTheLine() {
        let (menu, _, _, target) = makeSection(count: 2)

        #expect(
            menu.items.map(\.title) == [
                "Open Kernova", "2 VMs Failed to Start\u{2026}", "", "Quit Kernova",
            ])
        #expect(menu.items[1].target === target)
        #expect(menu.items[1].isEnabled)
    }

    @Test("The line fires the action it was built with")
    func lineFiresItsAction() throws {
        let (menu, _, _, target) = makeSection(count: 1)
        let line = try #require(menu.items.first(where: { $0.target === target }))

        NSApp.sendAction(try #require(line.action), to: line.target, from: line)

        #expect(target.tapCount == 1)
    }

    // MARK: - Sync

    @Test("A first failure while the menu is open inserts the line under the anchor")
    func syncInsertsTheLine() {
        let (menu, section, anchor, target) = makeSection(count: 0)

        section.sync(to: 1, after: anchor)

        #expect(
            menu.items.map(\.title) == [
                "Open Kernova", "1 VM Failed to Start\u{2026}", "", "Quit Kernova",
            ])
        #expect(menu.items[1].target === target)
    }

    @Test("A further failure retitles the line rather than replacing it")
    func syncRetitlesInPlace() {
        let (menu, section, anchor, _) = makeSection(count: 1)
        let line = menu.items[1]

        section.sync(to: 2, after: anchor)

        #expect(menu.items[1] === line)
        #expect(line.title == "2 VMs Failed to Start\u{2026}")
    }

    @Test("Draining the failures removes the line")
    func syncRemovesTheLine() {
        let (menu, section, anchor, _) = makeSection(count: 3)

        section.sync(to: 0, after: anchor)

        #expect(menu.items.map(\.title) == ["Open Kernova", "", "Quit Kernova"])
    }

    @Test("A line removed and earned again lands back in its slot")
    func syncReinsertsAfterRemoval() {
        let (menu, section, anchor, _) = makeSection(count: 1)

        section.sync(to: 0, after: anchor)
        section.sync(to: 1, after: anchor)

        #expect(
            menu.items.map(\.title) == [
                "Open Kernova", "1 VM Failed to Start\u{2026}", "", "Quit Kernova",
            ])
    }
}
