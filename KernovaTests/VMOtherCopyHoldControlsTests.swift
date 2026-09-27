import AppKit
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Every control that writes a VM's state, swept across every settings panel
/// on a VM another copy of Kernova holds: each one dims through the catalog,
/// and the title of the row holding it grays with it.
///
/// A sweep rather than a list, so a control added without asking the catalog
/// fails it. What it passes over is named below: the controls that only read.
@Suite("Another copy's hold dims every edit control", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct VMOtherCopyHoldControlsTests {
    private let preferences = makeTestPreferences()

    /// The actions of the controls in these panels that write nothing: the
    /// snapshot row's ••• button opens the menu ``snapshotMenuWritesNothing()``
    /// sweeps.
    private static let readingActions: Set<String> = ["moreTapped:"]

    /// Whether `control` belongs to an affordance that only reads: an info
    /// popover's button, or a row icon opening Get Info.
    private static func isInReadingAffordance(_ control: NSControl) -> Bool {
        sequence(first: control as NSView, next: \.superview).contains {
            $0 is InfoButtonView || $0 is AttachmentIconButton
        }
    }

    /// The pane over a VM holding one snapshot, opened the way the detail
    /// router opens it — read-only exactly where the catalog refuses
    /// configuration edits — with another copy holding the VM when `held`.
    private func makePane(
        guestOS: VMGuestOS, category: VMSettingsCategory, held: Bool
    ) -> (pane: VMSettingsViewController, panel: NSView, instance: VMInstance, snapshot: VMSnapshot)? {
        let storage = MockVMStorageService()
        let viewModel = makeSettingsViewModel(preferences: preferences, storage: storage)
        let snapshot = VMSnapshot(name: "Only", notes: "A note", kind: .cold, macAddress: nil)
        let instance = viewModel.library.registerFixture(
            guestOS: guestOS, snapshots: VMSnapshotManifest(snapshots: [snapshot]))
        if held {
            storage.files.holdElsewhere(instance.bundleURL)
            viewModel.library.refreshFromOtherCopies()
            #expect(instance.heldByAnotherCopy)
        }
        let pane = makeSettingsPane(
            instance: instance, viewModel: viewModel,
            isReadOnly: !viewModel.capabilities.isAvailable(.editConfiguration, on: instance))
        pane.loadViewIfNeeded()
        pane.viewDidAppear()
        pane.showCategory(category)
        guard let panel = pane.panelForTesting(category) else {
            Issue.record("No \(category) panel")
            return nil
        }
        return (pane, panel, instance, snapshot)
    }

    /// Every control on screen in `panel` that writes: whatever is not a plain
    /// label or image, and not one of the reading affordances.
    private func writingControls(in panel: NSView) -> [NSControl] {
        allSubviews(NSControl.self, in: panel) { control in
            guard isVisible(control, within: panel) else { return false }
            if let field = control as? NSTextField, !(field is InlineEditableLabel), !field.isEditable {
                return false
            }
            if let image = control as? NSImageView, !image.isEditable { return false }
            let action = control.action.map(NSStringFromSelector) ?? ""
            return !Self.readingActions.contains(action) && !Self.isInReadingAffordance(control)
        }
    }

    /// Whether `control` takes input: an inline label is armed, anything else
    /// is enabled.
    private func takesInput(_ control: NSControl) -> Bool {
        if let label = control as? InlineEditableLabel { return label.controlsEnabled }
        return control.isEnabled
    }

    private func describe(_ control: NSControl) -> String {
        let action = control.action.map(NSStringFromSelector) ?? "no action"
        let row = sequence(first: control as NSView, next: \.superview).lazy
            .compactMap { $0 as? GroupedFormControlRow }.first
        return "\(type(of: control)) \(action) \(row?.titleLabel.stringValue ?? "")"
    }

    /// The titled row holding `control` within `panel`, if any.
    private func titledRow(of control: NSControl, within panel: NSView) -> GroupedFormControlRow? {
        sequence(first: control as NSView, next: \.superview).prefix { $0 !== panel }
            .lazy.compactMap { $0 as? GroupedFormControlRow }.first
    }

    /// Whether `control` has to sit in a ``GroupedFormControlRow`` for its
    /// title to dim with it: everything but a button naming itself, or a
    /// control on a list row, which carries its own title line.
    private static func needsRowTitle(_ control: NSControl) -> Bool {
        let onListRow = sequence(first: control as NSView, next: \.superview).contains {
            $0 is AttachmentRowView || $0 is SnapshotRowView
        }
        if onListRow { return false }
        if let button = control as? NSButton, !(button is NSPopUpButton), !button.title.isEmpty {
            return false
        }
        return true
    }

    nonisolated private static let sweeps: [(VMGuestOS, VMSettingsCategory)] = [
        VMGuestOS.macOS, .linux,
    ].flatMap { guestOS in
        VMSettingsCategory.allCases.map { (guestOS, $0) }
    }

    @Test("Every edit control in the panel dims, with its row's title", arguments: sweeps)
    func everyEditControlDims(guestOS: VMGuestOS, category: VMSettingsCategory) throws {
        let free = try #require(makePane(guestOS: guestOS, category: category, held: false))
        #expect(
            writingControls(in: free.panel).contains(where: takesInput),
            "\(guestOS) \(category): the sweep found nothing a free VM takes")

        let held = try #require(makePane(guestOS: guestOS, category: category, held: true))
        let controls = writingControls(in: held.panel)
        #expect(!controls.isEmpty)
        for control in controls {
            #expect(!takesInput(control), "\(guestOS) \(category): \(describe(control)) takes input")
            guard let row = titledRow(of: control, within: held.panel) else {
                #expect(
                    !Self.needsRowTitle(control),
                    "\(guestOS) \(category): \(describe(control)) sits in no titled row")
                continue
            }
            #expect(
                row.titleLabel.textColor == .disabledControlTextColor,
                "\(guestOS) \(category): \(describe(control))'s row title is lit")
        }
    }

    @Test("The snapshot row's menu offers nothing that writes; Get Info still reads")
    func snapshotMenuWritesNothing() throws {
        let held = try #require(makePane(guestOS: .macOS, category: .snapshots, held: true))
        let section = try #require(firstSubview(SnapshotSectionView.self, in: held.panel))
        let menu = try #require(section.makeRowMenu(forRowWith: held.snapshot.id))

        let reading: Set<String> = ["Get Info"]
        let items = menu.items.filter { !$0.isSeparatorItem }
        #expect(items.count > reading.count)
        for item in items {
            #expect(item.isEnabled == reading.contains(item.title), "\(item.title)")
        }
    }
}
