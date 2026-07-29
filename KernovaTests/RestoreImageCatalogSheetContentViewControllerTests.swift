import AppKit
import Foundation
import Testing

@testable import Kernova

@Suite("RestoreImageCatalogSheetContentViewController Tests")
@MainActor
struct RestoreImageCatalogSheetContentViewControllerTests {
    private func host(_ major: Int, _ minor: Int, _ patch: Int) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    private var entries: [RestoreImageCatalogEntry] {
        [
            makeCatalogEntry(version: "26.6", build: "25G72"),
            makeCatalogEntry(version: "15.6.1", build: "24G90"),
            makeCatalogEntry(version: "12.0.1", build: "21A559"),
        ]
    }

    private func makeSheet(
        selectedBuild: String? = nil,
        hostVersion: OperatingSystemVersion? = nil,
        downloadedBuilds: Set<String> = []
    ) -> RestoreImageCatalogSheetContentViewController {
        let vc = RestoreImageCatalogSheetContentViewController(
            entries: entries,
            selectedBuild: selectedBuild,
            generatedAt: "2026-07-28",
            hostVersion: hostVersion ?? host(26, 6, 0),
            isDownloaded: { downloadedBuilds.contains($0.build) }
        )
        vc.loadViewIfNeeded()
        return vc
    }

    @Test("Opens with the newest supported version selected")
    func selectsNewestSupportedByDefault() {
        let vc = makeSheet()
        #expect(vc.selectedEntry?.build == "25G72")
    }

    @Test("A previous pick is preselected")
    func preselectsPreviousPick() {
        let vc = makeSheet(selectedBuild: "24G90")
        #expect(vc.selectedEntry?.build == "24G90")
    }

    @Test("A guest newer than the host cannot be selected")
    func guestNewerThanHostIsUnselectable() throws {
        // Host below 26.6, so the newest entry is out of reach.
        let vc = makeSheet(hostVersion: host(15, 6, 1))
        #expect(vc.selectedEntry?.build == "24G90")

        let table = try #require(findTableView(in: vc.view))
        #expect(vc.tableView(table, shouldSelectRow: 0) == false)
        #expect(vc.tableView(table, shouldSelectRow: 1) == true)
    }

    @Test("Search filters on version and build")
    func searchFiltersRows() {
        let vc = makeSheet()

        vc.applyFilter("15.6")
        #expect(vc.visibleEntries.map(\.build) == ["24G90"])

        vc.applyFilter("21A559")
        #expect(vc.visibleEntries.map(\.build) == ["21A559"])

        vc.applyFilter("")
        #expect(vc.visibleEntries.count == 3)
    }

    @Test("A selection surviving the filter is kept")
    func filterKeepsSurvivingSelection() {
        let vc = makeSheet(selectedBuild: "24G90")
        vc.applyFilter("15")
        #expect(vc.selectedEntry?.build == "24G90")
    }

    @Test("A filter that hides the selection clears it")
    func filterDroppingSelectionClearsIt() {
        let vc = makeSheet(selectedBuild: "24G90")
        vc.applyFilter("26.6")
        #expect(vc.selectedEntry == nil)
    }

    @Test("Choosing reports the entry to the delegate")
    func choosingReportsToDelegate() {
        let vc = makeSheet(selectedBuild: "24G90")
        let delegate = RecordingDelegate()
        vc.delegate = delegate

        findButton(titled: "Choose", in: vc.view)?.performClick(nil)

        #expect(delegate.chosen?.build == "24G90")
        #expect(delegate.cancelCount == 0)
    }

    @Test("Cancel reports a dismissal and no choice")
    func cancelReportsToDelegate() {
        let vc = makeSheet()
        let delegate = RecordingDelegate()
        vc.delegate = delegate

        findButton(titled: "Cancel", in: vc.view)?.performClick(nil)

        #expect(delegate.chosen == nil)
        #expect(delegate.cancelCount == 1)
    }

    @Test("Choose is disabled while nothing selectable is selected")
    func chooseDisabledWithoutSelection() {
        let vc = makeSheet()
        vc.applyFilter("nothing matches this")
        #expect(findButton(titled: "Choose", in: vc.view)?.isEnabled == false)
    }

    @Test("The footer dates the list and points at Download Latest for newer releases")
    func footerNamesTheSnapshotDate() {
        let vc = makeSheet()
        #expect(findLabel(containing: "July 2026", in: vc.view) != nil)
        #expect(findLabel(containing: "Download Latest", in: vc.view) != nil)
    }

    // MARK: - Helpers

    private final class RecordingDelegate: RestoreImageCatalogSheetContentViewControllerDelegate {
        var chosen: RestoreImageCatalogEntry?
        var cancelCount = 0

        func restoreImageCatalogSheet(
            _ vc: RestoreImageCatalogSheetContentViewController,
            didChoose entry: RestoreImageCatalogEntry
        ) {
            chosen = entry
        }

        func restoreImageCatalogSheetDidCancel(
            _ vc: RestoreImageCatalogSheetContentViewController
        ) {
            cancelCount += 1
        }
    }

    private func findTableView(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews {
            if let found = findTableView(in: subview) { return found }
        }
        return nil
    }

    private func findLabel(containing text: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.stringValue.contains(text) { return field }
        for subview in view.subviews {
            if let found = findLabel(containing: text, in: subview) { return found }
        }
        return nil
    }
}
