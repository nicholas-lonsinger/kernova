import Foundation
import KernovaCommandModel
import KernovaCore
import KernovaKit
import KernovaLogging
import Virtualization

/// Manages VM lifecycle operations: start, stop, pause, resume, save, and restore.
///
/// Stays on the main actor because it mutates `VMInstance`; every
/// `VZVirtualMachine` touch goes through the instance's `VMSession`, the VM's
/// own isolation domain on its private queue.
@MainActor
package final class VirtualizationService {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VirtualizationService")

    private let configBuilder: ConfigurationBuilder

    /// The guest agents this build bundles, whose installer disk a configuration may carry.
    private let guestAgents: BundledGuestAgents

    /// Whether this Mac's protected data is readable right now — `false` while
    /// the user is locked out — which a failed restore reports alongside its
    /// error.
    private let isProtectedDataAvailable: @MainActor () -> Bool

    package init(
        vmnetNetworks: VmnetNetworkService, vmnetAttachments: VmnetAttachmentMaker,
        bridgedInterfaces: any BridgedInterfaceProviding, entitlements: EntitlementService,
        guestAgents: BundledGuestAgents, isProtectedDataAvailable: @escaping @MainActor () -> Bool
    ) {
        configBuilder = ConfigurationBuilder(
            bridgedInterfaces: bridgedInterfaces, vmnetNetworks: vmnetNetworks,
            vmnetAttachments: vmnetAttachments, entitlements: entitlements, guestAgents: guestAgents)
        self.guestAgents = guestAgents
        self.isProtectedDataAvailable = isProtectedDataAvailable
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
    package func start(
        _ instance: VMInstance, _ context: borrowing VMGuestStartContext,
        provisioning: GuestProvisioningCredentials?
    ) async throws -> VMOperationEnding<GuestStartRoute> {
        let route = GuestStartRoute(context.kind)
        let hasSaveFile = context.bringUp.operation.bundle.hasSaveFile
        Self.logger.log(
            .debug,
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
            if !VirtualizationFailure.isRestoreFailure(error) {
                let nsError = error as NSError
                Self.logger.log(
                    .error,
                    "Failed to start VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public); underlying: \(VirtualizationFailure.underlyingChainDescription(nsError), privacy: .public)]"
                )
            }
            throw error
        }
        switch route {
        case .recoveryBoot:
            Self.logger.log(
                .notice,
                "Started VM '\(instance.name, privacy: .public)' in recovery mode")
        case .coldBoot, .restoredSavedState:
            Self.logger.log(.notice, "Started VM '\(instance.name, privacy: .public)'")
        }
        // A session that went away between VZ reporting the machine up and
        // here rests the VM where its end says; the route still answers,
        // because the guest did come up.
        return .rest(.live(.running), route)
    }

    // MARK: - Cold Boot

    /// Cold-boots `instance`, retrying with bounded backoff when the start fails on
    /// VZ file-lock contention (see ``VirtualizationFailure/isFileLockContention(_:)``).
    ///
    /// The contention it answers is this copy's own: a previous `VZVirtualMachine`
    /// on the same bundle releases its advisory lock on the auxiliary-storage and
    /// disk-image files only when fully *deallocated*, which lags
    /// `vm.state == .stopped` by more the more guest memory there is to tear down.
    /// No public VZ API observes the release, so gating on state cannot be
    /// airtight; a bounded retry against the ground-truth failure is. Another
    /// copy of Kernova running the VM holds the same files, but the bundle's run
    /// lock refuses that bring-up at admission, before VZ is asked.
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
                guard VirtualizationFailure.isFileLockContention(startError),
                    let delay = Self.fileLockRetryDelay(forAttempt: attempt)
                else { throw startError }
                attempt += 1
                Self.logger.log(
                    .warning,
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
        let result = try await buildConfiguration(
            try instance.coldBootConfiguration(context), context.operation)
        guard let session = await instance.bringUpSession(context, with: result) else {
            throw VirtualizationError.noVirtualMachine
        }
        try await context.operation.executingGuest { execution in
            // Made here, so the options are sent to the session from the one
            // region that holds them.
            let startOptions = MacOSGuestProvisioning.macOSStartOptions(
                bootIntoRecovery: bootIntoRecovery, guestOS: instance.configuration.guestOS,
                provisioning: provisioning)
            try await session.start(options: startOptions, execution: execution)
        }
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
    package func requestStop(_ instance: VMInstance) async throws {
        guard let session = instance.session else { throw VirtualizationError.noVirtualMachine }
        do {
            try await session.requestStop()
            Self.logger.log(.notice, "Requested stop for VM '\(instance.name, privacy: .public)'")
        } catch {
            Self.logger.log(
                .error,
                "Failed to stop VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    /// Terminates the live guest where it stands.
    package func forceStop(_ instance: VMInstance) async throws {
        guard let session = instance.session else { throw VirtualizationError.noVirtualMachine }
        do {
            try await session.stop()
            Self.logger.log(.notice, "Force-stopped VM '\(instance.name, privacy: .public)'")
        } catch {
            Self.logger.log(
                .error,
                "Failed to force-stop VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - Pause / Resume

    package func pause(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        guard let session = context.session else { throw VirtualizationError.noVirtualMachine }
        do {
            try await session.pause()
        } catch {
            // The VM stays where it was, still holding the session, with Stop,
            // Force Stop and a retried Pause all offered; the failure reaches
            // the user as the thrown error.
            Self.logger.log(
                .error,
                "Failed to pause VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        // The grace clock only means something while the guest is executing
        // — a frozen guest cannot say Hello, so letting it run would blame
        // the agent for the pause.
        instance.cancelAgentPostStartWatchdog()
        Self.logger.log(.notice, "Paused VM '\(instance.name, privacy: .public)'")
        return .rest(.live(.paused), ())
    }

    /// Resumes a live-paused guest from memory.
    package func resume(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        guard let session = context.session else { throw VirtualizationError.noVirtualMachine }
        do {
            try await session.resume(context.liveExecution())
        } catch {
            Self.logger.log(
                .error,
                "Failed to resume VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        Self.logger.log(.notice, "Resumed VM '\(instance.name, privacy: .public)'")
        return .rest(.live(.running), ())
    }

    // MARK: - Save

    /// Writes the guest's state to the bundle's suspend slot (pause, then
    /// save) and ends the session.
    package func save(
        _ instance: VMInstance, _ context: borrowing VMOperationContext
    ) async throws -> VMOperationEnding<Void> {
        guard let session = context.session else { throw VirtualizationError.noVirtualMachine }
        return try await Self.save(instance, context, session: session)
    }

    /// ``save(_:_:)`` over the VZ operations it needs rather than a concrete
    /// session — like ``captureWarmSnapshot(_:_:snapshot:session:)``, so the
    /// slot it drops when the write fails or the guest goes away under it is
    /// reachable without a real `VZVirtualMachine`.
    package static func save(
        _ instance: VMInstance, _ context: borrowing VMOperationContext,
        session: any VMSnapshotSessionOperating
    ) async throws -> VMOperationEnding<Void> {
        guard context.sessionID != nil else { throw VirtualizationError.noVirtualMachine }
        do {
            try await VMLiveStateCapture.suspendState(context, session: session, to: context.bundle.saveFileURL)
        } catch let refusal as VMLiveStateCapture.SaveRefusal {
            // Refused before anything was touched: the guest runs on, and the
            // slot is as it was.
            return .failed(.asStarted, refusal)
        } catch {
            logger.log(
                .error,
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
            logger.log(
                .notice,
                "VM '\(instance.name, privacy: .public)' lost its session mid-suspend — its partial saved state was dropped"
            )
            return .rest(.afterSessionEnd, ())
        }
        // No sidecar metadata is needed beside the save file: removable media
        // carry stable UUIDs and storage disks stable virtio block identifiers
        // in `config`, and VZ matches both on restore.
        context.parkedSession()
        context.endSession()
        logger.log(.notice, "Saved state for VM '\(instance.name, privacy: .public)'")
        return .rest(.atRest(.stopped), ())
    }

    // MARK: - Snapshots

    /// Captures `snapshot` in the mode the capture operation was admitted in:
    /// a live capture writes the guest's memory into the snapshot's own saved
    /// state and copies the bundle's disks beside it, a suspended capture
    /// clones the bundle's suspend slot beside the disk copies, and a stopped
    /// capture copies the disks with no saved state. Every mode records the
    /// VM's configuration beside them.
    ///
    /// A live capture pauses the guest for the write and puts it back the way it
    /// was found, so the VM keeps running across a snapshot — and the suspend
    /// slot is untouched either way. A failure discards the half-written
    /// snapshot directory and leaves the VM where it was: live, paused at
    /// worst, or at rest.
    package func takeSnapshot(
        _ instance: VMInstance, _ context: borrowing VMCaptureContext,
        snapshot request: VMSnapshotCaptureRequest
    ) async throws -> VMOperationEnding<VMSnapshot> {
        let mode = context.mode
        Self.logger.log(
            .debug,
            "takeSnapshot: mode=\(String(describing: mode), privacy: .public), status=\(instance.status.displayName, privacy: .public)"
        )
        let snapshot = request.record(capturedIn: mode)
        switch mode {
        case .live:
            guard let session = context.operation.session else {
                throw VirtualizationError.noVirtualMachine
            }
            return try await Self.captureWarmSnapshot(
                instance, context, snapshot: request, session: session)
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
        _ instance: VMInstance, _ capture: borrowing VMCaptureContext,
        snapshot request: VMSnapshotCaptureRequest, session: any VMSnapshotSessionOperating
    ) async throws -> VMOperationEnding<VMSnapshot> {
        guard capture.operation.sessionID != nil else { throw VirtualizationError.noVirtualMachine }
        let snapshot = request.record(capturedIn: .live)
        let configuration = instance.configuration
        let snapshotID = snapshot.id

        let captured = await VMLiveStateCapture.captureWarm(
            instance, capture, session: session,
            prepare: {
                try await capture.operation.bundle.prepareSnapshot(
                    snapshotID, configuration: configuration)
            },
            savingStateTo: { $0.saveFileURL },
            copy: { prepared in
                try await capture.operation.bundle.captureDisks(
                    intoSnapshot: snapshotID, relativePaths: prepared.relativePaths)
            })
        let rest: VMOperationRest
        switch captured {
        case .failed(let failedRest, let error):
            await capture.operation.bundle.removeSnapshotDirectory(snapshotID)
            logger.log(
                .error,
                "Failed to snapshot VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return .failed(failedRest, error)
        case .rest(let capturedRest, ()):
            rest = capturedRest
        }

        if capture.operation.sessionID == nil {
            // The guest went away while its disks were copied. The saved state
            // and the disks were both written before that happened, so the
            // snapshot is complete and the caller records it.
            logger.log(
                .notice,
                "Took snapshot '\(snapshot.name, privacy: .public)' of VM '\(instance.name, privacy: .public)', which lost its session mid-capture"
            )
        } else {
            logger.log(
                .notice,
                "Took snapshot '\(snapshot.name, privacy: .public)' of VM '\(instance.name, privacy: .public)'"
            )
        }
        return .rest(rest, VMSnapshot(snapshot, network: VMCapturedNetwork(configuration)))
    }

    /// Copies a live VM into a clone through ``VMLiveStateCapture/captureWarm(_:_:session:prepare:savingStateTo:copy:)``:
    /// `prepare` lays down the clone's staged bundle, and `copy` copies the
    /// files the saved state restores onto into it inside the pause that
    /// writes the guest's memory to `saveFileURL` first.
    package func copyLive(
        _ instance: VMInstance, _ context: borrowing VMCaptureContext,
        savingStateTo saveFileURL: URL,
        prepare: () async throws -> Void,
        copy: () async throws -> Void
    ) async throws -> VMOperationEnding<Void> {
        guard let session = context.operation.session else {
            throw VirtualizationError.noVirtualMachine
        }
        let ending = await VMLiveStateCapture.captureWarm(
            instance, context, session: session, prepare: prepare,
            savingStateTo: { saveFileURL }, copy: copy)
        switch ending {
        case .failed(_, let error):
            Self.logger.log(
                .error,
                "Failed to clone running VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        case .rest:
            Self.logger.log(
                .notice,
                "Copied running VM '\(instance.name, privacy: .public)' into a clone"
            )
        }
        return ending
    }

    /// The bundle's disks and the VM's configuration, from a stopped VM — no VZ
    /// work, so nothing is paused and no saved state is written.
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
            Self.logger.log(
                .error,
                "Failed to snapshot VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        Self.logger.log(
            .notice,
            "Took a cold snapshot '\(snapshot.name, privacy: .public)' of stopped VM '\(instance.name, privacy: .public)'"
        )
        return .rest(.asStarted, VMSnapshot(snapshot, network: VMCapturedNetwork(configuration)))
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
            Self.logger.log(
                .error,
                "Failed to snapshot VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        Self.logger.log(
            .notice,
            "Took a suspended-state snapshot '\(snapshot.name, privacy: .public)' of VM '\(instance.name, privacy: .public)'"
        )
        return .rest(.asStarted, VMSnapshot(snapshot, network: VMCapturedNetwork(configuration)))
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
    package func revertToSnapshot(
        _ instance: VMInstance, _ context: borrowing VMRevertContext,
        commitConfiguration: @MainActor (borrowing VMEditPermit, VMSnapshotRestorePlan) throws -> Void
    ) async throws -> VMOperationEnding<Void> {
        let snapshot = context.snapshot
        Self.logger.log(
            .debug,
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
                Self.logger.log(
                    .warning,
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
                try commitConfiguration(context.bringUp.operation.permit, plan)
            } catch {
                await context.bringUp.operation.bundle.discardRestoreStaging()
                throw error
            }
            try await context.bringUp.operation.bundle.installRestore(plan)
        } catch {
            Self.logger.log(
                .error,
                "Failed to revert VM '\(instance.name, privacy: .public)' to '\(snapshot.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return .failed(.atRest(.stopped), error)
        }
        Self.logger.log(
            .notice,
            "Reverted VM '\(instance.name, privacy: .public)' to snapshot '\(snapshot.name, privacy: .public)'"
        )

        // A warm revert leaves the snapshot's saved state in the bundle and a
        // cold one leaves none, so the write that just landed is what says
        // where the VM rests — unless the revert goes back to being live at
        // the captured state, which only a warm snapshot captured.
        guard context.resumesAfter, plan.kind == .warm else { return .rest(.atRest(.stopped), ()) }
        // Landed before the resume marks the session it starts, so a resume
        // that fails retracts to files that have landed.
        context.bringUp.operation.filesLanded()
        do {
            try await restoreFromSaveFile(instance, context.bringUp)
        } catch {
            return .failed(.atRest(.stopped), VirtualizationError.revertResumeFailed(underlying: error))
        }
        return .rest(.live(.running), ())
    }

    // MARK: - Private Helpers

    /// Builds `config` into a VZ configuration, first making the VM's copy of
    /// each installer disk it attaches that the bundle lacks and creating the
    /// EFI variable store an EFI boot reads when the bundle holds none.
    private func buildConfiguration(
        _ config: VMConfiguration, _ context: borrowing VMOperationContext
    ) async throws -> sending ConfigurationBuilder.BuildResult {
        try await GuestAgentDiskCopies.ensure(
            for: config, in: VMBundleLayout(bundleURL: context.bundle.url), agents: guestAgents)
        if config.bootMode == .efi {
            try await context.bundle.ensureEFIVariableStore()
        }
        return try await configBuilder.build(from: config, bundleURL: context.bundle.url)
    }

    /// Builds a `VZVirtualMachine`, restores from a save file, and resumes,
    /// retrying with bounded backoff when the attempt fails on VZ file-lock
    /// contention (see ``VirtualizationFailure/isFileLockContention(_:)``) — the restore-path
    /// counterpart of
    /// ``coldBootRetryingLockContention(_:_:bootIntoRecovery:provisioning:)``,
    /// answering the same teardown lag.
    ///
    /// A restore or resume failure surfaces as
    /// ``VirtualizationError/restoreFailed(underlying:hostLocked:)`` with the save file
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
                guard
                    VirtualizationFailure.isFileLockContention(
                        VirtualizationFailure.unwrappedRestoreFailure(attemptError)),
                    let delay = Self.fileLockRetryDelay(forAttempt: attempt)
                else { throw attemptError }
                attempt += 1
                Self.logger.log(
                    .warning,
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
        let result = try await buildConfiguration(instance.effectiveConfiguration, context.operation)
        guard let session = await instance.bringUpSession(context, with: result) else {
            throw VirtualizationError.noVirtualMachine
        }
        try await Self.restoreSavedState(
            instance, context.operation, session: session,
            isProtectedDataAvailable: isProtectedDataAvailable)
    }

    /// Loads the bundle's suspend slot into `session` and resumes the guest,
    /// whose execution spends the slot (``VMOperationContext/executingGuest(_:)``),
    /// over the VZ operations it needs rather than a concrete session — like
    /// ``save(_:_:session:)``, so tests reach it without a real
    /// `VZVirtualMachine`.
    static func restoreSavedState(
        _ instance: VMInstance, _ context: borrowing VMOperationContext,
        session: any VMSnapshotSessionOperating,
        isProtectedDataAvailable: @MainActor () -> Bool
    ) async throws {
        logger.log(.debug, "restoreFromSaveFile: attempting restore from save file")
        do {
            try await session.restoreMachineState(from: context.bundle.saveFileURL)
            try await context.executingGuest { execution in try await session.resume(execution) }
        } catch {
            let nsError = error as NSError
            let hostLocked = !isProtectedDataAvailable()
            logger.log(
                .error,
                "Restore failed for VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public) [\(nsError.domain, privacy: .public) \(nsError.code, privacy: .public); underlying: \(VirtualizationFailure.underlyingChainDescription(nsError), privacy: .public); host locked: \(hostLocked, privacy: .public)]"
            )
            throw VirtualizationError.restoreFailed(underlying: error, hostLocked: hostLocked)
        }
    }
}

// MARK: - VirtualizationProviding

extension VirtualizationService: VirtualizationProviding {}
