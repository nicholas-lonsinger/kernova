import AppKit
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
