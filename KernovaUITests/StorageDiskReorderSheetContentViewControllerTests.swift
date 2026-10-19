import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

@Suite("StorageDiskReorderSheetContentViewController Tests", .caseScoped)
@MainActor
struct StorageDiskReorderSheetContentViewControllerTests {
    @Test("header includes Boot Order title and an info button")
    func headerShowsTitleAndInfoButton() {
        let vc = make(disks: [disk("Main"), disk("Secondary")])
        vc.loadViewIfNeeded()
        let labels = collectLabels(in: vc.view).map(\.stringValue)
        #expect(labels.contains("Boot Order"))
        #expect(firstSubview(InfoButtonView.self, in: vc.view) != nil)
    }

    @Test("table renders one row per disk")
    func rowsRendered() {
        let disks = [disk("Main"), disk("Secondary"), disk("Installer")]
        let vc = make(disks: disks)
        vc.loadViewIfNeeded()
        guard let table = firstSubview(NSTableView.self, in: vc.view) else {
            Issue.record("Expected an NSTableView")
            return
        }
        #expect(table.numberOfRows == disks.count)
    }

    @Test("Each row states the pane's sizes, its path until they land, and repaints when they move")
    func rowsStateThePanesSizes() throws {
        let measured = disk("Measured")
        let unmeasured = disk("Unmeasured")
        let vc = make(
            disks: [measured, unmeasured],
            sizes: [measured.id: VMBundleLayout.DiskSizes(onDiskBytes: 3_000_000_000, capacityBytes: 64_000_000_000)])
        vc.loadViewIfNeeded()
        let allocated = DataFormatters.formatBytes(64_000_000_000)

        #expect(
            try subtitle(row: 0, in: vc)
                == "\(DataFormatters.formatBytes(3_000_000_000)) (used) / \(allocated) (allocated)")
        #expect(try subtitle(row: 1, in: vc) == unmeasured.path)

        vc.show(sizes: [
            measured.id: VMBundleLayout.DiskSizes(onDiskBytes: 5_000_000_000, capacityBytes: 64_000_000_000),
            unmeasured.id: VMBundleLayout.DiskSizes(capacityBytes: 8_000_000_000),
        ])

        #expect(
            try subtitle(row: 0, in: vc)
                == "\(DataFormatters.formatBytes(5_000_000_000)) (used) / \(allocated) (allocated)")
        #expect(try subtitle(row: 1, in: vc) == "\(DataFormatters.formatBytes(8_000_000_000)) allocated")
    }

    @Test("performReorder downward shifts disk forward and fires onReorder")
    func reorderDownwardFiresCallback() {
        let disks = [disk("A"), disk("B"), disk("C")]
        let vc = make(disks: disks)
        var reorderedOrderings: [[StorageDisk]] = []
        vc.onReorder = { reorderedOrderings.append($0) }
        vc.loadViewIfNeeded()

        // Move "A" (row 0) past "C" — proposedRow == 3 means "after the
        // last row." After the downward shift A should land at index 2.
        let didReorder = vc.performReorder(sourceRow: 0, proposedRow: 3)
        #expect(didReorder)
        #expect(vc.disks.map(\.label) == ["B", "C", "A"])
        #expect(reorderedOrderings.count == 1)
        #expect(reorderedOrderings.last?.map(\.label) == ["B", "C", "A"])
    }

    @Test("performReorder upward shifts disk back and fires onReorder")
    func reorderUpwardFiresCallback() {
        let disks = [disk("A"), disk("B"), disk("C")]
        let vc = make(disks: disks)
        var reorderedOrderings: [[StorageDisk]] = []
        vc.onReorder = { reorderedOrderings.append($0) }
        vc.loadViewIfNeeded()

        // Move "C" (row 2) to the top — proposedRow == 0 means "before
        // the first row." Target stays at 0 (upward drag).
        let didReorder = vc.performReorder(sourceRow: 2, proposedRow: 0)
        #expect(didReorder)
        #expect(vc.disks.map(\.label) == ["C", "A", "B"])
        #expect(reorderedOrderings.last?.map(\.label) == ["C", "A", "B"])
    }

    @Test("performReorder no-ops when source and target collapse to the same index")
    func reorderNoOp() {
        let disks = [disk("A"), disk("B"), disk("C")]
        let vc = make(disks: disks)
        var reorderedOrderings: [[StorageDisk]] = []
        vc.onReorder = { reorderedOrderings.append($0) }
        vc.loadViewIfNeeded()

        // Drag row 1 to proposedRow 1 — target collapses to 1 == source.
        let droppedInPlace = vc.performReorder(sourceRow: 1, proposedRow: 1)
        #expect(!droppedInPlace)
        // Drag row 1 to proposedRow 2 — target == 2 - 1 == 1 == source.
        let droppedJustAfter = vc.performReorder(sourceRow: 1, proposedRow: 2)
        #expect(!droppedJustAfter)
        #expect(vc.disks.map(\.label) == ["A", "B", "C"])
        #expect(reorderedOrderings.isEmpty)
    }

    @Test("performReorder rejects out-of-range source")
    func reorderInvalidSource() {
        let vc = make(disks: [disk("A"), disk("B")])
        vc.loadViewIfNeeded()
        #expect(vc.performReorder(sourceRow: -1, proposedRow: 0) == false)
        #expect(vc.performReorder(sourceRow: 99, proposedRow: 0) == false)
    }

    @Test("pasteboard round-trip via tableView(_:acceptDrop:row:dropOperation:)")
    func acceptDropRoundTrip() {
        let vc = make(disks: [disk("A"), disk("B"), disk("C")])
        var reorderedOrderings: [[StorageDisk]] = []
        vc.onReorder = { reorderedOrderings.append($0) }
        vc.loadViewIfNeeded()
        guard let table = firstSubview(NSTableView.self, in: vc.view) else {
            Issue.record("Expected an NSTableView")
            return
        }

        // Drive the pasteboardWriterForRow → acceptDrop round-trip the
        // way AppKit would: serialize row 0 onto an NSPasteboardItem,
        // hand it back via a stub NSDraggingInfo, and call acceptDrop
        // with the same proposed-row that AppKit would supply for a
        // "drop after row 2" gesture.
        guard
            let writer = vc.tableView(table, pasteboardWriterForRow: 0)
                as? NSPasteboardItem
        else {
            Issue.record("Expected an NSPasteboardItem from pasteboardWriterForRow")
            return
        }
        // A per-test unique name so parallel/retried runs never share this global
        // named pasteboard (matches ClipboardPasteboardIntakeTests).
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("kernova-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([writer])

        let dragInfo = StubDraggingInfo(pasteboard: pasteboard)
        let accepted = vc.tableView(
            table, acceptDrop: dragInfo, row: 3, dropOperation: .above
        )
        #expect(accepted)
        #expect(vc.disks.map(\.label) == ["B", "C", "A"])
        #expect(reorderedOrderings.last?.map(\.label) == ["B", "C", "A"])
    }

    @Test("validateDrop returns .move only for .above")
    func validateDropOperation() {
        let vc = make(disks: [disk("A"), disk("B")])
        vc.loadViewIfNeeded()
        guard let table = firstSubview(NSTableView.self, in: vc.view) else {
            Issue.record("Expected an NSTableView")
            return
        }
        let dragInfo = StubDraggingInfo(
            pasteboard: NSPasteboard(name: NSPasteboard.Name("kernova-test-\(UUID().uuidString)")))
        #expect(
            vc.tableView(table, validateDrop: dragInfo, proposedRow: 1, proposedDropOperation: .above)
                == .move
        )
        #expect(
            vc.tableView(table, validateDrop: dragInfo, proposedRow: 1, proposedDropOperation: .on)
                == []
        )
    }

    @Test("Done button fires onDone")
    func doneFiresCallback() {
        let vc = make(disks: [disk("A"), disk("B")])
        var doneCount = 0
        vc.onDone = { doneCount += 1 }
        vc.loadViewIfNeeded()

        guard let done = findButton(titled: "Done", in: vc.view) else {
            Issue.record("Expected a Done button")
            return
        }
        done.performClick(nil)
        #expect(doneCount == 1)
    }

    @Test("Done button is keyed to Return")
    func doneIsDefault() {
        let vc = make(disks: [disk("A"), disk("B")])
        vc.loadViewIfNeeded()
        guard let done = findButton(titled: "Done", in: vc.view) else {
            Issue.record("Expected a Done button")
            return
        }
        #expect(done.keyEquivalent == "\r")
    }

    // MARK: - Helpers

    @MainActor
    private func make(
        disks: [StorageDisk], sizes: [UUID: VMBundleLayout.DiskSizes] = [:]
    ) -> StorageDiskReorderSheetContentViewController {
        StorageDiskReorderSheetContentViewController(
            disks: disks,
            sizes: sizes,
            fileMonitor: AttachmentFileMonitor(hostNotifications: .isolated())
        )
    }

    /// The subtitle row `row` paints.
    @MainActor
    private func subtitle(row: Int, in vc: StorageDiskReorderSheetContentViewController) throws -> String {
        let table = try #require(firstSubview(NSTableView.self, in: vc.view))
        let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true))
        let disk = vc.disks[row]
        let labels = collectLabels(in: cell).map(\.stringValue)
        return try #require(labels.first { $0 != disk.label })
    }

    private func disk(_ label: String) -> StorageDisk {
        StorageDisk(
            path: "/tmp/\(label).asif",
            readOnly: false,
            label: label,
            isInternal: false,
            kind: .virtio
        )
    }
}

/// Minimum-viable `NSDraggingInfo` stub for the pasteboard round-trip test.
///
/// AppKit's protocol surface is large, but `acceptDrop` /
/// `validateDrop` in our data source only touch `draggingPasteboard`;
/// every other member returns a neutral default.
private final class StubDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        super.init()
    }
    var draggingPasteboard: NSPasteboard { pasteboard }

    // Unused — trap so a future change that starts depending on these
    // surfaces as a test failure rather than silent-default behavior.
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    var draggingFormation: NSDraggingFormation {
        get { .default }
        set { _ = newValue }
    }
    var animatesToDestination: Bool {
        get { false }
        set { _ = newValue }
    }
    var numberOfValidItemsForDrop: Int {
        get { 0 }
        set { _ = newValue }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for: NSView?, classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
