import AppKit
import KernovaAgentCore
import KernovaAgentHost
import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

/// Inline rename in the AppKit sidebar.
@Suite("Sidebar Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct SidebarViewControllerTests {
    /// Shared by the view model (selection/order) and the sidebar's own use of
    /// `AppPreferences` (expanded sections + the advanced-options toggle).
    ///
    /// Fresh per test (the struct is re-instantiated), so each starts clean.
    private let preferences: AppPreferences

    init() {
        self.preferences = makeTestPreferences()
    }

    // MARK: - Row busy state

    /// The text of every label on screen, in document order: none under a hidden view.
    private func visibleTexts(in view: NSView) -> [String] {
        guard !view.isHidden else { return [] }
        var texts: [String] = []
        if let field = view as? NSTextField, !field.isEditable { texts.append(field.stringValue) }
        for subview in view.subviews { texts += visibleTexts(in: subview) }
        return texts
    }

    // MARK: - Inline rename

    /// The row's name label, which is also the box a rename opens.
    private func nameLabel(in cell: SidebarVMRowCellView) throws -> InlineEditableLabel {
        try #require(firstSubview(InlineEditableLabel.self, in: cell))
    }

    private func makeRenamingRow(
        instance: VMInstance, onCommitRename: @escaping (String) -> Void = { _ in }
    ) -> SidebarVMRowCellView {
        let cell = SidebarVMRowCellView()
        cell.configure(
            instance: instance,
            isRenaming: true,
            installPromptDisabled: { false },
            agentDiskControl: { nil },
            agentNudgeDismissible: { false },
            isBusy: { false },
            detail: { nil },
            tags: { [] },
            onCommitRename: onCommitRename,
            onCancelRename: {},
            onAgentDiskControl: {},
            onDismissAgentNudge: {})
        return cell
    }

    /// A recycled row carries typed text belonging to the VM it used to show,
    /// so the reuse teardown must drop it rather than commit it.
    @Test("Recycling a row mid-rename commits nothing")
    func recyclingARenamingRowCommitsNothing() throws {
        let instance = VMInstanceFixture.make()
        var commits = 0
        let cell = makeRenamingRow(instance: instance) { _ in commits += 1 }
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = cell
        let label = try nameLabel(in: cell)
        label.currentEditor()?.string = "Half-typed"
        label.stringValue = "Half-typed"

        cell.prepareForReuse()

        #expect(commits == 0)
        #expect(isRenaming(cell) == false)
        #expect(!label.isEditable)
    }
}

/// A drag session the test drives through the outline view's own
/// `NSDraggingDestination` methods, from a fixed point over it.
@MainActor
final class FakeDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingDestinationWindow: NSWindow?
    let draggingSourceOperationMask: NSDragOperation = .move
    let draggingLocation: NSPoint
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(window: NSWindow?, location: NSPoint, pasteboard: NSPasteboard, source: Any?) {
        draggingDestinationWindow = window
        draggingLocation = location
        draggingPasteboard = pasteboard
        draggingSource = source
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}
