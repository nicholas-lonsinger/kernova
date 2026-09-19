import Foundation
import KernovaKit
import KernovaLogging

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
        // Both phases a bring-up stands in: a boot with a save file leaves
        // `.starting` for `.restoringSavedState` before its first await.
        switch instance.phase {
        case .starting, .restoringSavedState:
            guard !recovery else {
                throw CommandError.busy(
                    vm: summary(instance), operation: instance.status.displayName.lowercased())
            }
            readyDisplay?(instance)
            return try await joinBringUp(instance, verb: .start) {
                bringUpFailure($0, verb: .start, on: instance)
            }
        default:
            break
        }
        if recovery, !capabilities.accepts(.startInRecovery, on: instance) {
            throw CommandError.unsupported(capability: "starting in macOS Recovery")
        }

        // Ahead of the setup dispatch: guest setup builds and runs a
        // `VZVirtualMachine` carrying the configured machine identity and MAC
        // address, so a conflicting one must be refused before it reaches the
        // installer, not only on the auto-boot that follows.
        try refuseDuplicateIdentity(instance)
        // Before the setup dispatch, so an install nobody answered for is
        // turned back rather than running and chaining a boot that is.
        let provisioning = try guestProvisioning(for: instance, recovery: recovery)

        // Dispatch on the surviving setup context, not status, so `.error`
        // retries route through the same pipeline too. The pipeline chains the
        // boot that spends the account, and reads the answer where this did.
        switch instance.configuration.pendingGuestSetup {
        case .macOSInstall(let context):
            installAndAutoBoot(instance, context: context)
            return
        case .linuxImageDownload(let context):
            downloadAndAutoBoot(instance, context: context)
            return
        case nil:
            break
        }

        // Before the boot geometry is applied: a pop-out VM's window is what
        // `displayBootSurface` measures, and readying is what opens it.
        readyDisplay?(instance)
        applyMatchWindowBootResolution(to: instance)
        let route: GuestStartRoute
        do {
            route = try await lifecycle.start(
                instance, bootIntoRecovery: recovery, provisioning: provisioning)
        } catch {
            throw bringUpFailure(error, verb: .start, on: instance)
        }
        // The cold boot is the one that spent the window, whether or not it
        // carried an account: the other two routes never reach the one boot
        // `GuestStartRoute.deliversGuestProvisioning` names.
        if route == .coldBoot { library.retractGuestAccount(for: instance) }
    }

    // MARK: - Joining a Bring-Up

    /// Waits out the bring-up already in flight for `instance` and answers with
    /// what that bring-up answered its own caller.
    ///
    /// `refusal` is the verb's own error mapping, so a joined failure carries
    /// the removable attachment or the capacity explanation the direct caller
    /// gets rather than a second, blander rendering — a transient failure rests
    /// the VM at `.stopped` with no message at all, so the phase cannot supply
    /// one.
    ///
    /// The wait is on the operation still running its body, not on the claim: a
    /// cold boot retrying VZ file-lock contention rests at
    /// ``VMLifecyclePhase/starting(sessionID:)`` with no session between
    /// attempts, and a claim that `stop` released is not an operation that has
    /// finished.
    private func joinBringUp(
        _ instance: VMInstance, verb: VMVerb, refusal: (any Error) -> CommandError
    ) async throws {
        #log(
            Self.logger, .notice,
            "Joining the bring-up already in flight for '\(instance.name, privacy: .public)'")
        if case .failed(let error) = await lifecycle.awaitSettledOutcome(for: instance.id) {
            throw refusal(error)
        }
        // Reached when the bring-up reported success but the VM is not live —
        // its session was released before the start settled, which rests the VM
        // and reports nothing to a caller that was not waiting.
        guard instance.hasLiveSession else {
            let state = instance.status.displayName.lowercased()
            let message =
                instance.phase.errorMessage
                ?? "The operation already under way left '\(instance.name)' \(state)."
            #log(
                Self.logger, .error,
                "Joined bring-up of '\(instance.name, privacy: .public)' did not leave it running: \(message, privacy: .public)"
            )
            throw CommandError.operationFailed(verb: verb, message: message)
        }
    }

    // MARK: - Duplicate Identity

    /// Refuses an operation that would put a second guest on an identity
    /// another live VM already claims.
    private func refuseDuplicateIdentity(_ instance: VMInstance) throws {
        if preferences.blockDuplicateMachineIDBoot,
            let conflict = liveMachineIDConflict(for: instance)
        {
            #log(
                Self.logger, .notice,
                "Refused to run '\(instance.name, privacy: .public)': shares a machine ID with active VM '\(conflict.name, privacy: .public)'"
            )
            throw CommandError.conflict(
                vm: summary(instance), with: summary(conflict), reason: .machineIdentity)
        }
        if let conflict = library.networkSlots.liveMACAddressConflict(
            for: instance.configuration, excluding: instance),
            let mac = instance.configuration.macAddress
        {
            #log(
                Self.logger, .notice,
                "Refused to run '\(instance.name, privacy: .public)': shares the MAC address \(mac, privacy: .public) with active VM '\(conflict.name, privacy: .public)'"
            )
            throw CommandError.conflict(
                vm: summary(instance), with: summary(conflict), reason: .macAddress)
        }
    }

    // MARK: - Guest Account

    /// What this start hands the guest for the account its VM owes — `nil` when
    /// it hands nothing, refusing when nobody has answered for it.
    ///
    /// Read from the VM's own state rather than from the call
    /// (``VMCapabilityCatalog/guestAccountState(of:)``): the answer is held for
    /// the VM by whoever supplied it, and a start that finds none refuses. Every
    /// door reaches this, which is what makes the rule uniform — whichever one
    /// can ask turns the refusal into its own question
    /// (``VMConsentPolicy/runGatheringGuestAccount(prompting:_:)``), and one
    /// that cannot passes the refusal to whoever called it.
    ///
    /// Reading the answer does not consume it: what spends the account is a boot
    /// that came up, so a start that fails before one leaves both halves where
    /// they were and its retry neither asks again nor has to.
    ///
    /// A recovery boot carries no account and spends no window, so it reads
    /// nothing.
    private func guestProvisioning(
        for instance: VMInstance, recovery: Bool
    ) throws -> GuestProvisioningCredentials? {
        guard !recovery else { return nil }
        switch capabilities.guestAccountState(of: instance) {
        case .none:
            return nil
        case .owed(let account):
            throw owedGuestAccount(account, on: instance)
        case .answered(let account, let password):
            return GuestProvisioningCredentials(intent: account, password: password.value)
        }
    }

    /// Refuses an owed account before anything else happens, for a verb whose
    /// own work would be the wrong thing to do on the way to a refused start.
    func refuseOwedGuestAccount(_ instance: VMInstance) throws {
        guard case .owed(let account) = capabilities.guestAccountState(of: instance) else { return }
        throw owedGuestAccount(account, on: instance)
    }

    /// The refusal asking for `account`, logged as it is raised.
    private func owedGuestAccount(
        _ account: GuestAccountIntent, on instance: VMInstance
    ) -> CommandError {
        #log(
            Self.logger, .notice,
            "Refused to start '\(instance.name, privacy: .public)': nobody has answered for the account '\(account.username, privacy: .public)' it was set up with"
        )
        return .guestAccountPasswordRequired(
            GuestAccountPrompt(
                vm: summary(instance), username: account.username, fullName: account.fullName,
                message: Self.guestAccountMessage(vmName: instance.name, account: account)))
    }

    // MARK: - Answering for the Guest Account

    func provideGuestAccountPassword(_ selector: VMSelector, password: String) throws {
        let instance = try resolve(selector)
        try holdGuestAccountPassword(password, for: instance)
    }

    /// The account an answer would be about, or `nil` when there is none to
    /// answer for — an account already answered for included, which is what
    /// makes both verbs replace rather than refuse.
    private func guestAccountToAnswerFor(_ instance: VMInstance) -> GuestAccountIntent? {
        switch capabilities.guestAccountState(of: instance) {
        case .none: nil
        case .owed(let account), .answered(let account, _): account
        }
    }

    /// Validates `password` against the account `instance` names and holds it —
    /// the one path an answer reaches the VM by, whether a door supplied it or a
    /// create carried it.
    ///
    /// Virtualization's verdict is taken here rather than at the boot: a
    /// password it turns down produces no account, and a boot that ran anyway
    /// would have spent the one window macOS reads one in on a typo. The
    /// swallow-and-warn in
    /// ``MacOSGuestProvisioning/macOSStartOptions(bootIntoRecovery:guestOS:provisioning:)``
    /// stays as the last line of defence, where coming up unprovisioned beats
    /// not coming up at all.
    func holdGuestAccountPassword(_ password: String, for instance: VMInstance) throws {
        guard let account = guestAccountToAnswerFor(instance) else {
            throw CommandError.invalidArgument(
                "\u{201C}\(instance.name)\u{201D} creates no macOS account, so there is no password to set."
            )
        }
        let credentials = GuestProvisioningCredentials(intent: account, password: password)
        if let refusal = MacOSGuestProvisioning.validate(credentials) {
            #log(
                Self.logger, .notice,
                "macOS turned down the password for the account '\(account.username, privacy: .public)' on '\(instance.name, privacy: .public)'"
            )
            throw CommandError.invalidArgument(refusal.message)
        }
        library.holdGuestAccountPassword(GuestAccountPassword(password), for: instance)
        #log(
            Self.logger, .notice,
            "Holding the password for the account '\(account.username, privacy: .public)' '\(instance.name, privacy: .public)' was set up with"
        )
    }

    func skipGuestAccount(_ selector: VMSelector) throws {
        let instance = try resolve(selector)
        guard let account = guestAccountToAnswerFor(instance) else {
            throw CommandError.invalidArgument(
                "\u{201C}\(instance.name)\u{201D} creates no macOS account, so there is nothing to skip."
            )
        }
        #log(
            Self.logger, .notice,
            "Skipping the account '\(account.username, privacy: .public)' '\(instance.name, privacy: .public)' was set up with — macOS asks for one in Setup Assistant instead"
        )
        library.retractGuestAccount(for: instance)
    }

    /// What every surface is told about an account nobody has answered for.
    ///
    /// Names the account as the wizard gathered it, states the two facts a
    /// decision rests on — the boot creates it, and Kernova holds no password
    /// for it — and ends with the one remedy true wherever this is read, since
    /// the app can always ask. A door that can answer for itself adds its own
    /// way on top, as the `kernova` tool adds `--yes` to a consent refusal.
    private static func guestAccountMessage(vmName: String, account: GuestAccountIntent) -> String {
        "\u{201C}\(vmName)\u{201D} creates the macOS account \u{201C}\(account.fullName)\u{201D} "
            + "(\(account.username)) on its first boot, and Kernova doesn\u{2019}t save that "
            + "account\u{2019}s password. Start it in Kernova to enter the password, or to skip "
            + "setting up the account."
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
        guard let surface = displayBootSurface?(instance) else {
            #log(
                Self.logger, .notice,
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
            #log(
                Self.logger, .warning,
                "Could not persist the window-fitted resolution for '\(instance.name, privacy: .public)' — booting at the previously saved resolution"
            )
        }
    }

    // MARK: - Bring-Up Failure

    /// Turns a bring-up failure into the refusal a surface renders: the
    /// removable attachment when one is at fault, the explained capacity
    /// message when the VM limit is, else the raw error.
    ///
    /// Shared by both bring-up verbs, because both assemble the same
    /// configuration from the same attachments before the guest comes up —
    /// a resume restoring a saved state fails over a missing disk exactly as a
    /// boot does. `verb` is what the user asked for, which is what the refusal
    /// names.
    private func bringUpFailure(
        _ error: Error, verb: VMVerb, on instance: VMInstance
    ) -> CommandError {
        #log(
            Self.logger, .error,
            "Failed to \(verb.rawValue, privacy: .public) '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
        )
        if case VMLifecycleCoordinator.LifecycleError.operationInProgress = error {
            return failure(error, verb: verb, on: instance)
        }
        if let failure = bringUpFailedAttachment(from: error, verb: verb, on: instance) {
            return .operationFailed(
                verb: verb, message: error.localizedDescription,
                recovery: .removeStartFailedAttachment(failure))
        }
        if let explained = explainedFailure(for: error, verb: verb, on: instance) {
            return .operationFailed(
                verb: verb, title: explained.title, message: explained.message)
        }
        return .operationFailed(verb: verb, message: error.localizedDescription)
    }

    /// Maps a bring-up error to a ``StartFailedAttachment`` when it identifies
    /// an attachment the user can remove to get the VM running, or `nil` when
    /// the generic error is the right surface.
    ///
    /// Two exclusions where removal is the wrong advice: a VM's only disk, since
    /// removing it leaves nothing to start (and an empty list would re-synthesize
    /// `Disk.asif`), and file-lock contention — the file is fine and the lock
    /// holder is a VM still tearing down, so the fix is to wait and retry.
    private func bringUpFailedAttachment(
        from error: Error, verb: VMVerb, on instance: VMInstance
    ) -> StartFailedAttachment? {
        guard let builderError = error as? ConfigurationBuilderError,
            !VirtualizationService.isFileLockContention(builderError)
        else { return nil }
        switch builderError {
        case .storageDiskAttachFailed(let id, _, let label, _):
            guard let disk = storageDisk(id: id, on: instance),
                !instance.isSoleStorageDisk(disk)
            else { return nil }
            return StartFailedAttachment(
                verb: verb, kind: .storageDisk, id: id, label: label,
                message: builderError.localizedDescription)
        case .removableMediaAttachFailed(let id, _, let label, _):
            // Confirm the entry is really in the list: an offer whose action could
            // only no-op leaves a button that appears to do nothing.
            guard (instance.configuration.removableMedia ?? []).contains(where: { $0.id == id })
            else { return nil }
            return StartFailedAttachment(
                verb: verb, kind: .removableMedia, id: id, label: label,
                message: builderError.localizedDescription)
        default:
            return nil
        }
    }

    /// Maps a bring-up or install failure to copy naming the cause and the
    /// remedy, or `nil` when the raw error description is the right surface.
    private func explainedFailure(
        for error: Error, verb: VMVerb, on instance: VMInstance
    ) -> (title: String, message: String)? {
        guard VirtualizationService.isVirtualMachineLimitExceeded(error) else { return nil }
        let action = Self.bringUpLabel(for: instance, verb: verb)
        // The heading names the operation, the message names the control: a
        // resumed download's button says "Resume Download" and the operation is
        // still a download.
        let operation: String
        switch instance.startAction {
        case .start: operation = verb == .resume ? "Resume" : "Start"
        case .install, .resumeInstall: operation = "Install"
        case .download, .resumeDownload: operation = "Download"
        }
        let message: String
        switch instance.configuration.guestOS {
        case .macOS:
            message =
                "macOS allows at most two macOS virtual machines to run at once. Stop another macOS VM, then click \(action) to try again."
        case .linux:
            message =
                "The limit on running virtual machines has been reached. Stop another virtual machine, then click \(action) to try again."
        }
        return (title: "Couldn't \(operation) \u{201C}\(instance.name)\u{201D}", message: message)
    }

    /// What the control that brings this VM up is called: the Resume a VM
    /// holding a saved state offers, and the Start, Install or Download every
    /// other state does.
    ///
    /// `verb` is the bring-up that was asked for, so copy about a failed one
    /// names the control the user actually clicked.
    private static func bringUpLabel(for instance: VMInstance, verb: VMVerb) -> String {
        verb == .resume ? "Resume" : instance.startAction.label
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
                #log(
                    Self.logger, .notice,
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
                    #log(
                        Self.logger, .notice,
                        "Setup cancelled for '\(instance.name, privacy: .public)' — pipeline surfaced \(error.localizedDescription, privacy: .public)"
                    )
                } else if let explained = self.explainedFailure(
                    for: error, verb: .start, on: instance)
                {
                    self.reportUnattendedFailure(
                        .operationFailed(
                            verb: .start, title: explained.title, message: explained.message),
                        on: instance)
                } else {
                    self.reportUnattendedFailure(
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
            // Before the boot, which would otherwise ask about an account this
            // is about to end: the setup that just landed is the first thing to
            // read the guest's real version.
            self.dropGuestAccountBelowProvisioningFloor(on: instance)
            do {
                try await self.start(instance)
            } catch let failure as CommandError {
                self.reportUnattendedFailure(failure, on: instance)
            } catch {
                self.reportUnattendedFailure(
                    .operationFailed(verb: .start, message: error.localizedDescription),
                    on: instance)
            }
        }
    }

    /// Drops the account a VM owes when the guest a finished setup produced
    /// cannot act on one.
    ///
    /// The image the install ran from is the first authoritative reading of the
    /// guest's version — the account was offered against a filename, and a
    /// pinned URL or a picked file can name anything. Dropped rather than
    /// refused: the install has already landed, and there is no per-VM editor to
    /// turn the intent off with.
    private func dropGuestAccountBelowProvisioningFloor(on instance: VMInstance) {
        guard instance.configuration.pendingGuestAccount != nil,
            !MacOSGuestProvisioning.canProvision(instance.configuration)
        else { return }
        let image = instance.configuration.installedImage?.displayName ?? "the installed image"
        #log(
            Self.logger, .warning,
            "Dropping the guest account for '\(instance.name, privacy: .public)': \(image, privacy: .public) does not run the guest provisioning protocol"
        )
        library.retractGuestAccount(for: instance)
    }

    /// Drives the macOS install pipeline, then chains the boot that spends the
    /// account the VM owes.
    private func installAndAutoBoot(_ instance: VMInstance, context: MacOSInstallContext) {
        runGuestSetup(on: instance) { lifecycle in
            try await lifecycle.installMacOS(on: instance, context: context)
        }
    }

    /// Drives the Linux installer-image pipeline, then chains the boot.
    private func downloadAndAutoBoot(_ instance: VMInstance, context: LinuxInstallContext) {
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
        #log(Self.logger, .info, "Cancelling setup for '\(instance.name, privacy: .public)'")
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
        // Only the install loses work: its progress restarts from the
        // beginning. A kept image and a resumable download cost nothing.
        let confirmIsDestructive: Bool
        let dismissTitle: String
        switch instance.setupState?.currentStep?.id {
        case .install:
            title = "Cancel Installation?"
            message =
                "The installation will restart from the beginning the next time you start the virtual machine. The downloaded macOS image is cached, so you won't need to download it again."
            confirmTitle = "Cancel Installation"
            confirmIsDestructive = true
            dismissTitle = "Keep Installing"
        case .verify:
            title = "Cancel Verification?"
            message =
                "The downloaded image is kept, and it will be checked again the next time you start the virtual machine."
            confirmTitle = "Cancel Verification"
            confirmIsDestructive = false
            dismissTitle = "Keep Verifying"
        case .download, nil:
            title = "Cancel Download?"
            message =
                "The download progress will be saved and resumed the next time you start the virtual machine."
            confirmTitle = "Cancel Download"
            confirmIsDestructive = false
            dismissTitle = "Keep Downloading"
        }
        return ConfirmationPrompt(
            kind: .cancelGuestSetup, title: title, message: message, confirmTitle: confirmTitle,
            confirmIsDestructive: confirmIsDestructive, dismissTitle: dismissTitle)
    }

    // MARK: - Stop

    func stop(
        _ selector: VMSelector, disposition: StopDisposition, confirmed: Bool,
        timeout: TimeInterval?
    ) async throws {
        try Self.requireUsable(timeout)
        try await stop(
            try resolve(selector), disposition: disposition, confirmed: confirmed, timeout: timeout)
    }

    /// Takes the guest down, waiting out the power-off only for a caller that
    /// asked to be told whether it happened.
    ///
    /// Without a `timeout` the verb is the shutdown *request*: VZ accepts it and
    /// the guest goes down in its own time, which is what every in-app Stop
    /// means. With one, the wait is the verb — and a guest that ignores the
    /// request refuses rather than escalating, because terminating it is a
    /// separate decision with separate consent.
    func stop(
        _ instance: VMInstance, disposition: StopDisposition, confirmed: Bool,
        timeout: TimeInterval? = nil
    ) async throws {
        try await requestStop(instance, disposition: disposition, confirmed: confirmed)
        guard let timeout else { return }
        try await awaitPowerOff(instance, within: timeout, verb: .stop)
    }

    private func requestStop(
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
            // A VM holding a saved state has no guest to send the request to, so
            // this is not a shutdown at all: it deletes the suspended session
            // exactly as the force path does, and an Ephemeral VM's rolls the
            // disks back to the baseline on top of that. It passes the gate
            // alongside the VMs that do take a shutdown, and asks the same
            // consent the force path does — which is also what the UI asks at
            // every suspended Stop.
            try require(anyOf: [.stop, .discardSavedState], on: instance)
            guard confirmed || !instance.holdsSuspendedSession else {
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
                #log(Self.logger, .notice, "Force-stopped VM '\(instance.name, privacy: .public)'")
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
            #log(
                Self.logger, .error,
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
            title: "Stop \u{201C}\(instance.name)\u{201D}?",
            message:
                "\u{201C}\(instance.name)\u{201D} is paused and cannot be shut down directly. Resume it to send a graceful shutdown, or force stop to terminate it immediately (any unsaved data inside the guest will be lost).",
            confirmTitle: "Resume and Shut Down",
            confirmIsDestructive: false,
            dismissTitle: "Cancel",
            alternatives: [
                ConfirmationAlternative(
                    title: "Force Stop", isDestructive: true, disposition: .force)
            ])
    }

    /// The refusal a force stop raises, worded for what it actually discards.
    static func forceStopPrompt(_ instance: VMInstance) -> ConfirmationPrompt {
        // An ephemeral VM's discard is a revert to its baseline, so the button
        // names that outcome rather than the deletion it isn't.
        let discardsSavedState = instance.holdsSuspendedSession
        let ephemeralBaseline = discardsSavedState ? instance.ephemeralBaselineSnapshot : nil
        let message: String
        if let ephemeralBaseline {
            message =
                "\u{201C}\(instance.name)\u{201D} is ephemeral, so it returns to "
                + "\u{201C}\(ephemeralBaseline.name)\u{201D}. The suspended session, and everything "
                + "changed inside the guest during it, are discarded."
        } else if discardsSavedState {
            message =
                "\u{201C}\(instance.name)\u{201D} has its state saved to disk. Discarding will permanently delete the saved state."
        } else {
            message =
                "\u{201C}\(instance.name)\u{201D} will be immediately terminated. Any unsaved data inside the guest will be lost."
        }
        let confirmTitle: String
        if discardsSavedState {
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
        let title: String
        if let ephemeralBaseline {
            // The discard *is* a revert to that snapshot, so it asks in the
            // words `revertPrompt` asks in.
            title =
                "Revert \u{201C}\(instance.name)\u{201D} to \u{201C}\(ephemeralBaseline.name)\u{201D}?"
        } else if discardsSavedState {
            title = "Discard the Saved State of \u{201C}\(instance.name)\u{201D}?"
        } else {
            title = "Force Stop \u{201C}\(instance.name)\u{201D}?"
        }
        return ConfirmationPrompt(
            kind: .forceStop,
            title: title,
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
            #log(
                Self.logger, .error,
                "Failed to pause '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw failure(error, verb: .pause, on: instance)
        }
    }

    func resume(_ selector: VMSelector) async throws {
        let instance = try resolve(selector)
        try require(.resume, on: instance)

        if case .restoringSavedState = instance.phase {
            readyDisplay?(instance)
            return try await joinBringUp(instance, verb: .resume) {
                bringUpFailure($0, verb: .resume, on: instance)
            }
        }

        // A cold resume builds a fresh VZVirtualMachine from the save file, so it
        // claims the machine identity — and puts its MAC address back on a
        // network — just as a cold boot does. A hot resume's live object already
        // holds both, and refusing would be refusing a VM its own identity.
        if instance.holdsSuspendedSession {
            try refuseDuplicateIdentity(instance)
        }

        readyDisplay?(instance)
        do {
            try await lifecycle.resume(instance)
        } catch {
            throw bringUpFailure(error, verb: .resume, on: instance)
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
            #log(
                Self.logger, .error,
                "Failed to save '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw failure(error, verb: .suspend, on: instance)
        }
    }

    // MARK: - Restart

    /// Shuts the guest down and starts it again once it has powered off.
    ///
    /// Composed rather than a VZ operation of its own, so it inherits every
    /// gate and refusal the two verbs already state.
    ///
    /// Two waits, because only the first is the guest's to refuse. The
    /// power-off is what a `timeout` bounds; without one it is unbounded,
    /// matching what a graceful shutdown means — a guest that will not go down
    /// is neither restarted nor terminated behind the user's back. The settle
    /// after it is always unbounded: `resetToStopped()` fires the power-off hook
    /// a turn after the status, so an Ephemeral VM's baseline revert registers
    /// there, and bringing the VM up mid-revert would either be refused as busy
    /// or boot off disks the revert is still overwriting. No guest can withhold
    /// that work, so no deadline belongs on it.
    ///
    /// Where the VM lands decides which verb brings it back up. A power-off
    /// normally lands it stopped, but an Ephemeral VM's baseline revert can hand
    /// it back suspended on the baseline's memory image, and that is the state
    /// the mode promises — so it is resumed rather than booted, and never waited
    /// on for a `.stopped` that is not coming.
    ///
    /// A VM still owing its guest the account it was set up with is refused
    /// before the stop. Running is not evidence the window is spent — an
    /// install can finish and the guest be booted into Recovery, which reads no
    /// account — and finding that out after the guest is down would leave the
    /// VM powered off half way through a restart.
    func restart(_ selector: VMSelector, timeout: TimeInterval?) async throws {
        try Self.requireUsable(timeout)
        let instance = try resolve(selector)
        try require(.restart, on: instance)
        // Before the stop, not at the boot half: a VM still owing its account
        // has a question outstanding, and discovering that after the guest is
        // down leaves it powered off mid-restart. Refused here it keeps
        // running, and the door that can ask answers and restarts again.
        try refuseOwedGuestAccount(instance)
        try await stop(instance, disposition: .graceful, confirmed: true)
        try await awaitPowerOff(instance, within: timeout, verb: .restart)
        await waitForObservedChange { [library] in
            !library.isBusy(instance) && !library.hasRevertInFlight(for: instance.id)
                && (instance.canStart || instance.canResume)
        }
        switch capabilities.bringUpVerb(for: instance) {
        case .resume:
            try await resume(.id(instance.id))
        case .start, nil:
            // `nil` falls here so the start's own gate names what is in the way
            // — a clone that began copying this VM's files while the guest was
            // going down is `busy`, not a restart with nothing left to do.
            try await start(instance)
        }
    }

    /// Refuses a deadline no wait can honor, before anything is asked of the
    /// guest.
    private static func requireUsable(_ timeout: TimeInterval?) throws {
        guard let timeout, !CommandTimeout.isUsable(timeout) else { return }
        throw CommandError.invalidArgument("A timeout is a number of seconds greater than zero.")
    }

    /// Suspends until the guest is off — its `VZVirtualMachine` gone from
    /// memory — bounded by `seconds` when the caller named one.
    ///
    /// The power-off is the whole of what a shutdown request achieves and the
    /// whole of what a guest can refuse, so it is all a deadline here measures.
    /// A pause or a save keeps the memory live and satisfies nothing; work
    /// Kernova does behind the power-off is waited out separately, and without a
    /// deadline.
    ///
    /// - Throws: ``CommandError/timedOut(vm:verb:seconds:)`` when the deadline
    ///   passes first. Nothing is undone and nothing is escalated: the VM is
    ///   exactly where the expiry found it.
    private func awaitPowerOff(
        _ instance: VMInstance, within seconds: TimeInterval?, verb: VMVerb
    ) async throws {
        let isOff: @MainActor () -> Bool = { !instance.hasLiveVirtualMachine }
        guard let seconds else {
            await waitForObservedChange(until: isOff)
            return
        }
        let settled = await waitForObservedChange(
            until: isOff, before: ObservedChangeDeadline(seconds: seconds, clock: clock))
        guard settled else {
            #log(
                Self.logger, .notice,
                "'\(instance.name, privacy: .public)' had not powered off \(seconds, privacy: .public)s after the shutdown request"
            )
            throw CommandError.timedOut(vm: summary(instance), verb: verb, seconds: seconds)
        }
    }

    // MARK: - Open

    func open(_ selector: VMSelector) throws {
        let instance = try resolve(selector)
        // An imported bundle carrying a save file rests its phantom `.paused`,
        // which reads as having a display while the copy is still writing —
        // and a preparing row admits no verb that would surface one.
        try require(.open, on: instance)
        surfaceDisplay?(instance)
    }

    // MARK: - Reveal

    /// Brings the VM in front of the user whatever state it is in.
    ///
    /// The branch is the ``VMCapability/open`` gate rather than a display test
    /// of its own, so the one VM whose display is not the right thing to
    /// surface — the phantom of an import still copying, resting `.paused` —
    /// lands on its library row instead, and by the same predicate that refuses
    /// it an ``open(_:)``.
    func reveal(_ selector: VMSelector) throws {
        let instance = try resolve(selector)
        try require(.reveal, on: instance)
        if capabilities.accepts(.open, on: instance) {
            surfaceDisplay?(instance)
        } else {
            revealInLibrary?(instance)
        }
    }

    // MARK: - Show in Finder

    func showInFinder(_ selector: VMSelector) throws {
        let instance = try resolve(selector)
        try require(.showInFinder, on: instance)
        revealInFinder?(instance)
    }

    // MARK: - Application

    /// Fires the quit from a later main-actor turn, so a transport waiting on
    /// this verb has its answer encoded and handed over before the app starts
    /// going down — a client left reading a socket that simply closed cannot
    /// tell success from a crash.
    func quit() {
        #log(Self.logger, .notice, "Quit requested from a command front door")
        guard let requestQuit else {
            #log(Self.logger, .fault, "No adapter is wired to take the app down")
            assertionFailure("No adapter is wired to take the app down")
            return
        }
        Task { @MainActor in requestQuit() }
    }

    // MARK: - Storage Disk Lookup

    /// The storage disk `id` refers to, resolving the synthesized main disk
    /// when the VM has no explicit list.
    func storageDisk(id: UUID, on instance: VMInstance) -> StorageDisk? {
        instance.effectiveStorageDisks.first { $0.id == id }
    }
}
