import AppKit
import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("LinuxImageURLSheetContentViewController Tests")
@MainActor
struct LinuxImageURLSheetContentViewControllerTests {
    private static let digest =
        "9866e6b13a12f8dfdda382d414ccd90da60b898beeaa80cd87e55b25fdc11a06"
    private static let isoURL = "https://mirror.example/alpine-3.22-aarch64.iso"

    private func makeSheet(
        resolve: any LinuxImageResolving,
        initialURL: String? = nil,
        initialChecksum: String? = nil
    ) -> LinuxImageURLSheetContentViewController {
        let vc = LinuxImageURLSheetContentViewController(
            resolveService: resolve, initialURL: initialURL, initialChecksum: initialChecksum)
        vc.loadViewIfNeeded()
        return vc
    }

    /// Runs Check and awaits the production task rather than polling for it.
    private func check(_ vc: LinuxImageURLSheetContentViewController) async {
        findButton(titled: "Check", in: vc.view)?.performClick(nil)
        await vc.checkTaskForTesting?.value
    }

    /// The URL field, then the checksum field, in the order they are laid out.
    private func editableFields(in vc: LinuxImageURLSheetContentViewController) -> [NSTextField] {
        allSubviews(NSTextField.self, in: vc.view) { $0.isEditable }
    }

    @Test("Use is disabled until a URL has been checked")
    func useDisabledBeforeCheck() {
        let vc = makeSheet(resolve: MockLinuxImageResolveService())
        #expect(findButton(titled: "Use", in: vc.view)?.isEnabled == false)
        #expect(vc.checkedImage == nil)
    }

    @Test("Check with an empty URL does nothing")
    func checkIgnoresEmptyField() async {
        let resolve = MockLinuxImageResolveService()
        let vc = makeSheet(resolve: resolve)
        await check(vc)
        #expect(resolve.resolveCallCount == 0)
    }

    @Test("A successful check enables Use and records the image")
    func successfulCheckEnablesUse() async {
        let resolve = MockLinuxImageResolveService()
        resolve.resolveResult = makeResolvedLinuxImage(
            isoURLString: Self.isoURL, filename: "alpine-3.22-aarch64.iso", sha256: Self.digest)
        let vc = makeSheet(
            resolve: resolve, initialURL: Self.isoURL, initialChecksum: Self.digest)

        await check(vc)

        #expect(resolve.resolveCallCount == 1)
        #expect(resolve.lastResolvedCustomImage?.sha256 == Self.digest)
        #expect(vc.checkedImage?.url.absoluteString == Self.isoURL)
        #expect(vc.checkedImage?.sha256 == Self.digest)
        #expect(vc.checkedSizeBytes == resolve.resolveResult.sizeBytes)
        #expect(findButton(titled: "Use", in: vc.view)?.isEnabled == true)
        #expect(findLabel(containing: "alpine-3.22-aarch64.iso", in: vc.view) != nil)
        #expect(findLabel(containing: "won't be verified", in: vc.view) == nil)
    }

    @Test("A check with no checksum says the download won't be verified")
    func unverifiedCheckSaysSo() async {
        let resolve = MockLinuxImageResolveService()
        resolve.resolveResult = makeResolvedLinuxImage(
            isoURLString: Self.isoURL, filename: "alpine-3.22-aarch64.iso", sha256: nil)
        let vc = makeSheet(resolve: resolve, initialURL: Self.isoURL)

        await check(vc)

        #expect(resolve.lastResolvedCustomImage?.sha256 == nil)
        #expect(vc.checkedImage?.sha256 == nil)
        // Nothing is blocked — the pick is honest about what it is.
        #expect(findButton(titled: "Use", in: vc.view)?.isEnabled == true)
        #expect(
            findLabel(
                containing: "This download won't be verified. Choose a host you trust.",
                in: vc.view) != nil)
    }

    @Test("A malformed checksum fails at entry, before anything is contacted")
    func malformedChecksumNeverResolves() async {
        let resolve = MockLinuxImageResolveService()
        let vc = makeSheet(resolve: resolve, initialURL: Self.isoURL, initialChecksum: "deadbeef")

        await check(vc)

        #expect(resolve.resolveCallCount == 0)
        #expect(vc.checkedImage == nil)
        #expect(findLabel(containing: "isn't a SHA-256 checksum", in: vc.view) != nil)
        #expect(findButton(titled: "Use", in: vc.view)?.isEnabled == false)
    }

    @Test("An http link is refused with or without a checksum, before anything is contacted")
    func httpIsRefused() async {
        let httpURL = "http://mirror.example/alpine-3.22-aarch64.iso"
        let resolve = MockLinuxImageResolveService()

        for checksum in ["", Self.digest] {
            let vc = makeSheet(resolve: resolve, initialURL: httpURL, initialChecksum: checksum)
            await check(vc)

            #expect(vc.checkedImage == nil)
            #expect(findLabel(containing: "must be served over HTTPS", in: vc.view) != nil)
        }
        #expect(resolve.resolveCallCount == 0)
    }

    @Test("A malformed URL is refused without reaching the resolve")
    func malformedURLNeverResolves() async {
        let resolve = MockLinuxImageResolveService()
        let vc = makeSheet(resolve: resolve, initialURL: "not a url")

        await check(vc)

        #expect(resolve.resolveCallCount == 0)
        #expect(vc.checkedImage == nil)
        #expect(findLabel(containing: "isn't a valid URL", in: vc.view) != nil)
    }

    @Test("A link that doesn't name an .iso is refused without reaching the resolve")
    func nonISOLinkNeverResolves() async {
        let resolve = MockLinuxImageResolveService()
        let vc = makeSheet(resolve: resolve, initialURL: "https://mirror.example/downloads/")

        await check(vc)

        #expect(resolve.resolveCallCount == 0)
        #expect(findLabel(containing: "doesn't end in the name of an .iso file", in: vc.view) != nil)
    }

    @Test("A failed check leaves Use disabled and shows the reason")
    func failedCheckKeepsUseDisabled() async {
        let resolve = MockLinuxImageResolveService()
        resolve.resolveError = LinuxImageURLError.unreachable(statusCode: 404)
        let vc = makeSheet(resolve: resolve, initialURL: Self.isoURL)

        await check(vc)

        #expect(vc.checkedImage == nil)
        #expect(findButton(titled: "Use", in: vc.view)?.isEnabled == false)
        #expect(findLabel(containing: "Nothing is hosted at that URL", in: vc.view) != nil)
    }

    @Test("Choosing hands the checked image to the delegate")
    func chooseReportsToDelegate() async {
        let resolve = MockLinuxImageResolveService()
        let vc = makeSheet(resolve: resolve, initialURL: Self.isoURL, initialChecksum: Self.digest)
        let delegate = RecordingDelegate()
        vc.delegate = delegate

        await check(vc)
        findButton(titled: "Use", in: vc.view)?.performClick(nil)

        #expect(delegate.chosen?.url.absoluteString == Self.isoURL)
        #expect(delegate.chosen?.sha256 == Self.digest)
        #expect(delegate.chosenSizeBytes == resolve.resolveResult.sizeBytes)
        #expect(delegate.cancelCount == 0)
    }

    @Test("Cancel reports a dismissal and no choice")
    func cancelReportsToDelegate() {
        let vc = makeSheet(resolve: MockLinuxImageResolveService())
        let delegate = RecordingDelegate()
        vc.delegate = delegate

        findButton(titled: "Cancel", in: vc.view)?.performClick(nil)

        #expect(delegate.chosen == nil)
        #expect(delegate.cancelCount == 1)
    }

    @Test("Editing the checksum invalidates the previous verdict")
    func editingTheChecksumClearsTheVerdict() async throws {
        let vc = makeSheet(
            resolve: MockLinuxImageResolveService(), initialURL: Self.isoURL,
            initialChecksum: Self.digest)
        await check(vc)
        #expect(vc.checkedImage != nil)

        // A verdict paired with one digest must not survive onto another.
        let checksumField = try #require(editableFields(in: vc).last)
        checksumField.stringValue = ""
        vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))

        #expect(vc.checkedImage == nil)
        #expect(findButton(titled: "Use", in: vc.view)?.isEnabled == false)
    }

    @Test("Editing the URL invalidates a check still in flight")
    func editingCancelsTheInFlightCheck() async throws {
        let resolve = SuspendingResolveService()
        let vc = makeSheet(resolve: resolve, initialURL: Self.isoURL)

        findButton(titled: "Check", in: vc.view)?.performClick(nil)
        let inFlight = try #require(vc.checkTaskForTesting)
        try await resolve.waitUntilResolving()

        let urlField = try #require(editableFields(in: vc).first)
        urlField.stringValue = "https://mirror.example/other-3.22-aarch64.iso"
        vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        resolve.release()
        await inFlight.value

        // The first URL's answer must not become the second's verdict.
        #expect(vc.checkedImage == nil)
        #expect(findButton(titled: "Use", in: vc.view)?.isEnabled == false)
        // Back to idle, so the edited URL can be checked in turn.
        #expect(findLabel(containing: "Reading the file's size", in: vc.view) == nil)
        #expect(findButton(titled: "Check", in: vc.view)?.isEnabled == true)
    }

    // MARK: - Helpers

    private final class RecordingDelegate: LinuxImageURLSheetContentViewControllerDelegate {
        var chosen: CustomLinuxImage?
        var chosenSizeBytes: UInt64?
        var cancelCount = 0

        func linuxImageURLSheet(
            _ vc: LinuxImageURLSheetContentViewController,
            didChoose image: CustomLinuxImage,
            sizeBytes: UInt64
        ) {
            chosen = image
            chosenSizeBytes = sizeBytes
        }

        func linuxImageURLSheetDidCancel(_ vc: LinuxImageURLSheetContentViewController) {
            cancelCount += 1
        }
    }
}

/// Resolve stand-in that stays inside the pasted-URL overload until the test
/// releases it, the way the real one stays busy across a round trip.
private final class SuspendingResolveService: LinuxImageResolving, @unchecked Sendable {
    private let result = makeResolvedLinuxImage()
    private let gate = AsyncGate()
    private let lock = NSLock()
    private var isResolving = false
    private var isReleased = false

    /// Not exercised here: this sheet only ever checks a pasted URL.
    func resolve(_ entry: LinuxImageCatalogEntry) async throws -> ResolvedLinuxImage {
        result
    }

    func resolve(_ image: CustomLinuxImage) async throws -> ResolvedLinuxImage {
        lock.withLock { self.isResolving = true }
        gate.notify()
        try? await gate.wait(until: { self.lock.withLock { self.isReleased } })
        return result
    }

    /// Suspends until a resolve is in flight.
    func waitUntilResolving() async throws {
        try await gate.wait(until: { self.lock.withLock { self.isResolving } })
    }

    /// Lets the in-flight resolve finish.
    func release() {
        lock.withLock { self.isReleased = true }
        gate.notify()
    }
}
