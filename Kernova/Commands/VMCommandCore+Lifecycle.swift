import Foundation
import KernovaKit

/// The lifecycle verbs: everything that moves a VM between resting and
/// running, plus the guest-setup pipelines a first start owes.
extension VMCommandCore {
    // MARK: - Start

    func start(_ selector: VMSelector, recovery: Bool) async throws {
        try await start(try resolve(selector), recovery: recovery)
    }

    /// The start every surface reaches, with the instance already resolved.
    func start(_ instance: VMInstance, recovery: Bool = false) async throws {
        try require(.start, on: instance)
        if recovery, !capabilities.accepts(.startInRecovery, on: instance) {
            throw CommandError.unsupported(capability: "starting in macOS Recovery")
        }

        // Ahead of the setup dispatch: guest setup builds and runs a
        // `VZVirtualMachine` carrying the configured machine identity and MAC
        // address, so a conflicting one must be refused before it reaches the
        // installer, not only on the auto-boot that follows.
        try refuseDuplicateIdentity(instance)

        // Dispatch on the surviving setup context, not status, so `.error`
        // retries route through the same pipeline too.
        if instance.configuration.installContext != nil {
            installAndAutoBoot(instance)
            return
        }
        if instance.configuration.linuxInstallContext != nil {
            downloadAndAutoBoot(instance)
            return
        }

        surfaceDisplay?(instance)
        applyMatchWindowBootResolution(to: instance)
        do {
            try await lifecycle.start(instance, bootIntoRecovery: recovery)
        } catch {
            throw startFailure(error, on: instance)
        }
    }

    // MARK: - Duplicate Identity

    /// Refuses an operation that would put a second guest on an identity
    /// another live VM already claims.
    private func refuseDuplicateIdentity(_ instance: VMInstance) throws {
        if preferences.blockDuplicateMachineIDBoot,
            let conflict = liveMachineIDConflict(for: instance)
        {
            Self.logger.notice(
                "Refused to run '\(instance.name, privacy: .public)': shares a machine ID with active VM '\(conflict.name, privacy: .public)'"
            )
            throw CommandError.conflict(
                vm: summary(instance), with: summary(conflict), reason: .machineIdentity)
        }
        if let conflict = library.liveMACAddressConflict(
            for: instance.configuration, excluding: instance),
            let mac = instance.configuration.macAddress
        {
            Self.logger.notice(
                "Refused to run '\(instance.name, privacy: .public)': shares the MAC address \(mac, privacy: .public) with active VM '\(conflict.name, privacy: .public)'"
            )
            throw CommandError.conflict(
                vm: summary(instance), with: summary(conflict), reason: .macAddress)
        }
    }

    /// The first VM holding a live machine identity matching `instance`'s.
    ///
    /// Live means VZ holds the identity: any active status, or paused with the
    /// virtual machine still in memory. A cold-paused VM has released it, and
    /// blocking its twin on a saved state that claims nothing would be wrong.
    private func liveMachineIDConflict(for instance: VMInstance) -> VMInstance? {
        library.instances.first { other in
            other !== instance
                && (other.isActive || other.isLivePaused)
                && Self.sharesMachineIdentifier(instance, other)
        }
    }

    /// Whether two VMs would claim the same machine identity.
    ///
    /// macOS identifiers compare the *effective* value, which falls back to the
    /// bundle's identifier file exactly as the boot path does; generic
    /// identifiers have no such file, so they compare configuration fields.
    private static func sharesMachineIdentifier(_ a: VMInstance, _ b: VMInstance) -> Bool {
        if let lhs = a.effectiveMachineIdentifierData, let rhs = b.effectiveMachineIdentifierData,
            lhs == rhs
        {
            return true
        }
        if let lhs = a.configuration.genericMachineIdentifierData,
            let rhs = b.configuration.genericMachineIdentifierData,
            lhs == rhs
        {
            return true
        }
        return false
    }

    // MARK: - Boot Geometry

    /// Resizes a cold-booting VM's display to the surface it is about to appear
    /// on, persisting the result before the VZ configuration is built.
    ///
    /// Left alone when a save file exists: VZ restores only into a configuration
    /// identical to the saved one, and a mismatch fails the restore.
    private func applyMatchWindowBootResolution(to instance: VMInstance) {
        guard instance.configuration.displaySizesToWindow, !instance.hasSaveFile else { return }
        guard let surface = displayBootGeometryProvider?.displayBootSurface(for: instance) else {
            Self.logger.notice(
                "No measurable display surface for '\(instance.name, privacy: .public)' — booting at the configured resolution"
            )
            return
        }
        let hiDPI =
            instance.configuration.guestOS.supportsDisplayDensity
            && instance.configuration.displayHiDPI
        let scale = hiDPI ? surface.backingScaleFactor : 1
        let resolution = DisplayBootSizing.resolution(
            fittingPoints: surface.pointSize, backingScaleFactor: scale)
        let previous = instance.configuration
        if !library.updateConfiguration(of: instance, mutate: { $0.displayResolution = resolution }) {
            // Assigned directly rather than through the funnel: disk still holds
            // `previous`, so re-persisting it is a second chance to fail.
            instance.configuration = previous
            Self.logger.warning(
                "Could not persist the window-fitted resolution for '\(instance.name, privacy: .public)' — booting at the previously saved resolution"
            )
        }
    }

    // MARK: - Start Failure

    /// Turns a start failure into the refusal a surface renders: the removable
    /// attachment when one is at fault, the explained capacity message when the
    /// VM limit is, else the raw error.
    private func startFailure(_ error: Error, on instance: VMInstance) -> CommandError {
        Self.logger.error(
            "Failed to start '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
        )
        if case VMLifecycleCoordinator.LifecycleError.operationInProgress = error {
            return failure(error, verb: .start, on: instance)
        }
        if let failure = startFailedAttachment(from: error, on: instance) {
            return .operationFailed(
                verb: .start, message: error.localizedDescription,
                recovery: .removeStartFailedAttachment(failure))
        }
        if let explained = explainedFailure(for: error, on: instance) {
            return .operationFailed(
                verb: .start, title: explained.title, message: explained.message)
        }
        return .operationFailed(verb: .start, message: error.localizedDescription)
    }

    /// Maps a start error to a ``StartFailedAttachment`` when it identifies an
    /// attachment the user can remove to get the VM running, or `nil` when the
    /// generic error is the right surface.
    ///
    /// Two exclusions where removal is the wrong advice: the disk the guest boots
    /// from, and file-lock contention — the file is fine and the lock holder is a VM
    /// still tearing down, so the fix is to wait and retry.
    private func startFailedAttachment(
        from error: Error, on instance: VMInstance
    ) -> StartFailedAttachment? {
        guard let builderError = error as? ConfigurationBuilderError,
            !VirtualizationService.isFileLockContention(builderError)
        else { return nil }
        switch builderError {
        case .storageDiskAttachFailed(let id, _, let label, _):
            guard let disk = storageDisk(id: id, on: instance),
                !isMainDisk(disk, of: instance)
            else { return nil }
            return StartFailedAttachment(
                kind: .storageDisk, id: id, label: label,
                message: builderError.localizedDescription)
        case .removableMediaAttachFailed(let id, _, let label, _):
            // Confirm the entry is really in the list: an offer whose action could
            // only no-op leaves a button that appears to do nothing.
            guard (instance.configuration.removableMedia ?? []).contains(where: { $0.id == id })
            else { return nil }
            return StartFailedAttachment(
                kind: .removableMedia, id: id, label: label,
                message: builderError.localizedDescription)
        default:
            return nil
        }
    }

    /// Maps a start or install failure to copy naming the cause and the remedy,
    /// or `nil` when the raw error description is the right surface.
    private func explainedFailure(
        for error: Error, on instance: VMInstance
    ) -> (title: String, message: String)? {
        guard VirtualizationService.isVirtualMachineLimitExceeded(error) else { return nil }
        let verb: String
        switch instance.startAction {
        case .start: verb = "Start"
        case .install, .resumeInstall: verb = "Install"
        case .download, .resumeDownload: verb = "Download"
        }
        let message: String
        switch instance.configuration.guestOS {
        case .macOS:
            message =
                "macOS allows at most two macOS virtual machines to run at once. Stop another macOS VM, then click \(instance.startAction.label) to try again."
        case .linux:
            message =
                "The limit on running virtual machines has been reached. Stop another virtual machine, then click \(instance.startAction.label) to try again."
        }
        return (title: "Couldn't \(verb) \u{201C}\(instance.name)\u{201D}", message: message)
    }

    // MARK: - Guest Setup

    /// Runs a guest-setup pipeline for an `.initialBoot` (or `.error` with a
    /// surviving context) VM and, on success, chains an auto-boot.
    ///
    /// A permanent failure leaves the VM in `.error` so the banner keeps the
    /// message on screen; cancel and transient failures (the running-VM cap)
    /// return it to `.initialBoot` for a retry that resumes the download from
    /// the `.kernovadownload` bundle if present.
    private func runGuestSetup(
        on instance: VMInstance,
        _ pipeline: @escaping (VMLifecycleCoordinator) async throws -> Void
    ) {
        if instance.setupTask != nil { return }  // guard against rapid double-click
        instance.setupTask = Task { [weak self] in
            guard let self else { return }
            defer { instance.setupTask = nil }
            do {
                try await pipeline(self.lifecycle)
                // A cancel accepted while the pipeline was drawing to a close
                // still means the VM must not boot. Raised inside this `do` so
                // it takes the cancel branch below rather than falling through
                // into the chained start, and after the last suspension point
                // the pipeline has, so nothing can slip between the two.
                try Task.checkCancellation()
            } catch is CancellationError {
                // Tear down a VM the install attached before cancellation fired: a
                // retry would otherwise build a fresh `VZMacAuxiliaryStorage` while
                // the old one is still alive on `instance.session`.
                instance.tearDownSession(restingAt: .initialBoot)
                instance.setupState = nil
                Self.logger.notice(
                    "Setup cancelled for '\(instance.name, privacy: .public)' — VM remains in .initialBoot"
                )
                return
            } catch {
                // Same teardown reason as the cancel branch: an attached VM from a
                // partial install must not bleed into the next retry. The
                // pipeline classified its own failure into a resting phase, so
                // the teardown keeps that — unless a cancel raced the failure
                // (user intent was cancel, so drop the message and take no
                // dialog), or the throw came from before the classification and
                // the VM is still in an install phase naming its session.
                let classified = instance.phase
                let restingAtCancel = Task.isCancelled || classified.sessionID != nil
                instance.tearDownSession(restingAt: restingAtCancel ? .initialBoot : classified)
                instance.setupState = nil
                if Task.isCancelled {
                    Self.logger.notice(
                        "Setup cancelled for '\(instance.name, privacy: .public)' — pipeline surfaced \(error.localizedDescription, privacy: .public)"
                    )
                } else if let explained = self.explainedFailure(for: error, on: instance) {
                    self.report(
                        .operationFailed(
                            verb: .start, title: explained.title, message: explained.message),
                        on: instance)
                } else {
                    self.report(
                        .operationFailed(verb: .start, message: error.localizedDescription),
                        on: instance)
                }
                return
            }
            // Setup is done; the boot that follows is an ordinary start, and its
            // failure is reported the same way a direct one's is — including the
            // removable-attachment recovery, which a flattened title-and-message
            // into a plain alert.
            instance.setupState = nil
            // Cleared here, ahead of the trailing `defer`: the gate this backs
            // (`allowedVerbs`' `.cancelGuestSetup`, and the cancel refusal
            // itself) covers exactly the setup phase, not the boot chained
            // after it — a cancel landing in that window would answer `.ok`
            // while touching a task no longer doing anything cancellable.
            instance.setupTask = nil
            do {
                try await self.start(instance)
            } catch let failure as CommandError {
                self.report(failure, on: instance)
            } catch {
                self.report(
                    .operationFailed(verb: .start, message: error.localizedDescription),
                    on: instance)
            }
        }
    }

    /// Drives the macOS install pipeline for a VM carrying an `installContext`.
    private func installAndAutoBoot(_ instance: VMInstance) {
        guard let context = instance.configuration.installContext else {
            assertionFailure("installAndAutoBoot called without installContext")
            return
        }
        runGuestSetup(on: instance) { lifecycle in
            try await lifecycle.installMacOS(on: instance, context: context)
        }
    }

    /// Drives the Linux installer-image pipeline for a VM carrying a
    /// `linuxInstallContext`.
    private func downloadAndAutoBoot(_ instance: VMInstance) {
        guard let context = instance.configuration.linuxInstallContext else {
            assertionFailure("downloadAndAutoBoot called without linuxInstallContext")
            return
        }
        runGuestSetup(on: instance) { lifecycle in
            try await lifecycle.downloadLinuxImage(on: instance, context: context)
        }
    }

    /// Cancels the in-progress guest setup — a macOS install, or a Linux
    /// installer image being fetched or verified.
    ///
    /// The VM returns to `.initialBoot` so a subsequent Start can resume, and the
    /// bundle is preserved — this is the non-destructive cancel.
    func cancelGuestSetup(_ selector: VMSelector, confirmed: Bool) throws {
        let instance = try resolve(selector)
        try require(.cancelGuestSetup, on: instance)
        guard let task = instance.setupTask else { throw invalidState(instance) }
        guard confirmed else {
            throw CommandError.confirmationRequired(Self.cancelGuestSetupPrompt(instance))
        }
        Self.logger.info("Cancelling setup for '\(instance.name, privacy: .public)'")
        task.cancel()
        // `runGuestSetup`'s cancel catch owns the status transition and
        // `setupState` cleanup — don't duplicate it here.
    }

    /// The confirmation a guest-setup cancel raises, worded for the step
    /// running now: a download's progress resumes, an install restarts from
    /// the beginning (the image stays cached), a verify is simply redone.
    static func cancelGuestSetupPrompt(_ instance: VMInstance) -> ConfirmationPrompt {
        let title: String
        let message: String
        let confirmTitle: String
        let dismissTitle: String
        switch instance.setupState?.currentStep?.id {
        case .install:
            title = "Cancel Installation?"
            message =
                "The installation will restart from the beginning the next time you start the virtual machine. The downloaded macOS image is cached, so you won't need to download it again."
            confirmTitle = "Cancel Installation"
            dismissTitle = "Keep Installing"
        case .verify:
            title = "Cancel Verification?"
            message =
                "The downloaded image is kept, and it will be checked again the next time you start the virtual machine."
            confirmTitle = "Cancel Verification"
            dismissTitle = "Keep Verifying"
        case .download, nil:
            title = "Cancel Download?"
            message =
                "The download progress will be saved and resumed the next time you start the virtual machine."
            confirmTitle = "Cancel Download"
            dismissTitle = "Keep Downloading"
        }
        return ConfirmationPrompt(
            kind: .cancelGuestSetup, title: title, message: message, confirmTitle: confirmTitle,
            dismissTitle: dismissTitle)
    }

    // MARK: - Stop

    func stop(_ selector: VMSelector, disposition: StopDisposition, confirmed: Bool) async throws {
        try await stop(try resolve(selector), disposition: disposition, confirmed: confirmed)
    }

    func stop(
        _ instance: VMInstance, disposition: StopDisposition, confirmed: Bool
    ) async throws {
        try refuseIfPreparing(instance)
        switch disposition {
        case .graceful:
            // VZ rejects `requestStop()` on a paused VM ("Invalid virtual
            // machine state"), so a live-paused guest has to be resumed first
            // or terminated — which is a choice, not a detail.
            if instance.isLivePaused {
                guard confirmed else {
                    throw CommandError.confirmationRequired(Self.stopPausedPrompt(instance))
                }
                try await resumeThenShutDown(instance)
                return
            }
            // A suspended VM has no guest to send the request to, so this is not
            // a shutdown at all: it deletes the suspended session exactly as the
            // force path does, and an Ephemeral VM's rolls the disks back to the
            // baseline on top of that. It passes the gate alongside the VMs that
            // do take a shutdown, and asks the same consent the force path does
            // — which is also what the UI asks at every suspended Stop.
            try require(anyOf: [.stop, .discardSavedState], on: instance)
            guard confirmed || !instance.isColdPaused else {
                throw CommandError.confirmationRequired(Self.forceStopPrompt(instance))
            }
            if try await discardedSavedStateAsEphemeralRevert(instance) { return }
            do {
                try await lifecycle.stop(instance)
            } catch {
                throw failure(error, verb: .stop, on: instance)
            }
        case .resumeThenShutDown:
            try require(.resume, on: instance)
            try await resumeThenShutDown(instance)
        case .force:
            // No state gate: a force stop is the interrupt of last resort, and
            // the states it is *most* needed in are the ones no gate would
            // predict — a VM resting at `.error` with a live `VZVirtualMachine`
            // still attached is exactly what the termination fallback has to be
            // able to terminate.
            guard confirmed else {
                throw CommandError.confirmationRequired(Self.forceStopPrompt(instance))
            }
            if try await discardedSavedStateAsEphemeralRevert(instance) { return }
            do {
                try await lifecycle.forceStop(instance)
                Self.logger.notice("Force-stopped VM '\(instance.name, privacy: .public)'")
            } catch {
                throw failure(error, verb: .stop, on: instance)
            }
        }
    }

    /// Resumes a paused VM then requests a graceful ACPI shutdown.
    private func resumeThenShutDown(_ instance: VMInstance) async throws {
        do {
            try await lifecycle.resume(instance)
            try await lifecycle.stop(instance)
        } catch {
            Self.logger.error(
                "Failed to resume-and-stop '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw failure(error, verb: .stop, on: instance)
        }
    }

    /// The two-choice refusal a paused VM's graceful stop raises: confirming
    /// takes the graceful route the guest can only receive awake, and the
    /// alternative terminates it where it stands.
    static func stopPausedPrompt(_ instance: VMInstance) -> ConfirmationPrompt {
        ConfirmationPrompt(
            kind: .stopPaused,
            title: "Stop Paused Virtual Machine",
            message:
                "\"\(instance.name)\" is paused and cannot be shut down directly. Resume it to send a graceful shutdown, or force stop to terminate it immediately (any unsaved data inside the guest will be lost).",
            confirmTitle: "Resume and Shut Down",
            dismissTitle: "Cancel",
            alternatives: [ConfirmationAlternative(title: "Force Stop", disposition: .force)])
    }

    /// The refusal a force stop raises, worded for what it actually discards.
    static func forceStopPrompt(_ instance: VMInstance) -> ConfirmationPrompt {
        // A cold-paused ephemeral VM's discard is a revert to its baseline, so
        // the button names that outcome rather than the deletion it isn't.
        let ephemeralBaseline = instance.isColdPaused ? instance.ephemeralBaselineSnapshot : nil
        let message: String
        if let ephemeralBaseline {
            message =
                "\"\(instance.name)\" is ephemeral, so discarding its suspended session returns it to "
                + "\u{201C}\(ephemeralBaseline.name)\u{201D}. Everything changed inside the guest "
                + "during the session is discarded."
        } else if instance.isColdPaused {
            message =
                "\"\(instance.name)\" has its state saved to disk. Discarding will permanently delete the saved state."
        } else {
            message =
                "\"\(instance.name)\" will be immediately terminated. Any unsaved data inside the guest will be lost."
        }
        let confirmTitle: String
        if instance.isColdPaused {
            confirmTitle = ephemeralBaseline == nil ? "Discard" : "Revert to Baseline"
        } else {
            confirmTitle = "Force Stop"
        }
        // A paused VM routes through the stop-paused refusal instead, so
        // offering the graceful shutdown here would chain one onto the other.
        let alternatives =
            instance.canStop && instance.status != .paused
            ? [ConfirmationAlternative(title: "Shut Down", disposition: .graceful)]
            : []
        return ConfirmationPrompt(
            kind: .forceStop,
            title: instance.isColdPaused ? "Discard Saved State" : "Force Stop Virtual Machine",
            message: message,
            confirmTitle: confirmTitle,
            dismissTitle: "Cancel",
            alternatives: alternatives)
    }

    // MARK: - Pause / Resume / Suspend

    func pause(_ selector: VMSelector) async throws {
        let instance = try resolve(selector)
        try require(.pause, on: instance)
        do {
            try await lifecycle.pause(instance)
        } catch {
            Self.logger.error(
                "Failed to pause '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw failure(error, verb: .pause, on: instance)
        }
    }

    func resume(_ selector: VMSelector) async throws {
        let instance = try resolve(selector)
        try require(.resume, on: instance)

        // A cold resume builds a fresh VZVirtualMachine from the save file, so it
        // claims the machine identity — and puts its MAC address back on a
        // network — just as a cold boot does. A hot resume's live object already
        // holds both, and refusing would be refusing a VM its own identity.
        if instance.isColdPaused {
            try refuseDuplicateIdentity(instance)
        }

        surfaceDisplay?(instance)
        do {
            try await lifecycle.resume(instance)
        } catch {
            Self.logger.error(
                "Failed to resume '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw failure(error, verb: .resume, on: instance)
        }
    }

    func suspend(_ selector: VMSelector) async throws {
        try await suspend(try resolve(selector))
    }

    func suspend(_ instance: VMInstance) async throws {
        try require(.suspend, on: instance)
        do {
            try await lifecycle.save(instance)
        } catch {
            Self.logger.error(
                "Failed to save '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw failure(error, verb: .suspend, on: instance)
        }
    }

    // MARK: - Restart

    /// Shuts the guest down and starts it again once it has powered off.
    ///
    /// Composed rather than a VZ operation of its own, so it inherits every
    /// gate and refusal the two verbs already state. The wait for the power-off
    /// is unbounded, matching what a graceful shutdown means: a guest that
    /// refuses to shut down is not restarted behind the user's back.
    ///
    /// The wait outlasts `.stopped`, which arrives first: `resetToStopped()`
    /// settles the status and *then* fires the power-off hook, so an Ephemeral
    /// VM's baseline revert is registered a turn later — and starting into it
    /// would either be refused as busy or boot off disks the revert is still
    /// overwriting.
    ///
    /// Where the VM lands decides which verb brings it back up. A power-off
    /// normally lands it stopped, but an Ephemeral VM's baseline revert can hand
    /// it back suspended on the baseline's memory image, and that is the state
    /// the mode promises — so it is resumed rather than booted, and never waited
    /// on for a `.stopped` that is not coming.
    func restart(_ selector: VMSelector) async throws {
        let instance = try resolve(selector)
        try require(.restart, on: instance)
        try await stop(instance, disposition: .graceful, confirmed: true)
        await waitForObservedChange { [library] in
            !library.isBusy(instance) && !library.hasRevertInFlight(for: instance.id)
                && (instance.canStart || instance.canResume)
        }
        if instance.canStart {
            try await start(instance)
        } else {
            try await resume(.id(instance.id))
        }
    }

    // MARK: - Open

    func open(_ selector: VMSelector) throws {
        let instance = try resolve(selector)
        // An imported bundle carrying a save file rests its phantom `.paused`,
        // which reads as having a display while the copy is still writing —
        // and `allowedVerbs` offers a preparing row nothing but its cancel.
        try require(.open, on: instance)
        surfaceDisplay?(instance)
    }

    // MARK: - Storage Disk Lookup

    /// The storage disk `id` refers to, resolving the synthesized main disk
    /// when the VM has no explicit list.
    func storageDisk(id: UUID, on instance: VMInstance) -> StorageDisk? {
        instance.effectiveStorageDisks.first { $0.id == id }
    }

    /// `true` when `disk` is the VM's primary (boot) `Disk.asif`.
    ///
    /// Matches by bundle-relative path, so it stays correct on cloned VMs (whose
    /// disk ids are regenerated).
    func isMainDisk(_ disk: StorageDisk, of instance: VMInstance) -> Bool {
        ConfigurationBuilder.isMainBundleDisk(
            disk, layout: VMBundleLayout(bundleURL: instance.bundleURL))
    }
}
