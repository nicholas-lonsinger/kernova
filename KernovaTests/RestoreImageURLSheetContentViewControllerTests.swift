import AppKit
import Foundation
import Testing

@testable import KernovaCore
@testable import KernovaUI

@Suite("RestoreImageURLSheetContentViewController Tests", .caseScoped)
@MainActor
struct RestoreImageURLSheetContentViewControllerTests {
    private func makeSheet(
        probe: any RestoreImageProbing,
        initialURL: String? = nil,
        hostMajor: Int = 26
    ) -> RestoreImageURLSheetContentViewController {
        let vc = RestoreImageURLSheetContentViewController(
            probeService: probe,
            initialURL: initialURL,
            hostVersion: OperatingSystemVersion(
                majorVersion: hostMajor, minorVersion: 0, patchVersion: 0)
        )
        vc.loadViewIfNeeded()
        return vc
    }

    /// Runs Check and awaits the production task rather than polling for it.
    private func check(_ vc: RestoreImageURLSheetContentViewController) async {
        findButton(titled: "Check", in: vc.view)?.performClick(nil)
        await vc.probeTaskForTesting?.value
    }

    @Test("Use is disabled until a URL has been checked")
    func useDisabledBeforeCheck() {
        let vc = makeSheet(probe: MockRestoreImageProbeService())
        #expect(findButton(titled: "Use", in: vc.view)?.isEnabled == false)
        #expect(vc.checkedImage == nil)
    }

    @Test("Check with an empty field does nothing")
    func checkIgnoresEmptyField() async {
        let probe = MockRestoreImageProbeService()
        let vc = makeSheet(probe: probe)
        await check(vc)
        #expect(probe.probeCallCount == 0)
    }

    @Test("A successful check enables Use and records the image")
    func successfulCheckEnablesUse() async {
        let probe = MockRestoreImageProbeService()
        let vc = makeSheet(
            probe: probe,
            initialURL: "https://updates.cdn-apple.com/x/UniversalMac_15.6.1_24G90_Restore.ipsw")

        await check(vc)

        #expect(probe.probeCallCount == 1)
        #expect(vc.checkedImage == probe.probeResult)
        #expect(findButton(titled: "Use", in: vc.view)?.isEnabled == true)
    }

    @Test("A failed check leaves Use disabled and shows the reason")
    func failedCheckKeepsUseDisabled() async {
        let probe = MockRestoreImageProbeService()
        probe.probeError = RestoreImageProbeError.notAVirtualMachineImage
        let vc = makeSheet(probe: probe, initialURL: "https://example.com/R.ipsw")

        await check(vc)

        #expect(vc.checkedImage == nil)
        #expect(findButton(titled: "Use", in: vc.view)?.isEnabled == false)
        #expect(findLabel(containing: "can't run as a virtual machine", in: vc.view) != nil)
    }

    @Test("A malformed URL is refused without reaching the probe")
    func malformedURLNeverProbes() async {
        let probe = MockRestoreImageProbeService()
        let vc = makeSheet(probe: probe, initialURL: "not a url")

        await check(vc)

        #expect(probe.probeCallCount == 0)
        #expect(vc.checkedImage == nil)
        #expect(findLabel(containing: "isn't a valid URL", in: vc.view) != nil)
    }

    @Test("Choosing hands the checked image to onChoose")
    func chooseReports() async {
        let probe = MockRestoreImageProbeService()
        let vc = makeSheet(probe: probe, initialURL: "https://example.com/R.ipsw")
        var chosen: ProbedRestoreImage?
        var cancelCount = 0
        vc.onChoose = { chosen = $0 }
        vc.onCancel = { cancelCount += 1 }

        await check(vc)
        findButton(titled: "Use", in: vc.view)?.performClick(nil)

        #expect(chosen == probe.probeResult)
        #expect(cancelCount == 0)
    }

    @Test("Cancel reports a dismissal and no choice")
    func cancelReports() {
        let vc = makeSheet(probe: MockRestoreImageProbeService())
        var chosen: ProbedRestoreImage?
        var cancelCount = 0
        vc.onChoose = { chosen = $0 }
        vc.onCancel = { cancelCount += 1 }

        findButton(titled: "Cancel", in: vc.view)?.performClick(nil)

        #expect(chosen == nil)
        #expect(cancelCount == 1)
    }

    @Test("An image newer than the host warns without blocking Use")
    func tooNewImageWarnsButDoesNotBlock() async {
        let probe = MockRestoreImageProbeService()
        probe.probeResult = makeProbedImage(version: "27.0", build: "26A100")
        let vc = makeSheet(
            probe: probe, initialURL: "https://example.com/R.ipsw", hostMajor: 26)

        await check(vc)

        // The version came from the filename, so it is a hint, not a verdict.
        #expect(vc.checkedImage != nil)
        #expect(findButton(titled: "Use", in: vc.view)?.isEnabled == true)
        #expect(findLabel(containing: "newer than this Mac", in: vc.view) != nil)
    }

    @Test("An unrecognized filename leads the badge with the unknown version")
    func unknownVersionIsCalledOut() async {
        let probe = MockRestoreImageProbeService()
        probe.probeResult = makeProbedImage(
            urlString: "https://example.com/image.ipsw", version: nil, build: nil)
        let vc = makeSheet(probe: probe, initialURL: "https://example.com/image.ipsw")

        await check(vc)

        #expect(vc.checkedImage != nil)
        #expect(
            findLabel(
                withText: "Unrecognized version · \(DataFormatters.formatBytes(probe.probeResult.sizeBytes)) "
                    + "· Installs in a virtual machine",
                in: vc.view) != nil)
    }

    @Test("A recognized filename leads the badge with its version")
    func recognizedVersionLeadsBadge() async {
        let probe = MockRestoreImageProbeService()
        probe.probeResult = makeProbedImage(version: "26.0", build: "25A354")
        let vc = makeSheet(
            probe: probe, initialURL: "https://example.com/R.ipsw", hostMajor: 26)

        await check(vc)

        #expect(
            findLabel(
                withText: "macOS 26.0 (25A354) · \(DataFormatters.formatBytes(probe.probeResult.sizeBytes)) "
                    + "· Installs in a virtual machine",
                in: vc.view) != nil)
    }

    @Test("Editing the URL invalidates the previous verdict")
    func editingClearsTheVerdict() async throws {
        let probe = MockRestoreImageProbeService()
        let vc = makeSheet(probe: probe, initialURL: "https://example.com/R.ipsw")
        await check(vc)
        #expect(vc.checkedImage != nil)

        let field = try #require(findEditableField(in: vc.view))
        field.stringValue = "https://example.com/other.ipsw"
        vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))

        #expect(vc.checkedImage == nil)
        #expect(findButton(titled: "Use", in: vc.view)?.isEnabled == false)
    }

    @Test("Editing the URL invalidates a probe still in flight")
    func editingCancelsTheInFlightProbe() async throws {
        let probe = SuspendingProbeService()
        let vc = makeSheet(probe: probe, initialURL: "https://example.com/A.ipsw")

        findButton(titled: "Check", in: vc.view)?.performClick(nil)
        let inFlight = try #require(vc.probeTaskForTesting)
        try await probe.waitUntilProbing()

        let field = try #require(findEditableField(in: vc.view))
        field.stringValue = "https://example.com/B.ipsw"
        vc.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        probe.release()
        await inFlight.value

        // A's answer must not become B's verdict.
        #expect(vc.checkedImage == nil)
        #expect(findButton(titled: "Use", in: vc.view)?.isEnabled == false)
        #expect(findLabel(containing: "Installs in a virtual machine", in: vc.view) == nil)
        // Back to idle, so the edited URL can be checked in turn.
        #expect(findLabel(containing: "Reading the image directory", in: vc.view) == nil)
        #expect(findButton(titled: "Check", in: vc.view)?.isEnabled == true)
    }
}

/// Probe stand-in that stays inside `probe` until the test releases it, the way
/// the real one stays busy across several round trips.
private final class SuspendingProbeService: RestoreImageProbing, @unchecked Sendable {
    private let probeResult = makeProbedImage()
    private let gate = AsyncGate()
    private let lock = NSLock()
    private var isProbing = false
    private var isReleased = false

    func probe(_ url: URL) async throws -> ProbedRestoreImage {
        lock.withLock { self.isProbing = true }
        gate.notify()
        try? await gate.wait(until: { self.lock.withLock { self.isReleased } })
        return probeResult
    }

    /// Not exercised here: the sheet checks a URL, it never asks for a size alone.
    func size(of url: URL) async throws -> UInt64 {
        probeResult.sizeBytes
    }

    /// Suspends until `probe` is in flight.
    func waitUntilProbing() async throws {
        try await gate.wait(until: { self.lock.withLock { self.isProbing } })
    }

    /// Lets the in-flight probe finish.
    func release() {
        lock.withLock { self.isReleased = true }
        gate.notify()
    }
}
