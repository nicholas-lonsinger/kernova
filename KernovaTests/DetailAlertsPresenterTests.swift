import Foundation
import Testing

@testable import Kernova

/// Covers the delete-sheet de-dup invariant and cancellable resolution Task
/// added for issue #362.
///
/// The presenter never has `start(window:)` called, so `window == nil` and
/// `runNext()` always bails — enqueued `showDeleteSheet` closures simply
/// accumulate in `pending`. The de-dup is therefore observable purely as
/// `pendingCountForTesting`, with no real sheet (which would need a live window
/// and run loop, unavailable headless — same constraint `SheetPresenterTests`
/// documents).
///
/// Determinism: every test holds the main actor synchronously from
/// `presentDeleteSheet` through the follow-up call/`stop()`, so the off-main
/// resolution Task can't run until the test `await`s the captured handle's
/// `.value`. This is event-driven — no polling or `waitUntil`.
@Suite("DetailAlertsPresenter Tests", .serialized)
@MainActor
struct DetailAlertsPresenterTests {
    private func makeViewModel() -> VMLibraryViewModel {
        VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService()
        )
    }

    /// An attachment-free Linux VM: `externalAttachmentsResolvingExistence`
    /// returns `[]` without the off-main probe, so resolution finishes fast.
    private func makeInstance(name: String = "Test VM") -> VMInstance {
        let config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    @Test("⌘⌫ then ⌥⌘⌫ on one VM yields a single sheet upgraded to Immediate")
    func dedupSameVMUpgradesMode() async {
        let presenter = DetailAlertsPresenter(viewModel: makeViewModel())
        let vmA = makeInstance(name: "A")

        // ⌘⌫ (Trash) starts the in-flight delete; ⌥⌘⌫ (Immediate) fires before
        // the first resolves and folds in — one sheet, latest gesture wins.
        presenter.presentDeleteSheet(for: vmA, permanently: false)
        let task = presenter.deleteResolutionTaskForTesting
        presenter.presentDeleteSheet(for: vmA, permanently: true)
        await task?.value

        #expect(presenter.pendingCountForTesting == 1)
        #expect(presenter.pendingDeleteInstanceIDForTesting == vmA.id)
        // The surviving sheet carries the later, stronger disposition — the
        // immediate request is not silently downgraded to Trash.
        #expect(presenter.pendingDeletePermanentlyForTesting == true)
    }

    @Test("Only one delete sheet is in flight, even for a different VM")
    func singleInFlightDifferentVM() async {
        let presenter = DetailAlertsPresenter(viewModel: makeViewModel())
        let vmA = makeInstance(name: "A")
        let vmB = makeInstance(name: "B")

        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionTaskForTesting?.value
        // vmA's sheet is queued (no window → not drained); a different-VM request
        // while one is in flight is dropped in favor of the first (#364).
        presenter.presentDeleteSheet(for: vmB)

        #expect(presenter.pendingCountForTesting == 1)
        #expect(presenter.pendingDeleteInstanceIDForTesting == vmA.id)
    }

    @Test("stop() cancels the in-flight resolution Task before it enqueues")
    func stopCancelsResolutionTask() async {
        let presenter = DetailAlertsPresenter(viewModel: makeViewModel())
        let vmA = makeInstance(name: "A")

        presenter.presentDeleteSheet(for: vmA)
        let task = presenter.deleteResolutionTaskForTesting
        // The test holds the main actor, so the Task body hasn't run yet —
        // cancellation lands before it can enqueue.
        presenter.stop()
        await task?.value

        #expect(presenter.pendingCountForTesting == 0)
        #expect(presenter.pendingDeleteInstanceIDForTesting == nil)
    }

    @Test("A new delete is accepted after teardown clears the de-dup id")
    func dedupResetsAfterStop() async {
        let presenter = DetailAlertsPresenter(viewModel: makeViewModel())
        let vmA = makeInstance(name: "A")

        presenter.presentDeleteSheet(for: vmA)
        let firstTask = presenter.deleteResolutionTaskForTesting
        presenter.stop()
        await firstTask?.value  // drain the cancelled Task (it bails, no enqueue)

        // De-dup id was cleared by stop(); a fresh request is accepted.
        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionTaskForTesting?.value

        #expect(presenter.pendingCountForTesting == 1)
        #expect(presenter.pendingDeleteInstanceIDForTesting == vmA.id)
    }
}
