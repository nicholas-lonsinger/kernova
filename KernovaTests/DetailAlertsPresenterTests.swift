import AppKit
import Foundation
import Testing

@testable import Kernova

/// Covers the delete-sheet de-dup state machine (issue #362 and follow-ups
/// #364/#366): one sheet in flight at a time, the latest gesture winning (mode
/// upgrade *and* different-VM retarget) up until the sheet is shown, a
/// cancellable off-main resolution, and a per-sheet token so a stale close can't
/// clobber a newer delete.
///
/// Most tests don't call `start(window:)`, so `window == nil` and `runNext()`
/// always bails — enqueued show closures simply accumulate in `pending` (the
/// in-flight request is observed via the `…ForTesting` seams, and the
/// close-handler's token guard is driven directly through
/// `handleDeleteSheetClosedForTesting`). The shown-sheet tests DO use a real
/// `NSWindow` so `showDeleteSheet` runs and `deleteSheetPresenter.isShown`
/// becomes true synchronously.
///
/// Headless limitation: the async `beginSheet` dismissal completion is never
/// delivered (no run loop is spun), so the close()/onClose path and `reset()`'s
/// interaction with a genuinely-delivered completion are integration-only —
/// these tests assert the synchronous state transitions, not the async
/// completion (the same constraint `SheetPresenterTests` documents).
///
/// Determinism: each test holds the main actor synchronously from
/// `presentDeleteSheet` through the follow-up call/`stop()`, so the off-main
/// resolution Task can't run until the test `await`s the captured handle's
/// `.value` — event-driven, no polling.
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

    /// A VM carrying an external (non-bundle) storage disk so
    /// `externalAttachmentsResolvingExistence` actually runs its off-main
    /// `FileManager.fileExists` probe — exercising the real async resolve gap.
    private func makeInstanceWithExternalDisk(name: String = "Ext VM") -> VMInstance {
        var config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
        config.storageDisks = [
            StorageDisk(path: "/tmp/does-not-exist-\(config.id.uuidString).img", isInternal: false)
        ]
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    // MARK: - Mode (last gesture wins, both directions)

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
        // The show step reads `pendingDelete` directly, so this is the disposition
        // the sheet would carry — the immediate request is not downgraded to Trash.
        #expect(presenter.pendingDeletePermanentlyForTesting == true)
    }

    @Test("⌥⌘⌫ then ⌘⌫ on one VM downgrades to Trash (last gesture wins both ways)")
    func dedupSameVMDowngradesMode() async {
        let presenter = DetailAlertsPresenter(viewModel: makeViewModel())
        let vmA = makeInstance(name: "A")

        presenter.presentDeleteSheet(for: vmA, permanently: true)
        let task = presenter.deleteResolutionTaskForTesting
        presenter.presentDeleteSheet(for: vmA, permanently: false)
        await task?.value

        #expect(presenter.pendingCountForTesting == 1)
        // Last wins is symmetric: a later plain ⌘⌫ backs off bypass-Trash.
        #expect(presenter.pendingDeletePermanentlyForTesting == false)
    }

    // MARK: - Single in flight + different-VM retarget (#364)

    @Test("A different-VM request during the resolve retargets the in-flight sheet")
    func differentVMRetargets() async {
        let presenter = DetailAlertsPresenter(viewModel: makeViewModel())
        let vmA = makeInstance(name: "A")
        let vmB = makeInstance(name: "B")

        // vmA starts the in-flight delete; a vmB request before it resolves wins
        // (last gesture) — still a single sheet, now targeting vmB (#364).
        presenter.presentDeleteSheet(for: vmA)
        let task = presenter.deleteResolutionTaskForTesting
        presenter.presentDeleteSheet(for: vmB)
        await task?.value

        #expect(presenter.pendingCountForTesting == 1)
        #expect(presenter.pendingDeleteInstanceIDForTesting == vmB.id)
    }

    @Test("Retargeting to a different VM carries that VM's own disposition")
    func retargetCarriesNewVMMode() async {
        let presenter = DetailAlertsPresenter(viewModel: makeViewModel())
        let vmA = makeInstance(name: "A")
        let vmB = makeInstance(name: "B")

        // The request is a single {instance, permanently} unit, so retargeting
        // swaps both — vmA's Immediate intent does not leak onto vmB's Trash.
        presenter.presentDeleteSheet(for: vmA, permanently: true)
        let task = presenter.deleteResolutionTaskForTesting
        presenter.presentDeleteSheet(for: vmB, permanently: false)
        await task?.value

        #expect(presenter.pendingDeleteInstanceIDForTesting == vmB.id)
        #expect(presenter.pendingDeletePermanentlyForTesting == false)
    }

    @Test("A retarget landing DURING the off-main resolve re-resolves the new VM")
    func retargetDuringResolveReResolves() async {
        let presenter = DetailAlertsPresenter(viewModel: makeViewModel())
        let vmA = makeInstance(name: "A")
        let vmB = makeInstance(name: "B")

        // Drive a one-shot vmB request into the gap right after vmA's externals
        // resolve but before the loop checks whether the request changed — this
        // is the across-the-await `continue` re-resolve path (the #364 core) that
        // a synchronous retarget (handled before the Task body runs) can't reach.
        presenter.afterDeleteResolveForTesting = { [weak presenter] in
            presenter?.afterDeleteResolveForTesting = nil
            presenter?.presentDeleteSheet(for: vmB)
        }
        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionTaskForTesting?.value

        #expect(presenter.pendingCountForTesting == 1)
        #expect(presenter.pendingDeleteInstanceIDForTesting == vmB.id)
    }

    // MARK: - Shown sheet is authoritative (no silent drop)

    @Test("A delete gesture while the sheet is shown is ignored, not dropped")
    func ignoreWhileSheetShown() async {
        let presenter = DetailAlertsPresenter(viewModel: makeViewModel())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled], backing: .buffered, defer: true)
        presenter.start(window: window)
        let vmA = makeInstance(name: "A")
        let vmB = makeInstance(name: "B")

        // With a window, the resolved delete actually shows a sheet.
        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionTaskForTesting?.value
        #expect(presenter.pendingCountForTesting == 0)  // drained → shown, not queued

        // A different-VM gesture while that sheet is on screen is ignored (the
        // modal sheet is authoritative), NOT coalesced into the in-flight request
        // and then silently dropped when the shown sheet closes.
        presenter.presentDeleteSheet(for: vmB)
        #expect(presenter.pendingDeleteInstanceIDForTesting == vmA.id)

        presenter.stop()  // tear down the sheet so the window doesn't linger
    }

    @Test("A delete after teardown during a shown sheet is accepted, not blocked")
    func deleteAcceptedAfterStopDuringShownSheet() async {
        let presenter = DetailAlertsPresenter(viewModel: makeViewModel())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled], backing: .buffered, defer: true)
        presenter.start(window: window)
        let vmA = makeInstance(name: "A")
        let vmB = makeInstance(name: "B")

        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionTaskForTesting?.value  // vmA's sheet is shown

        // Teardown must clear the shown-sheet state synchronously; otherwise the
        // ignore guard would still see deleteSheetInstance set and reject the next
        // delete after the pane reappears.
        presenter.stop()
        presenter.start(window: window)
        presenter.presentDeleteSheet(for: vmB)
        await presenter.deleteResolutionTaskForTesting?.value

        #expect(presenter.pendingDeleteInstanceIDForTesting == vmB.id)
        // stop() resets the sheet synchronously, so the prior sheet's lingering
        // `isShown` doesn't stall vmB — its sheet drains immediately (count 0).
        #expect(presenter.pendingCountForTesting == 0)

        presenter.stop()
    }

    // MARK: - Teardown

    @Test("stop() cancels the resolution Task and clears all in-flight state")
    func stopClearsInFlightState() async {
        let presenter = DetailAlertsPresenter(viewModel: makeViewModel())
        let vmA = makeInstance(name: "A")

        presenter.presentDeleteSheet(for: vmA, permanently: true)
        let task = presenter.deleteResolutionTaskForTesting
        // The test holds the main actor, so the Task body hasn't run yet —
        // cancellation lands before it can enqueue.
        presenter.stop()
        await task?.value

        #expect(presenter.pendingCountForTesting == 0)
        #expect(presenter.pendingDeleteInstanceIDForTesting == nil)
        // Both halves of the request are cleared symmetrically (no latched mode).
        #expect(presenter.pendingDeletePermanentlyForTesting == nil)
        #expect(presenter.deleteResolutionTaskForTesting == nil)
    }

    @Test("stop() bumps the sheet token so a stale close is invalidated")
    func stopBumpsDeleteSheetToken() async {
        let presenter = DetailAlertsPresenter(viewModel: makeViewModel())
        let vmA = makeInstance(name: "A")
        let before = presenter.deleteSheetTokenForTesting

        presenter.presentDeleteSheet(for: vmA)
        let task = presenter.deleteResolutionTaskForTesting
        presenter.stop()
        await task?.value

        #expect(presenter.deleteSheetTokenForTesting == before + 1)
    }

    @Test("A new delete is accepted after teardown clears the in-flight request")
    func dedupResetsAfterStop() async {
        let presenter = DetailAlertsPresenter(viewModel: makeViewModel())
        let vmA = makeInstance(name: "A")

        presenter.presentDeleteSheet(for: vmA)
        let firstTask = presenter.deleteResolutionTaskForTesting
        presenter.stop()
        await firstTask?.value  // drain the cancelled Task (it bails, no enqueue)

        // The in-flight request was cleared by stop(); a fresh request is accepted.
        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionTaskForTesting?.value

        #expect(presenter.pendingCountForTesting == 1)
        #expect(presenter.pendingDeleteInstanceIDForTesting == vmA.id)
    }

    // MARK: - Close-handler token guard (#362 same-VM clobber)

    @Test("A close with the current token clears the in-flight delete")
    func currentTokenCloseClears() async {
        let presenter = DetailAlertsPresenter(viewModel: makeViewModel())
        let vmA = makeInstance(name: "A")

        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionTaskForTesting?.value

        // The shown sheet's onClose carries the current token — it clears.
        presenter.handleDeleteSheetClosedForTesting(token: presenter.deleteSheetTokenForTesting)
        #expect(presenter.pendingDeleteInstanceIDForTesting == nil)
    }

    @Test("A stale-token close does NOT clobber a newer delete (#362)")
    func staleTokenCloseDoesNotClobber() async {
        let presenter = DetailAlertsPresenter(viewModel: makeViewModel())
        let vmA = makeInstance(name: "A")

        presenter.presentDeleteSheet(for: vmA)
        await presenter.deleteResolutionTaskForTesting?.value

        // A stale sheet's late close (older token, e.g. after a stop()/start()
        // bumped the token) must not clear the newer in-flight delete — even for
        // the same VM, which an id-keyed guard could not distinguish.
        presenter.handleDeleteSheetClosedForTesting(token: presenter.deleteSheetTokenForTesting - 1)
        #expect(presenter.pendingDeleteInstanceIDForTesting == vmA.id)
    }

    // MARK: - Real off-main resolve path (#366)

    @Test("De-dup holds across the real off-main external-resolution probe")
    func dedupAcrossRealOffMainResolve() async {
        let presenter = DetailAlertsPresenter(viewModel: makeViewModel())
        let vm = makeInstanceWithExternalDisk(name: "Ext")

        // This VM has an external disk, so resolution genuinely suspends on the
        // off-main `FileManager.fileExists` probe (not the synchronous []-return
        // path the other tests take).
        presenter.presentDeleteSheet(for: vm, permanently: false)
        let task = presenter.deleteResolutionTaskForTesting
        presenter.presentDeleteSheet(for: vm, permanently: true)
        await task?.value

        #expect(presenter.pendingCountForTesting == 1)
        #expect(presenter.pendingDeleteInstanceIDForTesting == vm.id)
        #expect(presenter.pendingDeletePermanentlyForTesting == true)
    }
}
