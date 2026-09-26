import Foundation
import KernovaKit
import KernovaLogging
import Virtualization

/// Manages VM lifecycle operations: start, stop, pause, resume, save, and restore.
///
/// Stays on the main actor because it mutates `VMInstance`; every
/// `VZVirtualMachine` touch goes through the instance's `VMSession`, the VM's
/// own isolation domain on its private queue.
@MainActor
final class VirtualizationService {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VirtualizationService")

    private let configBuilder: ConfigurationBuilder

    init(vmnetNetworks: any VmnetNetworkProviding, entitlements: EntitlementService) {
        configBuilder = ConfigurationBuilder(vmnetNetworks: vmnetNetworks, entitlements: entitlements)
    }

    // MARK: - Start

    /// Brings the guest up the way the bring-up holding the VM names: a cold
    /// boot, a Recovery boot, or the restore of the bundle's saved state.
    ///
    /// `provisioning` is the account a cold boot creates inside the guest. The
    /// same value goes into every file-lock retry, each of which is the same
    /// boot trying again. A recovery boot and a restore from a save file both
    /// read none, for the reason
    /// ``MacOSGuestProvisioning/macOSStartOptions(bootIntoRecovery:guestOS:provisioning:)``
    /// states.
    func start(
        _ instance: VMInstance, _ context: borrowing VMGuestStartContext,
        provisioning: GuestProvisioningCredentials?
    ) async throws -> VMOperationEnding<GuestStartRoute> {
        let route = GuestStartRoute(context.kind)
        let hasSaveFile = context.bringUp.operation.bundle.hasSaveFile
        #log(
            Self.logger, .debug,
            "start: route=\(String(describing: route), privacy: .public), hasSaveFile=\(hasSaveFile, privacy: .public)"
        )
        do {
            switch route {
            case .restoredSavedState:
                try await restoreFromSaveFile(instance, context.bringUp)
            case .coldBoot, .recoveryBoot:
                try await coldBootRetryingLockContention(
                    instance, context.bringUp, bootIntoRecovery: route == .recoveryBoot,
                    provisioning: route.deliversGuestProvisioning ? provisioning : nil)
            }
        } catch {
            // A restore failure already logged itself with the full error chain.
            if !Self.isRestoreFailure(error) {
                let nsError = error as NSError
                #log(
                    Self.logger, .error,
                    "Failed to start VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public); underlying: \(Self.underlyingChainDescription(nsError), privacy: .public)]"
                )
            }
            throw error
        }
        switch route {
        case .recoveryBoot:
            #log(
                Self.logger, .notice,
                "Started VM '\(instance.name, privacy: .public)' in recovery mode")
        case .coldBoot, .restoredSavedState:
            #log(Self.logger, .notice, "Started VM '\(instance.name, privacy: .public)'")
        }
        // A session that went away between VZ reporting the machine up and
        // here rests the VM where its end says; the route still answers,
        // because the guest did come up.
        return .rest(.live(.running), route)
    }

    // MARK: - Cold Boot

    /// Cold-boots `instance`, retrying with bounded backoff when the start fails on
    /// VZ file-lock contention (see ``isFileLockContention(_:)``).
    ///
    /// A previous `VZVirtualMachine` on the same bundle releases its advisory lock
    /// on the auxiliary-storage and disk-image files only when fully *deallocated*,
    /// which lags `vm.state == .stopped` by more the more guest memory there is to
    /// tear down. No public VZ API observes the release, so gating on state cannot
    /// be airtight; a bounded retry against the ground-truth failure is.
    private func coldBootRetryingLockContention(
        _ instance: VMInstance, _ context: borrowing VMBringUpContext, bootIntoRecovery: Bool,
        provisioning: GuestProvisioningCredentials?
    ) async throws {
        var attempt = 0
        while true {
            do {
                try await coldBoot(
                    instance, context, bootIntoRecovery: bootIntoRecovery,
                    provisioning: provisioning)
                return
            } catch let startError {
                guard Self.isFileLockContention(startError),
                    let delay = Self.fileLockRetryDelay(forAttempt: attempt)
                else { throw startError }
                attempt += 1
                #log(
                    Self.logger, .warning,
                    "Cold boot of '\(instance.name, privacy: .public)' hit file-lock contention; retry \(attempt, privacy: .public) in \(String(describing: delay), privacy: .public)"
                )
                context.operation.endSession()
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    // Cancelled mid-backoff: surface the original lock failure
                    // rather than leak a `CancellationError` into the status/alert
                    // classification paths, which aren't shaped for it.
                    throw startError
                }
            }
        }
    }

    /// Builds a fresh configuration and `VZVirtualMachine`, wires the session
    /// plumbing, and starts the machine — one cold-boot attempt.
    private func coldBoot(
        _ instance: VMInstance, _ context: borrowing VMBringUpContext, bootIntoRecovery: Bool,
        provisioning: GuestProvisioningCredentials?
    ) async throws {
        // Per attempt, not once per start: the lock-contention retry loop ends
        // the session between attempts, taking this context's scopes with it.
        instance.beginSessionContext(context, bootedIntoRecovery: bootIntoRecovery)
        let result = try await buildConfiguration(for: instance, context.operation)
        guard let session = await instance.bringUpSession(context, with: result) else {
            throw VirtualizationError.noVirtualMachine
        }
        let startOptions = MacOSGuestProvisioning.macOSStartOptions(
            bootIntoRecovery: bootIntoRecovery, guestOS: instance.configuration.guestOS,
            provisioning: provisioning)
        try await session.start(options: startOptions)
    }

    /// Detects VZ's advisory file-lock contention on a VM's backing files.
    ///
    /// Matches "Failed to lock auxiliary storage" (or the disk-image equivalent):
    /// `.invalidVirtualMachineConfiguration` carrying a POSIX `EAGAIN` underneath,
    /// which is what separates it from a genuinely invalid configuration (same VZ
    /// code, no `EAGAIN`) — matching localized text would be locale-fragile. A
    /// disk-image attach failure arrives wrapped in a `ConfigurationBuilderError`,
    /// so unwrap before matching or the contention retry never fires.
    nonisolated static func isFileLockContention(_ error: Error) -> Bool {
        if let builderError = error as? ConfigurationBuilderError,
            let underlying = builderError.underlyingAttachError
        {
            return isFileLockContention(underlying)
        }
        let nsError = error as NSError
        guard nsError.domain == VZError.errorDomain,
            VZError.Code(rawValue: nsError.code) == .invalidVirtualMachineConfiguration,
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        else { return false }
        return underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(EAGAIN)
    }

    /// Backoff before file-lock-contention cold-boot retry number `attempt`.
    ///
    /// `attempt` is 0-based; returns `nil` once the ~3.75 s budget is exhausted.
    /// Escalates because the holder's teardown time scales with guest memory size.
    static func fileLockRetryDelay(forAttempt attempt: Int) -> Duration? {
        let delays: [Duration] = [
            .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2),
        ]
        guard delays.indices.contains(attempt) else { return nil }
        return delays[attempt]
    }

    // MARK: - Stop

    /// Sends the live guest the ACPI shutdown request.
    func requestStop(_ instance: VMInstance) async throws {
        guard let session = instance.session else { throw VirtualizationError.noVirtualMachine }
        do {
            try await session.requestStop()
            #log(Self.logger, .notice, "Requested stop for VM '\(instance.name, privacy: .public)'")
        } catch {
            #log(
                Self.logger, .error,
                "Failed to stop VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    /// Terminates the live guest where it stands.
    func forceStop(_ instance: VMInstance) async throws {
        guard let session = instance.session else { throw VirtualizationError.noVirtualMachine }
        do {
            try await session.stop()
            #log(Self.logger, .notice, "Force-stopped VM '\(instance.name, privacy: .public)'")
        } catch {
            #log(
                Self.logger, .error,
                "Failed to force-stop VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - Pause / Resume

    func pause(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        guard let session = context.session else { throw VirtualizationError.noVirtualMachine }
        do {
            try await session.pause()
        } catch {
            // The VM stays where it was, still holding the session, with Stop,
            // Force Stop and a retried Pause all offered; the failure reaches
            // the user as the thrown error.
            #log(
                Self.logger, .error,
                "Failed to pause VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        // The grace clock only means something while the guest is executing
        // — a frozen guest cannot say Hello, so letting it run would blame
        // the agent for the pause.
        instance.cancelAgentPostStartWatchdog()
        #log(Self.logger, .notice, "Paused VM '\(instance.name, privacy: .public)'")
        return .rest(.live(.paused), ())
    }

    /// Resumes a live-paused guest from memory.
    func resume(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        guard let session = context.session else { throw VirtualizationError.noVirtualMachine }
        do {
            try await session.resume()
        } catch {
            #log(
                Self.logger, .error,
                "Failed to resume VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        context.bundle.removeSaveFile()
        #log(Self.logger, .notice, "Resumed VM '\(instance.name, privacy: .public)'")
        return .rest(.live(.running), ())
    }

    // MARK: - Save

    /// Writes the guest's state to the bundle's suspend slot (pause, then
    /// save) and ends the session.
    func save(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        guard let session = context.session else { throw VirtualizationError.noVirtualMachine }
        return try await Self.save(instance, context, session: session)
    }

    /// ``save(_:_:)`` over the VZ operations it needs rather than a concrete
    /// session — like ``captureWarmSnapshot(_:_:snapshot:session:)``, so the
    /// slot it drops when the write fails or the guest goes away under it is
    /// reachable without a real `VZVirtualMachine`.
    static func save(
        _ instance: VMInstance, _ context: borrowing VMOperationContext,
        session: any VMSnapshotSessionOperating
    ) async throws -> VMOperationEnding<Void> {
        guard let sessionID = context.sessionID else { throw VirtualizationError.noVirtualMachine }
        do {
            try await detachUSBAccessories(from: instance, session: session, for: sessionID)
            try await session.pauseIfRunning()
            try await session.saveMachineState(to: context.bundle.saveFileURL)
        } catch {
            #log(
                logger, .error,
                "Failed to save VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            // `saveMachineState` writes the slot in place, so a throw leaves it
            // part-written — which a relaunch would offer as a resumable
            // session that cannot restore.
            context.bundle.removeSaveFile()
            // A guest that went away under the write rests the VM where its
            // end says; a failure written over it would report a state this
            // save did not produce.
            let rest: VMOperationRest =
                context.sessionEnd == nil
                ? .atRest(.failed(message: error.localizedDescription)) : .afterSessionEnd
            return .failed(rest, error)
        }
        guard context.sessionEnd == nil else {
            // The guest went away mid-write, so the slot on disk is however far
            // VZ got.
            context.bundle.removeSaveFile()
            #log(
                logger, .notice,
                "VM '\(instance.name, privacy: .public)' lost its session mid-suspend — its partial saved state was dropped"
            )
            return .rest(.afterSessionEnd, ())
        }
        // No sidecar metadata is needed beside the save file: removable media
        // carry stable UUIDs and storage disks stable virtio block identifiers
        // in `config`, and VZ matches both on restore.
        context.endSession()
        #log(logger, .notice, "Saved state for VM '\(instance.name, privacy: .public)'")
        return .rest(.atRest(.stopped), ())
    }

    // MARK: - Snapshots

    /// Captures `snapshot` in the mode the capture operation was admitted in:
    /// a live capture writes the guest's memory into the snapshot's own saved
    /// state and copies the bundle's disks beside it, a suspended capture
    /// clones the bundle's suspend slot beside the disk copies, and a stopped
    /// capture copies the disks alone.
    ///
    /// A live capture pauses the guest for the write and puts it back the way it
    /// was found, so the VM keeps running across a snapshot — and the suspend
    /// slot is untouched either way. A failure discards the half-written
    /// snapshot directory and leaves the VM where it was: live, paused at
    /// worst, or at rest.
    func takeSnapshot(
        _ instance: VMInstance, _ context: borrowing VMCaptureContext,
        snapshot request: VMSnapshotCaptureRequest
    ) async throws -> VMOperationEnding<VMSnapshot> {
        let mode = context.mode
        #log(
            Self.logger, .debug,
            "takeSnapshot: mode=\(String(describing: mode), privacy: .public), status=\(instance.status.displayName, privacy: .public)"
        )
        let snapshot = request.record(capturedIn: mode)
        switch mode {
        case .live:
            guard let session = context.operation.session else {
                throw VirtualizationError.noVirtualMachine
            }
            return try await Self.captureWarmSnapshot(
                instance, context.operation, snapshot: request, session: session)
        case .suspended:
            return try await takeSuspendedSnapshot(instance, context.operation, snapshot: snapshot)
        case .stopped:
            return try await takeColdSnapshot(instance, context.operation, snapshot: snapshot)
        }
    }

    /// The guest's memory plus the bundle's disks, from a live VM, over the VZ
    /// operations it needs rather than a concrete session.
    ///
    /// Takes the session as a parameter so the resting phase it answers — the
    /// one place a capture can hand the VM back to a session that is no longer
    /// there — is reachable without the virtualization entitlement a real
    /// `VZVirtualMachine` needs.
    static func captureWarmSnapshot(
        _ instance: VMInstance, _ context: borrowing VMOperationContext,
        snapshot request: VMSnapshotCaptureRequest, session: any VMSnapshotSessionOperating
    ) async throws -> VMOperationEnding<VMSnapshot> {
        guard let sessionID = context.sessionID else { throw VirtualizationError.noVirtualMachine }
        let snapshot = request.record(capturedIn: .live)
        let wasRunning = instance.phase.operation?.startedFrom == .running(sessionID: sessionID)
        let configuration = instance.configuration
        let snapshotID = snapshot.id

        do {
            let prepared = try await context.bundle.prepareSnapshot(snapshotID, configuration: configuration)

            // The guest is still there afterwards, so these are put back once
            // the capture is done — see
            // ``VMLifecycleCoordinator/takeSnapshot(_:snapshot:record:)``.
            try await detachUSBAccessories(
                from: instance, session: session, for: sessionID)
            try await captureLiveState(
                session: session, wasRunning: wasRunning, saveFileURL: prepared.saveFileURL
            ) {
                try await context.bundle.captureDisks(
                    intoSnapshot: snapshotID, relativePaths: prepared.relativePaths)
            }
        } catch {
            await context.bundle.removeSnapshotDirectory(snapshotID)
            #log(
                logger, .error,
                "Failed to snapshot VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            let guest = await guestAfterFailedWarmCapture(
                instance, context, session: session, wasRunning: wasRunning)
            return .failed(.live(guest), error)
        }

        if context.sessionID == nil {
            // The guest went away while its disks were copied. The saved state
            // and the disks were both written before that happened, so the
            // snapshot is complete and the caller records it.
            #log(
                logger, .notice,
                "Took snapshot '\(snapshot.name, privacy: .public)' of VM '\(instance.name, privacy: .public)', which lost its session mid-capture"
            )
        } else {
            #log(
                logger, .notice,
                "Took snapshot '\(snapshot.name, privacy: .public)' of VM '\(instance.name, privacy: .public)'"
            )
        }
        return .rest(
            .live(wasRunning ? .running : .paused),
            VMSnapshot(snapshot, macAddress: configuration.macAddress))
    }

    /// The bundle's disks alone, from a stopped VM — no VZ work, so nothing is
    /// paused and no saved state is written.
    private func takeColdSnapshot(
        _ instance: VMInstance, _ context: borrowing VMOperationContext,
        snapshot: VMSnapshotRecord
    ) async throws -> VMOperationEnding<VMSnapshot> {
        let configuration = instance.configuration
        let snapshotID = snapshot.id
        do {
            let prepared = try await context.bundle.prepareSnapshot(snapshotID, configuration: configuration)
            try await context.bundle.captureDisks(
                intoSnapshot: snapshotID, relativePaths: prepared.relativePaths)
        } catch {
            await context.bundle.removeSnapshotDirectory(snapshotID)
            #log(
                Self.logger, .error,
                "Failed to snapshot VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        #log(
            Self.logger, .notice,
            "Took a disks-only snapshot '\(snapshot.name, privacy: .public)' of VM '\(instance.name, privacy: .public)'"
        )
        return .rest(.asStarted, VMSnapshot(snapshot, macAddress: configuration.macAddress))
    }

    /// The bundle's suspend slot plus its disks, from a VM paused to disk.
    ///
    /// A file copy with no VZ work: nothing is resumed, no saved state is
    /// written, and the slot the VM would resume from is left in place. The
    /// clone shares its blocks with that slot, so the capture costs the volume
    /// nothing until a resume drops the bundle's copy.
    private func takeSuspendedSnapshot(
        _ instance: VMInstance, _ context: borrowing VMOperationContext,
        snapshot: VMSnapshotRecord
    ) async throws -> VMOperationEnding<VMSnapshot> {
        let configuration = instance.configuration
        let snapshotID = snapshot.id
        do {
            let prepared = try await context.bundle.prepareSnapshot(snapshotID, configuration: configuration)
            try await context.bundle.captureDisks(
                intoSnapshot: snapshotID, relativePaths: prepared.relativePaths)
            try await context.bundle.captureSuspendSlot(intoSnapshot: snapshotID)
        } catch {
            await context.bundle.removeSnapshotDirectory(snapshotID)
            #log(
                Self.logger, .error,
                "Failed to snapshot VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        #log(
            Self.logger, .notice,
            "Took a suspended-state snapshot '\(snapshot.name, privacy: .public)' of VM '\(instance.name, privacy: .public)'"
        )
        return .rest(.asStarted, VMSnapshot(snapshot, macAddress: configuration.macAddress))
    }

    /// Takes every passthrough USB accessory off `instance` before its state is
    /// written, and answers what it took off.
    ///
    /// A saved state is restored only into a configuration compatible with it,
    /// and a passthrough device names host hardware that may be in a drawer by
    /// then — a mismatch VZ reports as `VZErrorRestore`, failing the whole
    /// restore with nothing the user can remove to recover. Nothing persists an
    /// attachment, so dropping them before the write makes that unreachable
    /// rather than merely unlikely. Both save paths call this, and a new one
    /// must too.
    ///
    /// A device the controller no longer holds is a success — an unplug got
    /// there first, and the post-condition already holds. Anything else throws:
    /// writing a state that still carries a passthrough device produces a save
    /// nothing can restore, so the save must fail where the user can see it
    /// rather than succeed into an unusable file.
    ///
    /// Each entry is cleared as its device leaves, and the one that threw is
    /// left, so what the instance still holds afterwards is exactly what this
    /// never reached — which is how the put-back knows what a sweep that threw
    /// part-way ejected. See
    /// ``VMLifecycleCoordinator/reattachUSBAccessories(ejectedFrom:on:for:)``.
    @discardableResult
    static func detachUSBAccessories(
        from instance: VMInstance, session: any VMSnapshotSessionOperating, for sessionID: UUID
    ) async throws -> [AttachedUSBAccessory] {
        let attached = instance.liveUSBAccessories
        for item in attached {
            do {
                try await session.detachUSBDevice(uuid: item.deviceID)
                // A .notice because it is an irreversible action on the user's
                // own hardware: the device resets and the host takes it back,
                // and nothing else in the log says a save did that.
                #log(
                    logger, .notice,
                    "Took USB accessory \(item.accessory.displayName, privacy: .public) off '\(instance.name, privacy: .public)' before writing its state"
                )
            } catch VMSessionError.usbDeviceNotFound {
                #log(
                    logger, .notice,
                    "USB accessory \(item.accessory.displayName, privacy: .public) was already off '\(instance.name, privacy: .public)' before the save"
                )
            }
            instance.forgetAttachedAccessory(deviceID: item.deviceID, for: sessionID)
        }
        return attached
    }

    /// Writes the guest's live state into `saveFileURL`, copies the disks
    /// beside it, and leaves the guest executing only if it was found
    /// executing.
    ///
    /// The resume is conditional because `resumeIfPaused` reads VZ's `state`,
    /// which does not record who paused the guest: an unconditional call
    /// restarts a guest the user paused before asking for the snapshot, while
    /// the VM is reported as paused.
    static func captureLiveState(
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
    static func guestAfterFailedWarmCapture(
        _ instance: VMInstance, _ context: borrowing VMOperationContext,
        session: any VMSnapshotSessionOperating, wasRunning: Bool
    ) async -> VMGuestRunState {
        guard wasRunning, context.sessionID != nil else { return .paused }
        do {
            try await session.resumeIfPaused()
            return .running
        } catch {
            #log(
                logger, .warning,
                "Could not resume '\(instance.name, privacy: .public)' after a failed snapshot: \(error.localizedDescription, privacy: .public)"
            )
            return .paused
        }
    }

    // MARK: - Revert

    /// Returns the VM to a snapshot: its live session is discarded and the
    /// snapshot's disks and configuration are written back over the bundle's.
    ///
    /// A warm snapshot installs its saved state, and a revert whose context
    /// `resumesAfter` restores it inside this same operation; a cold snapshot
    /// drops the bundle's saved state and the VM rests stopped, whatever it
    /// was doing before.
    ///
    /// The snapshot keeps its own copies, so it stays revertible. A failure
    /// bringing the VM back up afterwards arrives as
    /// ``VirtualizationError/revertResumeFailed(underlying:)`` — the files are
    /// in place by then, so the caller records the revert as having landed.
    func revertToSnapshot(
        _ instance: VMInstance, _ context: borrowing VMRevertContext,
        commitConfiguration: @MainActor (VMSnapshotRestorePlan) throws -> Void
    ) async throws -> VMOperationEnding<Void> {
        let snapshot = context.snapshot
        #log(
            Self.logger, .debug,
            "revertToSnapshot: status=\(instance.status.displayName, privacy: .public), hasVM=\(instance.hasLiveVirtualMachine, privacy: .public)"
        )
        let snapshotID = snapshot.id

        // Read-only, and ahead of the teardown: a snapshot that turns out to be
        // incomplete refuses without having cost the user the live guest.
        let plan: VMSnapshotRestorePlan
        do {
            plan = try await context.bringUp.operation.bundle.planRestore(
                fromSnapshot: snapshotID, kind: snapshot.kind)
        } catch {
            return .failed(.asStarted, error)
        }

        // A live guest's memory and disks are exactly what the revert replaces,
        // and the user confirmed losing them — so terminate rather than save.
        if let session = context.bringUp.operation.session {
            do {
                try await session.stop()
            } catch {
                #log(
                    Self.logger, .warning,
                    "Terminating '\(instance.name, privacy: .public)' before a revert failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        context.bringUp.operation.endSession()

        // Staged, then committed, then installed: nothing in the bundle moves
        // until the files are cloned aside and the configuration — which the
        // saved state only loads back into — has landed, so a full volume or
        // a failed write stops the revert while it still costs the bundle
        // nothing.
        do {
            try await context.bringUp.operation.bundle.stageRestore(
                fromSnapshot: snapshotID, plan: plan)
            do {
                try commitConfiguration(plan)
            } catch {
                await context.bringUp.operation.bundle.discardRestoreStaging()
                throw error
            }
            try await context.bringUp.operation.bundle.installRestore(plan)
        } catch {
            #log(
                Self.logger, .error,
                "Failed to revert VM '\(instance.name, privacy: .public)' to '\(snapshot.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return .failed(.atRest(.stopped), error)
        }
        #log(
            Self.logger, .notice,
            "Reverted VM '\(instance.name, privacy: .public)' to snapshot '\(snapshot.name, privacy: .public)'"
        )

        // A warm revert leaves the snapshot's saved state in the bundle and a
        // cold one leaves none, so the write that just landed is what says
        // where the VM rests — unless the revert goes back to being live at
        // the captured state, which only a warm snapshot captured.
        guard context.resumesAfter, plan.kind == .warm else { return .rest(.atRest(.stopped), ()) }
        do {
            try await restoreFromSaveFile(instance, context.bringUp)
        } catch {
            return .failed(.atRest(.stopped), VirtualizationError.revertResumeFailed(underlying: error))
        }
        return .rest(.live(.running), ())
    }

    // MARK: - Error Classification

    /// How far an `NSUnderlyingErrorKey` walk follows the chain — framework
    /// `userInfo` can nest arbitrarily deep, or cyclically.
    nonisolated private static let maxUnderlyingErrorDepth = 4

    /// Returns `true` when the error is a transient environmental condition (e.g. too many
    /// concurrent VMs) rather than a problem with the VM itself.
    ///
    /// Transient leaves a plain start in `.stopped` and an install in
    /// `.initialBoot`, with no stored message; permanent rests at `.failed`
    /// (red) carrying the message for the banner and tooltip.
    nonisolated static func isTransientStartError(_ error: Error) -> Bool {
        // Checked ahead of the builder-error rule below: contention on a disk image
        // surfaces *as* a builder error and is still transient — the lock holder is
        // a dying VZVirtualMachine that releases it at deallocation.
        if isFileLockContention(error) { return true }

        if error is ConfigurationBuilderError { return false }

        if isVirtualMachineLimitExceeded(error) { return true }

        // Top level only, unlike the limit code: a cancel nested under a failure
        // describes a teardown step, not the failure that has to be classified.
        let nsError = error as NSError
        return nsError.domain == VZError.errorDomain
            && VZError.Code(rawValue: nsError.code) == .operationCancelled
    }

    /// Returns `true` when `error`, or anything within
    /// ``maxUnderlyingErrorDepth`` of its `NSUnderlyingErrorKey` chain, is
    /// `VZError.Code.virtualMachineLimitExceeded`.
    ///
    /// `VZMacOSInstaller.install()` surfaces the cap as `.installationFailed`
    /// carrying the real code underneath, so the top level alone identifies it
    /// on the plain-start path only.
    nonisolated static func isVirtualMachineLimitExceeded(_ error: Error) -> Bool {
        underlyingErrorChain(error as NSError).contains {
            $0.domain == VZError.errorDomain
                && VZError.Code(rawValue: $0.code) == .virtualMachineLimitExceeded
        }
    }

    /// `domain code` for each error *under* `error`, bounded by
    /// ``maxUnderlyingErrorDepth``; `"none"` when nothing is nested.
    static func underlyingChainDescription(_ error: NSError) -> String {
        let nested = underlyingErrorChain(error).dropFirst()
        guard !nested.isEmpty else { return "none" }
        return nested.map { "\($0.domain) \($0.code)" }.joined(separator: " → ")
    }

    /// `error` followed by up to ``maxUnderlyingErrorDepth`` of its
    /// `NSUnderlyingErrorKey` ancestors.
    nonisolated private static func underlyingErrorChain(_ error: NSError) -> [NSError] {
        var chain: [NSError] = []
        var current: NSError? = error
        while let nsError = current, chain.count <= maxUnderlyingErrorDepth {
            chain.append(nsError)
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    /// `true` when `error` is a failed save-file restore — the one start/resume
    /// failure that rests at cold-paused instead of `.error` or `.stopped`.
    static func isRestoreFailure(_ error: Error) -> Bool {
        guard let virtualizationError = error as? VirtualizationError,
            case .restoreFailed = virtualizationError
        else { return false }
        return true
    }

    /// `error` with one `restoreFailed` wrapper peeled off, so the contention
    /// and transience classifiers can read the VZ failure underneath.
    static func unwrappedRestoreFailure(_ error: Error) -> Error {
        guard let virtualizationError = error as? VirtualizationError,
            case .restoreFailed(let underlying) = virtualizationError
        else { return error }
        return underlying
    }

    // MARK: - Private Helpers

    /// Builds a VZ configuration off the main actor to avoid blocking the UI,
    /// first creating the EFI variable store an EFI boot reads when the bundle
    /// holds none.
    private func buildConfiguration(
        for instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> ConfigurationBuilder.BuildResult {
        let builder = configBuilder
        let config = instance.effectiveConfiguration
        let bundleURL = context.bundle.url
        if config.bootMode == .efi {
            try await context.bundle.ensureEFIVariableStore()
        }
        return try await Task.detached {
            try builder.build(from: config, bundleURL: bundleURL)
        }.value
    }

    /// Builds a `VZVirtualMachine`, restores from a save file, and resumes,
    /// retrying with bounded backoff when the attempt fails on VZ file-lock
    /// contention (see ``isFileLockContention(_:)``) — the restore-path
    /// counterpart of
    /// ``coldBootRetryingLockContention(_:_:bootIntoRecovery:provisioning:)``.
    ///
    /// A restore or resume failure surfaces as
    /// ``VirtualizationError/restoreFailed(underlying:)`` with the save file
    /// left in place — a cold boot over a suspended session destroys it, so
    /// discarding the saved state stays an explicit user action.
    private func restoreFromSaveFile(
        _ instance: VMInstance, _ context: borrowing VMBringUpContext
    ) async throws {
        var attempt = 0
        while true {
            do {
                try await restoreFromSaveFileAttempt(instance, context)
                return
            } catch let attemptError {
                guard Self.isFileLockContention(Self.unwrappedRestoreFailure(attemptError)),
                    let delay = Self.fileLockRetryDelay(forAttempt: attempt)
                else { throw attemptError }
                attempt += 1
                #log(
                    Self.logger, .warning,
                    "Restore of '\(instance.name, privacy: .public)' hit file-lock contention; retry \(attempt, privacy: .public) in \(String(describing: delay), privacy: .public)"
                )
                context.operation.endSession()
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    // Cancelled mid-backoff: surface the original lock failure
                    // rather than leak a `CancellationError` into the status/alert
                    // classification paths, which aren't shaped for it.
                    throw attemptError
                }
            }
        }
    }

    /// One restore attempt: build, attach, restore, resume. A configuration
    /// build failure propagates as-is (the caller's attachment explainers match
    /// on it); a restore or resume failure is wrapped in `restoreFailed`.
    private func restoreFromSaveFileAttempt(
        _ instance: VMInstance, _ context: borrowing VMBringUpContext
    ) async throws {
        instance.beginSessionContext(context)
        let result = try await buildConfiguration(for: instance, context.operation)
        guard let session = await instance.bringUpSession(context, with: result) else {
            throw VirtualizationError.noVirtualMachine
        }
        try await Self.restoreSavedState(instance, context.operation, session: session)
    }

    /// Loads the bundle's suspend slot into `session`, resumes the guest, and
    /// drops the slot, over the VZ operations it needs rather than a concrete
    /// session — like ``save(_:_:session:)``, so the slot it reads and the one
    /// it drops are reachable without a real `VZVirtualMachine`.
    static func restoreSavedState(
        _ instance: VMInstance, _ context: borrowing VMOperationContext,
        session: any VMSnapshotSessionOperating
    ) async throws {
        #log(logger, .debug, "restoreFromSaveFile: attempting restore from save file")
        do {
            try await session.restoreMachineState(from: context.bundle.saveFileURL)
            try await session.resume()
            context.bundle.removeSaveFile()
        } catch {
            let nsError = error as NSError
            #log(
                logger, .error,
                "Restore failed for VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public); underlying: \(underlyingChainDescription(nsError), privacy: .public)]"
            )
            throw VirtualizationError.restoreFailed(underlying: error)
        }
    }
}

// MARK: - VirtualizationProviding

extension VirtualizationService: VirtualizationProviding {}

// MARK: - Errors

enum VirtualizationError: LocalizedError {
    case invalidStateTransition(from: VMStatus, action: String)
    case noVirtualMachine
    case noSaveFile
    /// The file system turned the removal of the suspend slot down, so the VM
    /// is still resting on the session the discard was asked to end.
    case savedStateNotDiscarded
    case restoreFailed(underlying: any Error)
    /// The revert wrote the snapshot back, and bringing the VM up on it failed.
    case revertResumeFailed(underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .invalidStateTransition(let status, let action):
            "Cannot \(action) VM in \(status.displayName) state."
        case .noVirtualMachine:
            "No virtual machine instance is available."
        case .noSaveFile:
            "No saved state file found."
        case .savedStateNotDiscarded:
            // The VM still holds the session, so it is still offered — nothing
            // was lost, and the same command is the way to try again.
            "The saved state could not be deleted."
        case .restoreFailed(let underlying):
            // States what is known and stops. Nothing here can tell whether a
            // second attempt would fare better — after the device set has
            // diverged from the one the state was written with, none ever will
            // — and which commands the VM offers is its own state's answer.
            "Could not restore the saved state: \(underlying.localizedDescription)\n\n"
                + "The saved state was kept."
        case .revertResumeFailed(let underlying):
            "The virtual machine was reverted to the snapshot, but it could not be "
                + "resumed: \(underlying.localizedDescription)\n\n"
                + "The reverted state was kept — choose Resume to try again."
        }
    }
}

/// Bridges a wrapped underlying error into `NSUnderlyingErrorKey` so the
/// chain-walking classifiers (`isVirtualMachineLimitExceeded`,
/// `underlyingChainDescription`) see through the wrapper.
extension VirtualizationError: CustomNSError {
    var errorUserInfo: [String: Any] {
        switch self {
        case .restoreFailed(let underlying), .revertResumeFailed(let underlying):
            [NSUnderlyingErrorKey: underlying as NSError]
        default:
            [:]
        }
    }
}
