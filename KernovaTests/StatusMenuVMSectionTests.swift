import AppKit
import Testing

@testable import Kernova

/// Unit tests for `StatusMenuVMSection` — the status-item dropdown's VM rows.
///
/// `rebuild(rows:)` covers the from-scratch path `menuNeedsUpdate` runs on each
/// open; `sync(to:)` covers the in-place edits applied while the menu is on
/// screen, where item identity matters: a surviving row must be retitled, never
/// replaced, so the menu doesn't collapse under the cursor.
@Suite("StatusMenuVMSection")
@MainActor
struct StatusMenuVMSectionTests {
    private final class RowTarget: NSObject {
        @objc func rowTapped(_ sender: NSMenuItem) {}
    }

    private func makeInstance(name: String = "Test VM", status: VMStatus = .running) -> VMInstance {
        let config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, status: status)
    }

    private func row(_ id: UUID, _ title: String) -> StatusMenuVMRow {
        StatusMenuVMRow(instanceID: id, title: title)
    }

    /// Builds a menu shaped like the real dropdown — items above and below the
    /// section — with the section rebuilt from `rows`.
    private func makeSection(
        rows: [StatusMenuVMRow]
    ) -> (menu: NSMenu, section: StatusMenuVMSection, target: RowTarget) {
        let menu = NSMenu()
        let target = RowTarget()
        let section = StatusMenuVMSection(
            menu: menu, rowTarget: target, rowAction: #selector(RowTarget.rowTapped(_:)))
        menu.addItem(NSMenuItem(title: "Open Kernova", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        section.rebuild(rows: rows)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Kernova", action: nil, keyEquivalent: ""))
        return (menu, section, target)
    }

    // MARK: - Row model

    @Test("rows(for:) includes only VMs keeping the app alive, titled name — status")
    func rowModel() {
        let running = makeInstance(name: "Build VM", status: .running)
        let starting = makeInstance(name: "CI VM", status: .starting)
        let stopped = makeInstance(name: "Idle VM", status: .stopped)

        let rows = StatusMenuVMSection.rows(for: [running, starting, stopped])

        #expect(
            rows == [
                StatusMenuVMRow(instanceID: running.instanceID, title: "Build VM — Running"),
                StatusMenuVMRow(instanceID: starting.instanceID, title: "CI VM — Starting"),
            ])
    }

    @Test("A preparing phantom's row shows its operation, not raw status")
    func rowModelPreparing() {
        let phantom = makeInstance(name: "Clone", status: .stopped)
        phantom.preparingState = VMInstance.PreparingState(operation: .cloning, task: Task {})

        let rows = StatusMenuVMSection.rows(for: [phantom])

        #expect(
            rows == [
                StatusMenuVMRow(instanceID: phantom.instanceID, title: "Clone — Cloning\u{2026}")
            ])
    }

    // MARK: - Rebuild

    @Test("Rebuild with no rows appends the disabled placeholder")
    func rebuildEmpty() {
        let (menu, _, _) = makeSection(rows: [])

        #expect(
            menu.items.map(\.title) == [
                "Open Kernova", "", "No virtual machines running", "", "Quit Kernova",
            ])
        #expect(menu.items[2].isEnabled == false)
        #expect(menu.items[2].action == nil)
    }

    @Test("Rebuild appends one wired row per VM")
    func rebuildRows() {
        let first = UUID()
        let second = UUID()
        let (menu, _, target) = makeSection(
            rows: [row(first, "One — Running"), row(second, "Two — Starting")])

        #expect(
            menu.items.map(\.title) == [
                "Open Kernova", "", "One — Running", "Two — Starting", "", "Quit Kernova",
            ])
        #expect(menu.items[2].representedObject as? UUID == first)
        #expect(menu.items[3].representedObject as? UUID == second)
        #expect(menu.items[2].target === target)
        #expect(menu.items[2].action == #selector(RowTarget.rowTapped(_:)))
    }

    // MARK: - Sync

    @Test("A status change retitles the existing item in place")
    func titleUpdatePreservesIdentity() {
        let id = UUID()
        let (menu, section, _) = makeSection(rows: [row(id, "VM — Running")])
        let item = menu.items[2]

        section.sync(to: [row(id, "VM — Suspending")])

        #expect(menu.items[2] === item)
        #expect(item.title == "VM — Suspending")
        #expect(menu.items.count == 5)
    }

    @Test("A VM stopping loses its row while other rows stay in place")
    func removalLeavesSurvivors() {
        let stopping = UUID()
        let surviving = UUID()
        let (menu, section, _) = makeSection(
            rows: [row(stopping, "One — Running"), row(surviving, "Two — Running")])
        let survivor = menu.items[3]

        section.sync(to: [row(surviving, "Two — Running")])

        #expect(
            menu.items.map(\.title) == [
                "Open Kernova", "", "Two — Running", "", "Quit Kernova",
            ])
        #expect(menu.items[2] === survivor)
    }

    @Test("The last VM stopping swaps its row for the placeholder")
    func lastRemovalInsertsPlaceholder() {
        let id = UUID()
        let (menu, section, _) = makeSection(rows: [row(id, "VM — Stopping")])

        section.sync(to: [])

        #expect(
            menu.items.map(\.title) == [
                "Open Kernova", "", "No virtual machines running", "", "Quit Kernova",
            ])
        #expect(menu.items[2].isEnabled == false)
    }

    @Test("A VM starting replaces the placeholder with its row")
    func firstRowRemovesPlaceholder() {
        let id = UUID()
        let (menu, section, target) = makeSection(rows: [])

        section.sync(to: [row(id, "VM — Starting")])

        #expect(
            menu.items.map(\.title) == [
                "Open Kernova", "", "VM — Starting", "", "Quit Kernova",
            ])
        #expect(menu.items[2].representedObject as? UUID == id)
        #expect(menu.items[2].target === target)
    }

    @Test("A newly started VM inserts at its position among existing rows")
    func insertionAmongExistingRows() {
        let first = UUID()
        let third = UUID()
        let (menu, section, _) = makeSection(
            rows: [row(first, "One — Running"), row(third, "Three — Running")])
        let second = UUID()

        section.sync(to: [
            row(first, "One — Running"),
            row(second, "Two — Starting"),
            row(third, "Three — Running"),
        ])

        #expect(
            menu.items.map(\.title) == [
                "Open Kernova", "", "One — Running", "Two — Starting", "Three — Running",
                "", "Quit Kernova",
            ])
    }

    @Test("Sync reorders surviving rows to match the model")
    func reorder() {
        let first = UUID()
        let second = UUID()
        let (menu, section, _) = makeSection(
            rows: [row(first, "One — Running"), row(second, "Two — Running")])
        let firstItem = menu.items[2]
        let secondItem = menu.items[3]

        section.sync(to: [row(second, "Two — Running"), row(first, "One — Running")])

        #expect(menu.items[2] === secondItem)
        #expect(menu.items[3] === firstItem)
    }

    @Test("Rows stay anchored when items are inserted above the section")
    func prefixInsertionKeepsAnchor() {
        let id = UUID()
        let (menu, section, _) = makeSection(rows: [row(id, "VM — Running")])
        menu.insertItem(NSMenuItem(title: "Paste readout", action: nil, keyEquivalent: ""), at: 0)
        menu.insertItem(.separator(), at: 1)
        let started = UUID()

        section.sync(to: [row(id, "VM — Running"), row(started, "New — Starting")])

        #expect(
            menu.items.map(\.title) == [
                "Paste readout", "", "Open Kernova", "", "VM — Running", "New — Starting",
                "", "Quit Kernova",
            ])
    }

    @Test("Sync before the section is in the menu is a no-op")
    func syncBeforeRebuild() {
        let menu = NSMenu()
        let target = RowTarget()
        let section = StatusMenuVMSection(
            menu: menu, rowTarget: target, rowAction: #selector(RowTarget.rowTapped(_:)))

        section.sync(to: [row(UUID(), "VM — Running")])

        #expect(menu.items.isEmpty)
    }

    @Test("Sync after the menu was cleared for rebuild is a no-op")
    func syncAfterRemoveAllItems() {
        let id = UUID()
        let (menu, section, _) = makeSection(rows: [row(id, "VM — Running")])
        menu.removeAllItems()

        section.sync(to: [row(id, "VM — Stopping")])

        #expect(menu.items.isEmpty)
    }
}
