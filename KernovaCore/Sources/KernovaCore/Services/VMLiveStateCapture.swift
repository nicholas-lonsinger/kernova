import Foundation
import KernovaCommandModel
import KernovaLogging

/// How a live guest's state is written beside the bundle's files, over the
/// session's own operations — the same steps for the engine's session and a
/// test's scripted one.
@MainActor
package enum VMLiveStateCapture {
    // The engine's category: each record is part of a VirtualizationService
    // operation.
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VirtualizationService")

    /// The one body every capture from a live VM runs: the USB question is
    /// decided first (``approve(_:toSave:as:)``), then `prepare` lays down the
    /// destination before the guest is touched, then inside one pause the
    /// guest's memory is written where `savingStateTo` says — through
    /// ``captureLiveState(_:_:session:wasRunning:saveFileURL:captureDisks:)``
    /// — and `copy` copies the disks beside it.
    ///
    /// Answers the guest put back the way it was found; a question the
    /// capture asks, which touches nothing; or — on any other failure, which
    /// leaves whatever `prepare` laid down for the caller to discard — where
    /// ``guestAfterFailedWarmCapture(_:_:session:wasRunning:)`` left it. Once
    /// past the question, the session still live is owed the removable-media
    /// reconcile that plugs its disks back in, on both outcomes.
    package static func captureWarm<Prepared: Sendable>(
        _ instance: VMInstance, _ capture: borrowing VMCaptureContext,
        consent: Consent, as action: USBSaveAction,
        session: any VMSnapshotSessionOperating,
        prepare: () async throws -> Prepared,
        savingStateTo saveFileURL: (Prepared) -> URL,
        copy: (Prepared) async throws -> Void
    ) async -> VMOperationEnding<Void> {
        let approval: UnplugApproval
        do {
            approval = try approve(consent, toSave: instance, as: action)
        } catch {
            return .failed(.asStarted, error)
        }
        let wasRunning =
            capture.operation.sessionID.map {
                instance.phase.operation?.startedFrom == .running(sessionID: $0)
            } ?? false
        defer {
            if let sessionID = capture.operation.sessionID {
                instance.peers?.oweRemovableMediaReconcile(to: instance, for: sessionID)
            }
        }
        do {
            let prepared = try await prepare()
            try await captureLiveState(
                capture, approval, session: session, wasRunning: wasRunning,
                saveFileURL: saveFileURL(prepared)
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

    // MARK: Writing a live guest's state

    /// What `saveMachineState` takes, which only this file can make: the two
    /// entry points below are then the only way to write a live guest's state.
    package struct SaveGrant: Sendable {
        fileprivate init() {}
    }

    /// A save's leave to unplug every USB device its VM holds, which only
    /// ``approve(_:toSave:as:)`` makes: each entry point below takes one, so
    /// no state is written past the question.
    package struct UnplugApproval: Sendable {
        fileprivate init() {}
    }

    /// Decides the USB question a save of `instance` as `action` asks under
    /// `consent` (``USBSaveDecision``) from the VM as it stands, throwing it
    /// as ``CommandError/confirmationRequired(_:)`` when it asks.
    package static func approve(
        _ consent: Consent, toSave instance: VMInstance, as action: USBSaveAction
    ) throws -> UnplugApproval {
        try USBSaveDecision.require(consent, toSave: instance, as: action)
        return UnplugApproval()
    }

    /// Writes the guest's state, as a suspend does, into `url`: every
    /// hot-pluggable USB device unplugged first, then the guest paused.
    ///
    /// No saved state holds a hot-plugged USB device. A removable medium in a
    /// saved state can fail its restore (FB25379418), so a restore lists none
    /// and the media are plugged back in once the guest runs again. A
    /// passthrough device restores two ways
    /// (docs/research/2026-10-02-vz-restore-matches-usb-passthrough-devices.md):
    /// naming it under the `uuid` it was saved with is the one
    /// `VZUSBDeviceConfiguration.uuid` documents, but VZ checks nothing about
    /// the hardware behind that `uuid`, and the resumed guest would trust its
    /// cached view of a drive the Mac or another VM may have written since;
    /// leaving it out restored on the one host build measured, and no vendor
    /// documents it. Taking it off before the write keeps a restore resting on
    /// neither.
    package static func suspendState(
        _ context: borrowing VMOperationContext, _ approval: UnplugApproval,
        session: any VMSnapshotSessionOperating, to url: URL
    ) async throws {
        for deviceID in try await devicesToUnplug(context, session: session) {
            try await unplug(deviceID, context, session: session)
        }
        try await writeState(context, approval, session: session, to: url)
    }

    /// Writes the guest's live state into `saveFileURL` as a warm capture
    /// does, copies the disks beside it, and leaves the guest executing only
    /// if it was found executing. Each passthrough accessory taken off is owed
    /// back to the guest, which keeps running.
    ///
    /// The resume is conditional because `resumeIfPaused` reads VZ's `state`,
    /// which does not record who paused the guest: an unconditional call
    /// restarts a guest the user paused before asking for the snapshot, while
    /// the VM is reported as paused.
    package static func captureLiveState(
        _ capture: borrowing VMCaptureContext, _ approval: UnplugApproval,
        session: any VMSnapshotSessionOperating,
        wasRunning: Bool,
        saveFileURL: URL,
        captureDisks: () async throws -> Void
    ) async throws {
        // Taken before the guest is touched: a session that ends while the
        // disks copy still leaves a complete capture, which the resume, a no-op
        // on a guest no longer paused, must not refuse.
        let execution = try capture.operation.liveExecution()
        try await unplugUSBDevices(owingReturns: capture, session: session)
        try await writeState(capture.operation, approval, session: session, to: saveFileURL)
        try await captureDisks()
        if wasRunning {
            try await session.resumeIfPaused(execution)
        }
    }

    /// Pauses the guest and writes its state into `url`: the one call to
    /// `saveMachineState`.
    private static func writeState(
        _ context: borrowing VMOperationContext, _ approval: UnplugApproval,
        session: any VMSnapshotSessionOperating, to url: URL
    ) async throws {
        try await session.pauseIfRunning()
        try await session.saveMachineState(to: url, SaveGrant())
    }

    /// ``suspendState(_:_:session:to:)``'s unplug for a warm capture, whose
    /// guest is still running afterwards: each passthrough accessory is owed
    /// back to it (``VMCaptureContext/oweReturn(of:)``) just before its own
    /// detach — macOS can assign it back before the detach returns — and
    /// forgiven if that detach throws, so what is owed is exactly what the
    /// sweep took off.
    private static func unplugUSBDevices(
        owingReturns capture: borrowing VMCaptureContext, session: any VMSnapshotSessionOperating
    ) async throws {
        let instance = capture.operation.instance
        for deviceID in try await devicesToUnplug(capture.operation, session: session) {
            let accessory = instance.liveUSBAccessories.first { $0.deviceID == deviceID }
            if let accessory {
                if accessory.accessory.identity == nil {
                    logger.log(
                        .warning,
                        "USB accessory \(accessory.accessory.displayName, privacy: .public) will not go back on '\(instance.name, privacy: .public)' after the capture: nothing durable identifies it"
                    )
                }
                capture.oweReturn(of: accessory)
            }
            do {
                try await unplug(deviceID, capture.operation, session: session)
            } catch {
                if let accessory { capture.forgiveReturn(of: accessory) }
                throw error
            }
        }
    }

    /// Every USB device on the session's controller but the VM's USB-kind
    /// storage disks, which are boot media, never hot-plugged, and stay.
    ///
    /// VZ's own list rather than Kernova's records of it, so a device those
    /// records lost still comes off.
    private static func devicesToUnplug(
        _ context: borrowing VMOperationContext, session: any VMSnapshotSessionOperating
    ) async throws -> [UUID] {
        let bootStorage = Set(
            context.instance.effectiveStorageDisks.filter { $0.kind == .usbMassStorage }.map(\.id))
        return try await session.usbDeviceIDs().filter { !bootStorage.contains($0) }
    }

    /// Unplugs the USB device `deviceID` names from the VM `context` holds,
    /// and drops it from what the session records the guest holding.
    ///
    /// A device the controller no longer holds is a success — an unplug got
    /// there first, and the post-condition already holds. Anything else throws:
    /// the save fails where the user can see it rather than write a state
    /// holding the device. The device that threw stays recorded, so what the
    /// guest still holds afterwards is exactly what this never reached.
    private static func unplug(
        _ deviceID: UUID, _ context: borrowing VMOperationContext,
        session: any VMSnapshotSessionOperating
    ) async throws {
        let instance = context.instance
        let name =
            instance.liveUSBAccessories.first { $0.deviceID == deviceID }?.accessory.displayName
            ?? instance.liveRemovableMedia.first { $0.id == deviceID }?.displayName
            ?? deviceID.uuidString
        do {
            try await session.detachUSBDevice(uuid: deviceID)
            // A .notice because it is an irreversible action on what the guest
            // holds: a passthrough device resets and the host takes it back,
            // and nothing else in the log says a save did that.
            logger.log(
                .notice,
                "Unplugged USB device \(name, privacy: .public) from '\(instance.name, privacy: .public)' before writing its state"
            )
        } catch VMSessionError.usbDeviceNotFound {
            logger.log(
                .notice,
                "USB device \(name, privacy: .public) was already off '\(instance.name, privacy: .public)' before the save"
            )
        }
        if context.releaseAccessory(deviceID: deviceID) == nil, let sessionID = context.sessionID {
            instance.forgetAttachedMedia(deviceID: deviceID, for: sessionID)
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
            try await session.resumeIfPaused(context.liveExecution())
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
