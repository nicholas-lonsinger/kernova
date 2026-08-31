import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Unit tests for `AppClipboardReadout` — the one readout the app-level surfaces
/// render across every VM, and the Cancel routing behind it.
///
/// The routing is what docs/CLIPBOARD.md §13's "a Cancel stops what its own
/// readout showed" comes down to: the click carries the id the bar was rendered
/// for, and it has to reach that operation through whichever VM owns it rather
/// than whatever is newest by the time it lands.
@Suite("AppClipboardReadout", .admissionGated)
@MainActor
struct AppClipboardReadoutTests {
    private func makeInstance(name: String) -> VMInstance {
        let config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, phase: .running(sessionID: UUID()))
    }

    /// Stands a running, cancellable readout on `instance`, returning the
    /// operation behind it and the cell its cancel sets.
    ///
    /// The operation is returned so the caller can keep it alive: the reporter
    /// holds it weakly, and an operation nobody references has nothing left to
    /// cancel.
    private func runTransfer(
        on instance: VMInstance, gesture: ClipboardTransferGesture, since: Date
    ) -> (operation: ClipboardTransferOperation, cancelled: Box<Bool>) {
        let cancelled = Box(false)
        let operation = ClipboardTransferOperation(
            gesture: gesture, direction: .inbound, peerName: instance.name, revealDelay: 0,
            now: { 0 }, schedule: { _, _ in }, onCancelRequested: { cancelled.value = true },
            reporter: instance.clipboardTransfers)
        instance.clipboardTransfers.publish(
            from: operation,
            .running(
                ClipboardProgressSnapshot(
                    direction: .inbound, peerName: instance.name, currentItemName: nil,
                    filesCompleted: 0, fileCount: 1, bytesTransferred: 1, totalBytes: 2,
                    bytesPerSecond: nil, secondsRemaining: nil, gesture: gesture,
                    elapsedSeconds: 1, isCancellable: true, operationID: operation.id),
                since: since))
        return (operation, cancelled)
    }

    /// The id the readout `instances` renders was shown on.
    private func shownID(in instances: [VMInstance]) throws -> ClipboardTransferOperationID {
        guard case .running(let snapshot, _) = AppClipboardReadout.report(for: instances) else {
            throw TestFailure("the readout is not running")
        }
        return snapshot.operationID
    }

    // MARK: - Cancel routing

    @Test("Cancel reaches the VM the readout's id belongs to, not the newest one")
    func cancelRoutesToTheOwningVM() {
        let older = makeInstance(name: "Build VM")
        let newer = makeInstance(name: "CI VM")
        let shown = runTransfer(on: older, gesture: .paste, since: Date(timeIntervalSince1970: 100))
        let latest = runTransfer(
            on: newer, gesture: .paste, since: Date(timeIntervalSince1970: 200))

        #expect(AppClipboardReadout.cancel(shown.operation.id, in: [older, newer]))

        // Through the owning VM's reporter, which is what turns the id back into
        // the operation and asks it to stop.
        #expect(shown.cancelled.value)
        #expect(!latest.cancelled.value)
        withExtendedLifetime((shown.operation, latest.operation)) {}
    }

    @Test("A Cancel no VM claims stops nothing")
    func cancelOfAnUnclaimedIdStopsNothing() {
        let instance = makeInstance(name: "Build VM")
        let running = runTransfer(on: instance, gesture: .paste, since: Date())

        // The readout a stale click was rendered for: its operation retired
        // before the click landed, so no reporter answers for the id.
        #expect(!AppClipboardReadout.cancel(.unattached, in: [instance]))

        #expect(!running.cancelled.value)
        withExtendedLifetime(running.operation) {}
    }

    // MARK: - Readout ranking

    @Test("A peer's paste outranks a drop, and a drop outranks the rest")
    func readoutRanksAwaitedGesturesFirst() throws {
        let pasting = makeInstance(name: "Paste VM")
        let dropping = makeInstance(name: "Drop VM")
        let fetching = makeInstance(name: "Preview VM")
        // Reverse rank order in time, so recency alone would pick the loser at
        // each step.
        let paste = runTransfer(
            on: pasting, gesture: .peerPaste, since: Date(timeIntervalSince1970: 100))
        let drop = runTransfer(
            on: dropping, gesture: .drop, since: Date(timeIntervalSince1970: 200))
        let preview = runTransfer(
            on: fetching, gesture: .preview, since: Date(timeIntervalSince1970: 300))

        #expect(try shownID(in: [pasting, dropping, fetching]) == paste.operation.id)
        #expect(try shownID(in: [dropping, fetching]) == drop.operation.id)
        #expect(try shownID(in: [fetching]) == preview.operation.id)
        withExtendedLifetime((paste.operation, drop.operation, preview.operation)) {}
    }

    @Test("Two VMs at the same rank are settled by which opened its bar last")
    func readoutSettlesEqualRanksByRecency() throws {
        let earlier = makeInstance(name: "Build VM")
        let later = makeInstance(name: "CI VM")
        let first = runTransfer(
            on: earlier, gesture: .drop, since: Date(timeIntervalSince1970: 100))
        let second = runTransfer(
            on: later, gesture: .drop, since: Date(timeIntervalSince1970: 200))

        #expect(try shownID(in: [earlier, later]) == second.operation.id)
        #expect(try shownID(in: [later, earlier]) == second.operation.id)
        withExtendedLifetime((first.operation, second.operation)) {}
    }

    @Test("With nothing running the readout dwells on the most recent finish")
    func readoutDwellsOnTheLatestFinish() {
        let earlier = makeInstance(name: "Build VM")
        let later = makeInstance(name: "CI VM")
        finish(on: earlier, at: Date(timeIntervalSince1970: 100))
        finish(on: later, at: Date(timeIntervalSince1970: 200))

        guard case .finished(let finish) = AppClipboardReadout.report(for: [earlier, later]) else {
            Issue.record("the readout dropped both finished reports")
            return
        }
        #expect(finish.peerName == "CI VM")
    }

    /// Stands a completed transfer — one that still has a bar to dwell on — on
    /// `instance`.
    private func finish(on instance: VMInstance, at date: Date) {
        instance.clipboardTransfers.finish(
            ClipboardTransferFinish(
                gesture: .paste,
                outcome: .completed(
                    final: ClipboardProgressSnapshot(
                        direction: .inbound, peerName: instance.name, currentItemName: nil,
                        filesCompleted: 1, fileCount: 1, bytesTransferred: 2, totalBytes: 2,
                        bytesPerSecond: nil, secondsRemaining: nil, gesture: .paste,
                        elapsedSeconds: 1)),
                peerName: instance.name, date: date))
    }
}
