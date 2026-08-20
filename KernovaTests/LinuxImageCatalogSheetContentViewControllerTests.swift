import AppKit
import Foundation
import Testing

@testable import Kernova

@Suite("LinuxImageCatalogSheetContentViewController Tests", .admissionGated)
@MainActor
struct LinuxImageCatalogSheetContentViewControllerTests {
    private var entries: [LinuxImageCatalogEntry] {
        [
            makeLinuxCatalogEntry(
                id: "ubuntu-desktop-26.04", distribution: "Ubuntu Desktop", version: "26.04 LTS",
                isoPattern: "ubuntu-26.04*-desktop-arm64.iso"),
            makeLinuxCatalogEntry(
                id: "ubuntu-desktop-24.04", distribution: "Ubuntu Desktop", version: "24.04 LTS",
                isoPattern: "ubuntu-24.04*-desktop-arm64.iso"),
            makeLinuxCatalogEntry(id: "debian-13", distribution: "Debian", version: "13"),
        ]
    }

    private func makeSheet(
        entries: [LinuxImageCatalogEntry]? = nil,
        selectedID: String? = nil,
        downloads: [String] = [],
        onDownloadsRead: @escaping @MainActor () -> Void = {}
    ) -> LinuxImageCatalogSheetContentViewController {
        let vc = LinuxImageCatalogSheetContentViewController(
            entries: entries ?? self.entries,
            selectedID: selectedID,
            generatedAt: "2026-08-05",
            downloadsFilenames: {
                onDownloadsRead()
                return downloads
            }
        )
        vc.loadViewIfNeeded()
        return vc
    }

    /// The Downloads name a completed download leaves behind.
    ///
    /// Built the way the pipeline builds it — the resolved ISO URL through
    /// ``LinuxImageFilename`` — rather than spelled out, so a test never asserts
    /// against a discriminator it invented.
    private func downloadedName(
        of published: String, from entry: LinuxImageCatalogEntry
    ) -> String {
        LinuxImageFilename.destination(for: entry.directoryURL.appendingPathComponent(published))
    }

    /// The text the sheet renders in `column` for the row at `row`.
    private func cellText(
        _ vc: LinuxImageCatalogSheetContentViewController, row: Int, column identifier: String
    ) throws -> String {
        let table = try #require(firstSubview(NSTableView.self, in: vc.view))
        let column = try #require(
            table.tableColumns.first { $0.identifier.rawValue == identifier })
        let cell = vc.tableView(table, viewFor: column, row: row) as? NSTableCellView
        return try #require(cell?.textField?.stringValue)
    }

    @Test("Opens with the first distribution selected")
    func selectsFirstRowByDefault() {
        let vc = makeSheet()
        #expect(vc.selectedEntry?.id == "ubuntu-desktop-26.04")
    }

    @Test("A previous pick is preselected")
    func preselectsPreviousPick() {
        let vc = makeSheet(selectedID: "debian-13")
        #expect(vc.selectedEntry?.id == "debian-13")
    }

    @Test("Rows read in catalog order whatever order they arrive in")
    func sortsEntriesForDisplay() {
        let vc = makeSheet(entries: entries.reversed())
        #expect(
            vc.visibleEntries.map(\.id) == [
                "ubuntu-desktop-26.04", "ubuntu-desktop-24.04", "debian-13",
            ])
    }

    @Test("Search filters on distribution and version")
    func searchFiltersRows() {
        let vc = makeSheet()

        vc.applyFilter("debian")
        #expect(vc.visibleEntries.map(\.id) == ["debian-13"])

        vc.applyFilter("24.04")
        #expect(vc.visibleEntries.map(\.id) == ["ubuntu-desktop-24.04"])

        vc.applyFilter("")
        #expect(vc.visibleEntries.count == 3)
    }

    @Test("A selection surviving the filter is kept")
    func filterKeepsSurvivingSelection() {
        let vc = makeSheet(selectedID: "debian-13")
        vc.applyFilter("Debian")
        #expect(vc.selectedEntry?.id == "debian-13")
    }

    @Test("A filter that hides the selection clears it and disables Choose")
    func filterDroppingSelectionClearsIt() {
        let vc = makeSheet(selectedID: "debian-13")
        vc.applyFilter("Ubuntu")
        #expect(vc.selectedEntry == nil)
        #expect(findButton(titled: "Choose", in: vc.view)?.isEnabled == false)
    }

    @Test("Choosing reports the entry to the delegate")
    func choosingReportsToDelegate() {
        let vc = makeSheet(selectedID: "debian-13")
        let delegate = RecordingDelegate()
        vc.delegate = delegate

        findButton(titled: "Choose", in: vc.view)?.performClick(nil)

        #expect(delegate.chosen?.id == "debian-13")
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

    @Test("The Status column names only the images already in Downloads")
    func statusNamesDownloadedImages() throws {
        let debian = try #require(entries.last)
        let vc = makeSheet(
            downloads: [downloadedName(of: "debian-13.1.0-arm64-netinst.iso", from: debian)])

        #expect(try cellText(vc, row: 0, column: "status").isEmpty)
        #expect(try cellText(vc, row: 2, column: "status") == "In Downloads")
    }

    @Test("An ISO the user fetched themselves does not read as In Downloads")
    func statusIgnoresImagesThisAppDidNotDownload() throws {
        // Under the mirror's own name, so no download will ever find or adopt
        // it — saying it is there would promise a fast path that is not there.
        let vc = makeSheet(downloads: ["debian-13.1.0-arm64-netinst.iso"])

        #expect(try cellText(vc, row: 2, column: "status").isEmpty)
    }

    @Test("The same image fetched from another mirror does not read as In Downloads")
    func statusIgnoresTheSameImageFromAnotherURL() throws {
        // Same published filename, different directory, so the discriminator
        // differs and choosing this row downloads the whole ISO again.
        let elsewhere = makeLinuxCatalogEntry(
            directoryURLString: "https://mirror.example/debian-cd/current/arm64/iso-cd/")
        let vc = makeSheet(
            downloads: [downloadedName(of: "debian-13.1.0-arm64-netinst.iso", from: elsewhere)])

        #expect(try cellText(vc, row: 2, column: "status").isEmpty)
    }

    @Test("A pasted-URL download does not read as In Downloads for a catalog row")
    func statusIgnoresACustomURLDownload() throws {
        // The URL source names its destination the same way, so a link ending
        // in a catalog image's filename lands on a name whose stem matches that
        // row's glob — and whose discriminator says it came from elsewhere.
        let pasted = try #require(
            URL(string: "https://example.com/debian-13.1.0-arm64-netinst.iso"))
        let vc = makeSheet(downloads: [LinuxImageFilename.destination(for: pasted)])

        #expect(try cellText(vc, row: 2, column: "status").isEmpty)
    }

    @Test("A half-finished download does not read as In Downloads")
    func statusIgnoresPartialDownloads() throws {
        // The bundle replaces the destination's extension rather than following
        // it, so nothing about a partial download reads as an `.iso`.
        let ubuntu = try #require(entries.first)
        let complete = downloadedName(of: "ubuntu-26.04.1-desktop-arm64.iso", from: ubuntu)
        let partial = (complete as NSString).deletingPathExtension + ".kernovadownload"
        let vc = makeSheet(downloads: [partial])

        #expect(try cellText(vc, row: 0, column: "status").isEmpty)
    }

    @Test("Downloads is read once, however many rows render and filters run")
    func downloadsAreEnumeratedOncePerSheet() throws {
        var reads = 0
        let debian = try #require(entries.last)
        let vc = makeSheet(
            downloads: [downloadedName(of: "debian-13.1.0-arm64-netinst.iso", from: debian)],
            onDownloadsRead: { reads += 1 })

        for row in 0..<3 { _ = try cellText(vc, row: row, column: "status") }
        for term in ["u", "ub", "ubu"] {
            vc.applyFilter(term)
            _ = try cellText(vc, row: 0, column: "status")
        }

        #expect(reads == 1)
    }

    @Test("Sizes are stated as the approximations they are")
    func sizeColumnMarksTheSizeApproximate() throws {
        let vc = makeSheet(entries: [makeLinuxCatalogEntry(approxSizeBytes: 735_358_976)])
        #expect(try cellText(vc, row: 0, column: "size") == wizardApproximateSize(735_358_976))
        // Spelled out once, so the hedge in front of the number is pinned
        // rather than compared against itself.
        #expect(wizardApproximateSize(4_161_089_536) == "About 4.16 GB")
    }

    @Test("Distribution and version each get their own column")
    func distributionAndVersionColumns() throws {
        let vc = makeSheet()
        #expect(try cellText(vc, row: 0, column: "distribution") == "Ubuntu Desktop")
        #expect(try cellText(vc, row: 0, column: "version") == "26.04 LTS")
    }

    @Test("The footer dates the list and points at ISO File for anything else")
    func footerNamesTheSnapshotDate() {
        let vc = makeSheet()
        #expect(findLabel(containing: "August 2026", in: vc.view) != nil)
        #expect(findLabel(containing: "ISO File", in: vc.view) != nil)
    }

    // MARK: - Helpers

    private final class RecordingDelegate: LinuxImageCatalogSheetContentViewControllerDelegate {
        var chosen: LinuxImageCatalogEntry?
        var cancelCount = 0

        func linuxImageCatalogSheet(
            _ vc: LinuxImageCatalogSheetContentViewController,
            didChoose entry: LinuxImageCatalogEntry
        ) {
            chosen = entry
        }

        func linuxImageCatalogSheetDidCancel(
            _ vc: LinuxImageCatalogSheetContentViewController
        ) {
            cancelCount += 1
        }
    }
}
