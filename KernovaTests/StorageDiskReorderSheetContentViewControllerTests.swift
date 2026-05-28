import Testing
import AppKit
import Foundation
@testable import Kernova

@Suite("StorageDiskReorderSheetContentViewController Tests")
@MainActor
struct StorageDiskReorderSheetContentViewControllerTests {
    @Test("header includes Boot Order title and an info button")
    func headerShowsTitleAndInfoButton() {
        let vc = make(disks: [disk("Main"), disk("Secondary")])
        vc.loadViewIfNeeded()
        let labels = collectLabels(in: vc.view).map(\.stringValue)
        #expect(labels.contains("Boot Order"))
        #expect(findFirst(InfoButtonView.self, in: vc.view) != nil)
    }

    @Test("table renders one row per disk")
    func rowsRendered() {
        let disks = [disk("Main"), disk("Secondary"), disk("Installer")]
        let vc = make(disks: disks)
        vc.loadViewIfNeeded()
        guard let table = findFirst(NSTableView.self, in: vc.view) else {
            Issue.record("Expected an NSTableView")
            return
        }
        #expect(table.numberOfRows == disks.count)
    }

    @Test("performReorder downward shifts disk forward and fires delegate")
    func reorderDownwardFiresDelegate() {
        let disks = [disk("A"), disk("B"), disk("C")]
        let vc = make(disks: disks)
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.loadViewIfNeeded()

        // Move "A" (row 0) past "C" — proposedRow == 3 means "after the
        // last row." After the downward shift A should land at index 2.
        let didReorder = vc.performReorder(sourceRow: 0, proposedRow: 3)
        #expect(didReorder)
        #expect(vc.disks.map(\.label) == ["B", "C", "A"])
        #expect(delegate.reorderedOrderings.count == 1)
        #expect(delegate.reorderedOrderings.last?.map(\.label) == ["B", "C", "A"])
    }

    @Test("performReorder upward shifts disk back and fires delegate")
    func reorderUpwardFiresDelegate() {
        let disks = [disk("A"), disk("B"), disk("C")]
        let vc = make(disks: disks)
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.loadViewIfNeeded()

        // Move "C" (row 2) to the top — proposedRow == 0 means "before
        // the first row." Target stays at 0 (upward drag).
        let didReorder = vc.performReorder(sourceRow: 2, proposedRow: 0)
        #expect(didReorder)
        #expect(vc.disks.map(\.label) == ["C", "A", "B"])
        #expect(delegate.reorderedOrderings.last?.map(\.label) == ["C", "A", "B"])
    }

    @Test("performReorder no-ops when source and target collapse to the same index")
    func reorderNoOp() {
        let disks = [disk("A"), disk("B"), disk("C")]
        let vc = make(disks: disks)
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.loadViewIfNeeded()

        // Drag row 1 to proposedRow 1 — target collapses to 1 == source.
        let droppedInPlace = vc.performReorder(sourceRow: 1, proposedRow: 1)
        #expect(!droppedInPlace)
        // Drag row 1 to proposedRow 2 — target == 2 - 1 == 1 == source.
        let droppedJustAfter = vc.performReorder(sourceRow: 1, proposedRow: 2)
        #expect(!droppedJustAfter)
        #expect(vc.disks.map(\.label) == ["A", "B", "C"])
        #expect(delegate.reorderedOrderings.isEmpty)
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
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.loadViewIfNeeded()
        guard let table = findFirst(NSTableView.self, in: vc.view) else {
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
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("test-drag"))
        pasteboard.clearContents()
        pasteboard.writeObjects([writer])

        let dragInfo = StubDraggingInfo(pasteboard: pasteboard)
        let accepted = vc.tableView(
            table, acceptDrop: dragInfo, row: 3, dropOperation: .above
        )
        #expect(accepted)
        #expect(vc.disks.map(\.label) == ["B", "C", "A"])
        #expect(delegate.reorderedOrderings.last?.map(\.label) == ["B", "C", "A"])
    }

    @Test("validateDrop returns .move only for .above")
    func validateDropOperation() {
        let vc = make(disks: [disk("A"), disk("B")])
        vc.loadViewIfNeeded()
        guard let table = findFirst(NSTableView.self, in: vc.view) else {
            Issue.record("Expected an NSTableView")
            return
        }
        let dragInfo = StubDraggingInfo(pasteboard: NSPasteboard(name: NSPasteboard.Name("test-validate")))
        #expect(
            vc.tableView(table, validateDrop: dragInfo, proposedRow: 1, proposedDropOperation: .above)
                == .move
        )
        #expect(
            vc.tableView(table, validateDrop: dragInfo, proposedRow: 1, proposedDropOperation: .on)
                == []
        )
    }

    @Test("Done button fires delegate's didDismiss")
    func doneFiresDelegate() {
        let vc = make(disks: [disk("A"), disk("B")])
        let delegate = MockDelegate()
        vc.delegate = delegate
        vc.loadViewIfNeeded()

        guard let done = findButton(titled: "Done", in: vc.view) else {
            Issue.record("Expected a Done button")
            return
        }
        done.performClick(nil)
        #expect(delegate.dismissCount == 1)
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
    private func make(disks: [StorageDisk]) -> StorageDiskReorderSheetContentViewController {
        let config = VMConfiguration(
            name: "Reorder Test VM",
            guestOS: .linux,
            bootMode: .efi
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL)
        return StorageDiskReorderSheetContentViewController(
            disks: disks,
            instance: instance,
            fileMonitor: AttachmentFileMonitor()
        )
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

    @MainActor
    private final class MockDelegate: StorageDiskReorderSheetContentViewControllerDelegate {
        var reorderedOrderings: [[StorageDisk]] = []
        var dismissCount = 0

        func storageDiskReorderSheet(
            _ vc: StorageDiskReorderSheetContentViewController,
            didReorderTo disks: [StorageDisk]
        ) {
            reorderedOrderings.append(disks)
        }

        func storageDiskReorderSheetDidDismiss(
            _ vc: StorageDiskReorderSheetContentViewController
        ) {
            dismissCount += 1
        }
    }

    @MainActor
    private func collectLabels(in view: NSView) -> [NSTextField] {
        var out: [NSTextField] = []
        if let field = view as? NSTextField { out.append(field) }
        for subview in view.subviews { out.append(contentsOf: collectLabels(in: subview)) }
        return out
    }

    @MainActor
    private func findButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        for subview in view.subviews {
            if let match = findButton(titled: title, in: subview) { return match }
        }
        return nil
    }

    @MainActor
    private func findFirst<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = findFirst(type, in: subview) { return match }
        }
        return nil
    }
}

/// Minimum-viable `NSDraggingInfo` stub for the pasteboard round-trip test.
///
/// AppKit's protocol surface is large, but `acceptDrop` /
/// `validateDrop` in our data source only touch `draggingPasteboard`;
/// every other member returns a neutral default. `@preconcurrency`
/// silences the actor-isolation mismatch between this main-actor-safe
/// stub (constructed and used from `@MainActor` test methods) and
/// `NSDraggingInfo`'s nonisolated protocol requirements.
private final class StubDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
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
