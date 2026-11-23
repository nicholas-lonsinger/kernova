import AppKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

@Suite("IPSWSelectionContentViewController Tests", .caseScoped)
@MainActor
struct IPSWSelectionContentViewControllerTests {
    private let scratch = TestScratchDirectory(prefix: "IPSWSelectionContentViewControllerTests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    @Test("Overwrite warning shows when a file exists; Use Existing switches to local file")
    func overwriteUseExisting() async throws {
        let path = makeIPSW()

        let inspector = MockLocalRestoreImageInspector()
        inspector.inspectResult = InspectedRestoreImage(
            version: "26.5.2", build: "25F84", isSupportedOnThisHost: true, sizeBytes: 15_500_000_000)
        let vm = try await makeLookedUpWizard(localImageInspector: inspector)
        #expect(vm.shouldShowOverwriteWarning == true)

        let vc = IPSWSelectionContentViewController(creationVM: vm)
        vc.loadViewIfNeeded()
        #expect(findButton(titled: "Use Existing File", in: vc.view) != nil)

        findButton(titled: "Use Existing File", in: vc.view)?.performClick(nil)
        try await vc.adoptTaskForTesting?.joined()

        #expect(
            vm.ipswSelection
                == .localFile(
                    LocalRestoreImage(
                        path: path, bookmark: nil, inspection: .usable(inspector.inspectResult))))
        // The badge upgrades to the file's own metadata, not just its path.
        #expect(
            findLabel(
                containing: "macOS 26.5.2  ·  Build 25F84  ·  \(DataFormatters.formatBytes(15_500_000_000))",
                in: vc.view) != nil)
    }

    // MARK: - Helpers

    /// A wizard on Download Latest whose lookup found `makeLatestImage()`, so its
    /// destination is that image's file in this test's Downloads folder — the
    /// one ``makeIPSW(at:)`` writes by default.
    private func makeLookedUpWizard(
        localImageInspector: any LocalRestoreImageInspecting = MockLocalRestoreImageInspector()
    ) async throws -> VMCreationViewModel {
        let vm = VMCreationViewModel.overEngine(
            probeService: MockRestoreImageProbeService(), localImageInspector: localImageInspector,
            ipswService: MockIPSWService(), downloadsDirectory: scratch.url)
        try await vm.loadLatestImageDetails()?.joined()
        return vm
    }

    /// Puts an empty IPSW at `path`, the looked-up image's destination in this
    /// test's Downloads folder unless named.
    @discardableResult
    private func makeIPSW(at path: String? = nil) -> String {
        let path =
            path
            ?? scratch.url.appendingPathComponent(makeLatestImage().suggestedFilename)
            .path(percentEncoded: false)
        FileManager.default.createFile(atPath: path, contents: Data())
        return path
    }
}
