import Foundation
import KernovaLogging

/// How a live guest's state is written beside the bundle's files, over the
/// session's own operations — the same steps for the engine's session and a
/// test's scripted one.
@MainActor
package enum VMLiveStateCapture {
    // The engine's category: each record is part of a VirtualizationService
    // operation.
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VirtualizationService")

    /// The one body every capture from a live VM runs: `prepare` lays down
    /// the destination before the guest is touched, then inside one pause the
    /// guest's memory is written where `savingStateTo` says — every
    /// passthrough USB accessory taken off first and owed back — and `copy`
    /// copies the disks beside it.
    ///
    /// Answers the guest put back the way it was found, or — on a failure,
    /// which leaves whatever `prepare` laid down for the caller to discard —
    /// where ``guestAfterFailedWarmCapture(_:_:session:wasRunning:)`` left it.
    package static func captureWarm<Prepared: Sendable>(
        _ instance: VMInstance, _ capture: borrowing VMCaptureContext,
        session: any VMSnapshotSessionOperating,
        prepare: () async throws -> Prepared,
        savingStateTo saveFileURL: (Prepared) -> URL,
        copy: (Prepared) async throws -> Void
    ) async -> VMOperationEnding<Void> {
        let wasRunning =
            capture.operation.sessionID.map {
                instance.phase.operation?.startedFrom == .running(sessionID: $0)
            } ?? false
        do {
            let prepared = try await prepare()
            try await detachUSBAccessories(owingReturns: capture, session: session)
            try await captureLiveState(
                session: session, wasRunning: wasRunning, saveFileURL: saveFileURL(prepared)
            ) {
                try await copy(prepared)
            }
        } catch {
            let guest = await guestAfterFailedWarmCapture(
                instance, capture.operation, session: session, wasRunning: wasRunning)
            return .failed(.live(guest), error)
        }
        return .rest(.live(wasRunning ? .running : .paused), ())
    }

    /// Takes every passthrough USB accessory off the VM `context` holds before
    /// its state is written.
    ///
    /// A saved state holding a passthrough device restores two ways
    /// (docs/research/2026-10-02-vz-restore-matches-usb-passthrough-devices.md).
    /// Naming the device under the `uuid` it was saved with is the one
    /// `VZUSBDeviceConfiguration.uuid` documents, but VZ checks nothing about
    /// the hardware behind that `uuid`, and the resumed guest would trust its
    /// cached view of a drive the Mac or another VM may have written since.
    /// Leaving the device out restored on the one host build measured, and no
    /// vendor documents it. Detaching before the write keeps every saved state
    /// free of host hardware, so a restore rests on neither. Both save paths
    /// call this — the warm capture through
    /// ``detachUSBAccessories(owingReturns:session:)`` — and a new one must too.
    ///
    /// A device the controller no longer holds is a success — an unplug got
    /// there first, and the post-condition already holds. Anything else throws:
    /// a state still carrying a passthrough device restores only by one of the
    /// two ways above, so the save fails where the user can see it rather than
    /// write one.
    ///
    /// Each accessory is released as its device leaves, and the one that threw
    /// is kept, so what the guest still holds afterwards is exactly what this
    /// never reached.
    package static func detachUSBAccessories(
        _ context: borrowing VMOperationContext, session: any VMSnapshotSessionOperating
    ) async throws {
        for item in context.instance.liveUSBAccessories {
            try await detachUSBAccessory(item, context, session: session)
        }
    }

    /// ``detachUSBAccessories(_:session:)`` for a warm capture, whose guest
    /// is still running afterwards: each accessory is owed back to it
    /// (``VMCaptureContext/oweReturn(of:)``) just before its own detach —
    /// macOS can assign it back before the detach returns — and forgiven if
    /// that detach throws, so what is owed is exactly what the sweep took off.
    package static func detachUSBAccessories(
        owingReturns capture: borrowing VMCaptureContext, session: any VMSnapshotSessionOperating
    ) async throws {
        let instance = capture.operation.instance
        for item in instance.liveUSBAccessories {
            if item.accessory.identity == nil {
                logger.log(
                    .warning,
                    "USB accessory \(item.accessory.displayName, privacy: .public) will not go back on '\(instance.name, privacy: .public)' after the capture: nothing durable identifies it"
                )
            }
            capture.oweReturn(of: item)
            do {
                try await detachUSBAccessory(item, capture.operation, session: session)
            } catch {
                capture.forgiveReturn(of: item)
                throw error
            }
        }
    }

    /// Takes `item` off the VM `context` holds and releases it.
    private static func detachUSBAccessory(
        _ item: AttachedUSBAccessory, _ context: borrowing VMOperationContext,
        session: any VMSnapshotSessionOperating
    ) async throws {
        let instance = context.instance
        do {
            try await session.detachUSBDevice(uuid: item.deviceID)
            // A .notice because it is an irreversible action on the user's
            // own hardware: the device resets and the host takes it back,
            // and nothing else in the log says a save did that.
            logger.log(
                .notice,
                "Took USB accessory \(item.accessory.displayName, privacy: .public) off '\(instance.name, privacy: .public)' before writing its state"
            )
        } catch VMSessionError.usbDeviceNotFound {
            logger.log(
                .notice,
                "USB accessory \(item.accessory.displayName, privacy: .public) was already off '\(instance.name, privacy: .public)' before the save"
            )
        }
        context.releaseAccessory(deviceID: item.deviceID)
    }

    /// Writes the guest's live state into `saveFileURL`, copies the disks
    /// beside it, and leaves the guest executing only if it was found
    /// executing.
    ///
    /// The resume is conditional because `resumeIfPaused` reads VZ's `state`,
    /// which does not record who paused the guest: an unconditional call
    /// restarts a guest the user paused before asking for the snapshot, while
    /// the VM is reported as paused.
    package static func captureLiveState(
        session: any VMSnapshotSessionOperating,
        wasRunning: Bool,
        saveFileURL: URL,
        captureDisks: () async throws -> Void
    ) async throws {
        try await session.pauseIfRunning()
        try await session.saveMachineState(to: saveFileURL)
        try await captureDisks()
        if wasRunning {
            try await session.resumeIfPaused()
        }
    }

    /// Where a live guest is left after a warm capture failed.
    ///
    /// The guest may be paused anywhere between the pause and the resume, so
    /// the recovery is to put it back — and a guest that cannot be resumed is
    /// left live-paused, which Resume retries.
    package static func guestAfterFailedWarmCapture(
        _ instance: VMInstance, _ context: borrowing VMOperationContext,
        session: any VMSnapshotSessionOperating, wasRunning: Bool
    ) async -> VMGuestRunState {
        guard wasRunning, context.sessionID != nil else { return .paused }
        do {
            try await session.resumeIfPaused()
            return .running
        } catch {
            logger.log(
                .warning,
                "Could not resume '\(instance.name, privacy: .public)' after a failed capture: \(error.localizedDescription, privacy: .public)"
            )
            return .paused
        }
    }
}
