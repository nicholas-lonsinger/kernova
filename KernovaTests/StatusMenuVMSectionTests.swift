import AppKit
import KernovaKit
import Testing

@testable import Kernova

/// Unit tests for `StatusMenuVMSection` — the status-item dropdown's VM rows.
///
/// `rebuild(rows:)` covers the from-scratch path `menuNeedsUpdate` runs on each
/// open; `sync(to:)` covers the in-place edits applied while the menu is on
/// screen, where item identity matters: a surviving row must be retitled, never
/// replaced, so the menu doesn't collapse under the cursor.
@Suite("StatusMenuVMSection", .admissionGated)
@MainActor
struct StatusMenuVMSectionTests {
    private final class RowTarget: NSObject {
        @objc func rowTapped(_: NSMenuItem) {}
    }

    private func makeInstance(name: String = "Test VM", phase: VMLifecyclePhase = .running(sessionID: UUID()))
        -> VMInstance
    {
        let config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, phase: phase)
    }

    private func row(_ id: UUID, _ title: String, notice: String? = nil) -> StatusMenuVMRow {
        StatusMenuVMRow(instanceID: id, title: title, noticeText: notice)
    }

    /// Stands a refusal on `instance`'s transfer report, as a producer would.
    private func reportRefusal(
        _ failure: ClipboardTransferFailure, gesture: ClipboardTransferGesture,
        on instance: VMInstance
    ) {
        instance.clipboardTransfers.finish(
            ClipboardTransferFinish(
                gesture: gesture, outcome: .failed(failure), peerName: instance.name))
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
        let running = makeInstance(name: "Build VM", phase: .running(sessionID: UUID()))
        let starting = makeInstance(name: "CI VM", phase: .starting(sessionID: nil))
        let stopped = makeInstance(name: "Idle VM", phase: .stopped)

        let rows = StatusMenuVMSection.rows(for: [running, starting, stopped])

        #expect(
            rows == [
                StatusMenuVMRow(instanceID: running.instanceID, title: "Build VM — Running"),
                StatusMenuVMRow(instanceID: starting.instanceID, title: "CI VM — Starting"),
            ])
    }

    @Test("A VM with an outstanding clipboard refusal carries its dropdown line")
    func rowModelCarriesTheClipboardLine() {
        let running = makeInstance(name: "Build VM", phase: .running(sessionID: UUID()))
        let quiet = makeInstance(name: "CI VM", phase: .running(sessionID: UUID()))
        reportRefusal(
            .tooLarge(limitBytes: ClipboardPasteLimit.defaultBytes), gesture: .copy, on: running)

        let rows = StatusMenuVMSection.rows(for: [running, quiet])

        #expect(rows.map(\.noticeText) == ["Clipboard: too large to copy to your Mac", nil])
    }

    @Test("A running transfer draws no dropdown line — the readout is its surface")
    func rowModelSkipsRunningReports() {
        let running = makeInstance(name: "Build VM", phase: .running(sessionID: UUID()))
        let operation = ClipboardTransferOperation(
            gesture: .paste, direction: .inbound, peerName: running.name, revealDelay: 0,
            now: { 0 }, schedule: { _, _ in }, reporter: running.clipboardTransfers)
        running.clipboardTransfers.publish(
            from: operation,
            .running(
                ClipboardProgressSnapshot(
                    direction: .inbound, peerName: running.name, currentItemName: nil,
                    filesCompleted: 0, fileCount: 1, bytesTransferred: 1, totalBytes: 2,
                    bytesPerSecond: nil, secondsRemaining: nil, gesture: .paste,
                    elapsedSeconds: 1), since: Date()))

        #expect(StatusMenuVMSection.rows(for: [running]).map(\.noticeText) == [nil])
    }

    @Test("A stopped VM's refusal never reaches the dropdown — it has no row to sit under")
    func rowModelSkipsIssuesOfVMsWithoutRows() {
        let stopped = makeInstance(name: "Idle VM", phase: .stopped)
        reportRefusal(.timedOut, gesture: .paste, on: stopped)

        let rows = StatusMenuVMSection.rows(for: [stopped])

        #expect(rows.isEmpty)
    }

    @Test("A preparing phantom's row shows its operation, not raw status")
    func rowModelPreparing() {
        let phantom = makeInstance(name: "Clone", phase: .stopped)
        phantom.preparingState = VMInstance.PreparingState(operation: .cloning(sourceID: UUID()), task: Task {})

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

    @Test("Rebuild puts an indented, disabled notice line under the row it belongs to")
    func rebuildInsertsNoticeLines() {
        let first = UUID()
        let second = UUID()
        let (menu, _, _) = makeSection(rows: [
            row(first, "One — Running", notice: "Clipboard: too large to copy to your Mac"),
            row(second, "Two — Running"),
        ])

        #expect(
            menu.items.map(\.title) == [
                "Open Kernova", "", "One — Running", "Clipboard: too large to copy to your Mac",
                "Two — Running", "", "Quit Kernova",
            ])
        #expect(menu.items[3].isEnabled == false)
        #expect(menu.items[3].indentationLevel == 1)
        #expect(menu.items[3].representedObject == nil)
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

    @Test("An issue arriving while the menu is open inserts its line under the row")
    func syncInsertsNoticeLine() {
        let id = UUID()
        let other = UUID()
        let (menu, section, _) = makeSection(
            rows: [row(id, "One — Running"), row(other, "Two — Running")])
        let rowItem = menu.items[2]

        section.sync(to: [
            row(id, "One — Running", notice: "Clipboard: paste from the guest timed out"),
            row(other, "Two — Running"),
        ])

        #expect(
            menu.items.map(\.title) == [
                "Open Kernova", "", "One — Running", "Clipboard: paste from the guest timed out",
                "Two — Running", "", "Quit Kernova",
            ])
        #expect(menu.items[2] === rowItem)
        #expect(menu.items[3].indentationLevel == 1)
    }

    @Test("A cleared issue drops its line without disturbing the rows")
    func syncRemovesNoticeLine() {
        let id = UUID()
        let (menu, section, _) = makeSection(rows: [
            row(id, "VM — Running", notice: "Clipboard: paste from the guest timed out")
        ])
        let rowItem = menu.items[2]

        section.sync(to: [row(id, "VM — Running")])

        #expect(
            menu.items.map(\.title) == [
                "Open Kernova", "", "VM — Running", "", "Quit Kernova",
            ])
        #expect(menu.items[2] === rowItem)
    }

    @Test("A superseding issue retitles the existing line in place")
    func syncRetitlesNoticeLine() {
        let id = UUID()
        let (menu, section, _) = makeSection(rows: [
            row(id, "VM — Running", notice: "Clipboard: paste from the guest timed out")
        ])
        let noticeItem = menu.items[3]

        section.sync(to: [row(id, "VM — Running", notice: "Clipboard: earlier copy was removed")])

        #expect(menu.items[3] === noticeItem)
        #expect(noticeItem.title == "Clipboard: earlier copy was removed")
        #expect(menu.items.count == 6)
    }

    @Test("A VM stopping takes its notice line with its row")
    func syncRemovesNoticeLineWithTheRow() {
        let stopping = UUID()
        let surviving = UUID()
        let (menu, section, _) = makeSection(rows: [
            row(stopping, "One — Running", notice: "Clipboard: earlier copy was removed"),
            row(surviving, "Two — Running"),
        ])

        section.sync(to: [row(surviving, "Two — Running")])

        #expect(
            menu.items.map(\.title) == [
                "Open Kernova", "", "Two — Running", "", "Quit Kernova",
            ])
    }

    @Test("Reordering rows carries each notice line under its own row")
    func syncReordersNoticeLinesWithRows() {
        let first = UUID()
        let second = UUID()
        let (menu, section, _) = makeSection(rows: [
            row(first, "One — Running", notice: "Clipboard: earlier copy was removed"),
            row(second, "Two — Running", notice: "Clipboard: some items weren't forwarded"),
        ])

        section.sync(to: [
            row(second, "Two — Running", notice: "Clipboard: some items weren't forwarded"),
            row(first, "One — Running", notice: "Clipboard: earlier copy was removed"),
        ])

        #expect(
            menu.items.map(\.title) == [
                "Open Kernova", "", "Two — Running", "Clipboard: some items weren't forwarded",
                "One — Running", "Clipboard: earlier copy was removed", "", "Quit Kernova",
            ])
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
