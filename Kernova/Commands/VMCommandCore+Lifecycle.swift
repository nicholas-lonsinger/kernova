import Foundation
import KernovaKit
import KernovaLogging

/// The lifecycle verbs: everything that moves a VM between resting and
/// running, plus the guest-setup pipelines a first start owes.
extension VMCommandCore {
    // MARK: - Start

    func start(
        _ selector: VMSelector, recovery: Bool, consent: Consent,
        macAddressRemedy: MACAddressRemedy? = nil
    ) async throws {
        let instance = try resolve(selector)
        let identity = VMIdentityOverride(consent)
        do {
            if let remedy = try macAddressRemedyToTake(
                macAddressRemedy,
                answering: instance.activity.decide(
                    .start(recovery: recovery), posture: .commit, identity: identity),
                on: instance, identity: identity, holdingSavedState: instance.hasSaveFile,
                accountFor: recovery, verb: .start)
            {
                try takeMACAddressRemedy(remedy, on: instance, verb: .start)
            }
            try await startNow(instance, recovery: recovery, policy: .command(identity)).value()
        } catch {
            throw bringUpFailure(error, verb: .start, on: instance)
        }
    }

    /// What a start may begin beyond the bring-up itself.
    enum StartPolicy: Sendable, Equatable {
        /// Someone asked for this start: it runs the guest setup the VM still
        /// owes, which chains the boot. `identity` is what they can do about
        /// another active VM sharing its machine identity.
        case command(VMIdentityOverride)
        /// A standing preference asked for it
        /// (``VMHostState/startsAutomaticallyOnLaunch``), with nobody at the
        /// machine to watch what a start would put on screen: it begins no
        /// guest setup, and nobody can confirm starting beside a VM sharing its
        /// machine identity.
        case standing

        /// What this start can do about another active VM sharing its machine
        /// identity.
        var identity: VMIdentityOverride {
            switch self {
            case .command(let identity): identity
            case .standing: .unavailable
            }
        }
    }

    /// Decides the start `instance`'s state names and launches it, resolving
    /// `outcome` when its bring-up ends — the one start path, whoever asked:
    /// the user's Start, the boot a guest setup chains, a create's and the
    /// launch pass's auto-start, and Restart's boot.
    ///
    /// Synchronous from the decision to the launch, so what admission decided
    /// is what launches, and one a follow-up drains holds the VM before the
    /// step that freed it ends. A bring-up already in flight that the start
    /// joins forwards its outcome to `outcome`; a guest setup resolves
    /// `outcome` once it holds the VM, since the setup reports its own ending
    /// and chains the boot.
    ///
    /// Decided before anything else happens, so a busy VM refuses before the
    /// account question is raised. Throws the admission refusal as raised, or
    /// the account question
    /// (``CommandError/guestAccountPasswordRequired(_:)``), launching nothing.
    @discardableResult
    func startNow(
        _ instance: VMInstance, recovery: Bool = false, policy: StartPolicy,
        resolving outcome: VMOutcome = VMOutcome()
    ) throws -> VMOutcome {
        switch instance.activity.decide(
            .start(recovery: recovery), posture: .commit, identity: policy.identity)
        {
        case .refuse(let reason):
            if recovery, reason == .invalidState,
                instance.activity.decide(
                    .start(recovery: false), posture: .commit, identity: policy.identity) == .admit
            {
                throw CommandError.unsupported(capability: "starting in macOS Recovery")
            }
            throw VMAdmissionRefusal(refusal: reason)
        case .join(let running):
            logJoin(instance)
            readyDisplay?(instance)
            running.forward(to: outcome)
            return outcome
        case .admit:
            break
        }
        let work = VMAdmission.startWork(recovery: recovery, facts: instance.admissionFacts)
        if policy == .standing, case .setup = work {
            throw VMAdmissionRefusal(refusal: .invalidState)
        }

        // Before the setup dispatch, so an install nobody answered for is
        // turned back rather than running and chaining a boot that is.
        let provisioning = try guestProvisioning(for: instance, work: work)

        switch work {
        case .setup:
            // The setup pipeline chains the boot that spends the account, and
            // reads the answer where this did.
            try runGuestSetup(on: instance, identity: policy.identity)
            outcome.resolve(.success(()))
        case .guestStart(let kind):
            try lifecycle.launchStart(
                instance, kind, identity: policy.identity, provisioning: provisioning,
                resolving: outcome,
                beforeBoot: { [weak self] in self?.applyMatchWindowBootResolution($0) },
                afterBoot: { [weak self] permit, route in
                    try self?.retractDeliveredGuestAccount(permit, route: route)
                })
            // After the commit and before the body's first turn, which applies
            // the boot geometry: a pop-out VM's window is what
            // `displayBootSurface` measures, and readying is what opens it.
            readyDisplay?(instance)
        }
        return outcome
    }

    /// A start nobody waits on, as a follow-up on `instance` — joining a
    /// bring-up already in flight or a start already queued, and otherwise
    /// decided afresh when it drains.
    ///
    /// A failure is reported the way a direct start's is, the
    /// removable-attachment recovery included; a standing start that passed
    /// its VM over (``standingStartPassedOver(_:)``) did not fail.
    func startFollowUp(_ instance: VMInstance, policy: StartPolicy) -> VMFollowUp {
        VMFollowUp(scope: .vm, rank: .ordinary, request: .start(recovery: false)) {
            [weak self, weak instance] outcome in
            guard let self, let instance else { throw CancellationError() }
            try self.startNow(instance, policy: policy, resolving: outcome)
        }
        .reportingFailure { [weak self, weak instance] error in
            guard let self, let instance,
                policy != .standing || !Self.standingStartPassedOver(error)
            else { return }
            self.reportUnattendedFailure(
                self.bringUpFailure(error, verb: .start, on: instance), on: instance)
        }
    }

    /// Whether a standing start that ended with `error` passed its VM over
    /// rather than failed: the VM's state takes no start — it is running
    /// already, here or in another copy of Kernova, gone, or has a guest setup
    /// still to run — or its start would ask the account question nobody is
    /// there to answer.
    static func standingStartPassedOver(_ error: any Error) -> Bool {
        if case .guestAccountPasswordRequired? = error as? CommandError { return true }
        guard let refused = error as? VMAdmissionRefusal else { return false }
        switch refused.refusal {
        case .invalidState, .removed, .heldByAnotherCopy:
            return true
        case .busy, .identityConflict, .accessoryHeld, .unsupportedByBuild, .terminating,
            .takesStoppedVM:
            return false
        }
    }

    /// Ends the account the boot that came up by `route` delivered, as a write
    /// of that start.
    ///
    /// The cold boot is the one that spent the window, whether or not it
    /// carried an account: the other two routes never reach the one boot
    /// ``GuestStartRoute/deliversGuestProvisioning`` names. A retraction that
    /// does not land fails the start that spent it — the VM stays up, and the
    /// password is kept with the intent it answers.
    private func retractDeliveredGuestAccount(
        _ permit: borrowing VMEditPermit, route: GuestStartRoute
    ) throws {
        let instance = permit.instance
        guard route == .coldBoot, instance.configuration.pendingGuestAccount != nil else { return }
        guard case .saved = library.retractGuestAccount(permit) else {
            throw CommandError.operationFailed(
                verb: .start,
                message:
                    "\u{201C}\(instance.name)\u{201D} started, but Kernova could not record that the boot that delivers its macOS account has run."
            )
        }
    }

    /// Records that a request joined the bring-up already in flight for
    /// `instance`, which answers it with what it answers its own caller.
    private func logJoin(_ instance: VMInstance) {
        #log(
            Self.logger, .notice,
            "Joining the bring-up already in flight for '\(instance.name, privacy: .public)'")
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
    /// Only the cold boot ``GuestStartRoute/deliversGuestProvisioning`` names
    /// reads anything — or the guest setup that chains one: a recovery boot
    /// and a restore both carry no account and spend no window, so neither
    /// asks for one, and the question is put to the bring-up the start itself
    /// performs, so what is read here and what the boot does cannot disagree.
    func guestProvisioning(
        for instance: VMInstance, work: VMAdmission.StartWork
    ) throws -> GuestProvisioningCredentials? {
        let deliversAccount: Bool =
            switch work {
            case .setup: true
            case .guestStart(let start): GuestStartRoute(start).deliversGuestProvisioning
            }
        guard deliversAccount else { return nil }
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
        VMCapabilityCatalog.deliverableGuestAccount(of: instance.configuration)
    }

    /// Validates `password` against the account `instance` names and holds it.
    func holdGuestAccountPassword(_ password: String, for instance: VMInstance) throws {
        try holdGuestAccountPassword(password, for: instance.id, configuredAs: instance.configuration)
    }

    /// Validates `password` against the account `configuration` names and holds
    /// it for the VM identified by `id` — the one path an answer reaches a VM
    /// by, whether a door supplied it or a create carried it for the arrival
    /// that becomes the VM.
    ///
    /// Virtualization's verdict is taken here rather than at the boot: a
    /// password it turns down produces no account, and a boot that ran anyway
    /// would have spent the one window macOS reads one in on a typo. The
    /// swallow-and-warn in
    /// ``MacOSGuestProvisioning/macOSStartOptions(bootIntoRecovery:guestOS:provisioning:)``
    /// stays as the last line of defence, where coming up unprovisioned beats
    /// not coming up at all.
    func holdGuestAccountPassword(
        _ password: String, for id: UUID, configuredAs configuration: VMConfiguration
    ) throws {
        guard let account = VMCapabilityCatalog.deliverableGuestAccount(of: configuration) else {
            throw CommandError.invalidArgument(
                "\u{201C}\(configuration.name)\u{201D} creates no macOS account, so there is no password to set."
            )
        }
        let credentials = GuestProvisioningCredentials(intent: account, password: password)
        if let refusal = MacOSGuestProvisioning.validate(credentials) {
            #log(
                Self.logger, .notice,
                "macOS turned down the password for the account '\(account.username, privacy: .public)' on '\(configuration.name, privacy: .public)'"
            )
            throw CommandError.invalidArgument(refusal.message)
        }
        library.holdGuestAccountPassword(GuestAccountPassword(password), for: id)
        #log(
            Self.logger, .notice,
            "Holding the password for the account '\(account.username, privacy: .public)' '\(configuration.name, privacy: .public)' was set up with"
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
        let write = try edit(.liveKeys, on: instance, verb: .start) { permit in
            library.retractGuestAccount(permit)
        }
        switch write {
        case .saved:
            return
        case .refused(let refusal):
            throw refusalError(refusal, on: instance, verb: .start)
        case .notSaved:
            throw CommandError.operationFailed(
                verb: .start,
                message:
                    "The account \u{201C}\(account.username)\u{201D} could not be skipped: the change to \u{201C}\(instance.name)\u{201D} was not saved."
            )
        }
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

    // MARK: - Boot Geometry

    /// Resizes a cold-booting VM's display to the surface it is about to appear
    /// on, persisting the result as a write of the start `permit` belongs to,
    /// before the VZ configuration is built.
    ///
    /// Left alone when a save file exists, which a changed display width or
    /// height fails to restore.
    private func applyMatchWindowBootResolution(_ permit: borrowing VMEditPermit) {
        let instance = permit.instance
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
        switch library.updateConfiguration(permit, mutate: { $0.displayResolution = resolution }) {
        case .saved:
            break
        case .notSaved:
            #log(
                Self.logger, .warning,
                "Could not persist the window-fitted resolution for '\(instance.name, privacy: .public)' — booting at the previously saved resolution"
            )
        case .refused(let refusal):
            #log(
                Self.logger, .warning,
                "The window-fitted resolution for '\(instance.name, privacy: .public)' was refused — booting at the previously saved resolution: \(refusal.localizedDescription, privacy: .public)"
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
    func bringUpFailure(
        _ error: Error, verb: VMVerb, on instance: VMInstance
    ) -> CommandError {
        // A refusal, not a failure: the VM never left where it was, and
        // ``admissionRefusal(_:on:verb:)`` records it. A command error is
        // already in the vocabulary.
        if error is VMAdmissionRefusal || error is CommandError {
            return failure(error, verb: verb, on: instance)
        }
        #log(
            Self.logger, .error,
            "Failed to \(verb.rawValue, privacy: .public) '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
        )
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
    /// Every way one entry can be unusable, not only the refused attach: an
    /// item that is gone, a path naming the wrong kind of item and one the VM
    /// may no longer read or write all leave the same VM, with the same one
    /// entry to remove.
    ///
    /// Three exclusions where removal is the wrong advice. A bundle-internal
    /// disk, because nothing re-creates its entry
    /// (``StartFailedAttachment``) — which covers `Disk.asif`, the disk a
    /// path-traversing entry is refused as, and an in-bundle disk the user
    /// created. A VM's only disk, since removing it leaves nothing to start and
    /// an empty list would re-synthesize `Disk.asif`. And file-lock contention —
    /// the file is fine and the lock holder is a VM still tearing down, so the
    /// fix is to wait and retry.
    private func bringUpFailedAttachment(
        from error: Error, verb: VMVerb, on instance: VMInstance
    ) -> StartFailedAttachment? {
        guard let builderError = error as? ConfigurationBuilderError,
            !VirtualizationService.isFileLockContention(builderError),
            let reason = builderError.attachmentReason
        else { return nil }
        switch builderError {
        case .storageDiskNotFound(let id, _, let label),
            .storageDiskPathIsDirectory(let id, _, let label),
            .storageDiskNotWritable(let id, _, let label),
            .storageDiskAttachFailed(let id, _, let label, _):
            guard let disk = storageDisk(id: id, on: instance),
                !disk.isInternal, !instance.isSoleStorageDisk(disk)
            else { return nil }
            return StartFailedAttachment(
                verb: verb, kind: .storageDisk, reason: reason, id: id, label: label,
                message: builderError.localizedDescription)
        case .removableMediaNotFound(let id, _, let label),
            .removableMediaPathIsDirectory(let id, _, let label),
            .removableMediaNotWritable(let id, _, let label),
            .removableMediaAttachFailed(let id, _, let label, _):
            // Confirm the entry is really in the list: an offer whose action could
            // only no-op leaves a button that appears to do nothing.
            guard removableMediaItem(id: id, on: instance) != nil else { return nil }
            return StartFailedAttachment(
                verb: verb, kind: .removableMedia, reason: reason, id: id, label: label,
                message: builderError.localizedDescription)
        case .sharedDirectoryNotFound(let id, _, let label),
            .sharedDirectoryNotADirectory(let id, _, let label),
            .sharedDirectoryNotReadable(let id, _, let label),
            .sharedDirectoryNotWritable(let id, _, let label):
            guard sharedDirectory(id: id, on: instance) != nil else { return nil }
            return StartFailedAttachment(
                verb: verb, kind: .sharedDirectory, reason: reason, id: id, label: label,
                message: builderError.localizedDescription)
        default:
            return nil
        }
    }

    /// Maps a bring-up or install failure to a title and message naming its
    /// cause, or `nil` when the raw error description is the right surface.
    private func explainedFailure(
        for error: Error, verb: VMVerb, on instance: VMInstance
    ) -> (title: String, message: String)? {
        if case DownloadError.checksumMismatch = error {
            return (title: "Download Doesn't Match Its Checksum", message: error.localizedDescription)
        }
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

    /// Starts the guest-setup pipeline an `.initialBoot` (or `.error` with a
    /// surviving context) VM owes and, on success, chains an auto-boot.
    ///
    /// A permanent failure leaves the VM in `.error` so the banner keeps the
    /// message on screen; cancel and transient failures (the running-VM cap)
    /// return it to `.initialBoot` for a retry that resumes the download from
    /// the `.kernovadownload` bundle if present.
    ///
    /// The chained boot carries a confirmed `identity` on, since the user
    /// confirmed starting this VM beside one sharing its machine identity; it
    /// asks nobody, so an unconfirmed one is refused.
    private func runGuestSetup(on instance: VMInstance, identity: VMIdentityOverride) throws {
        try lifecycle.launchGuestSetup(on: instance, identity: identity) {
            [weak self, weak instance] result in
            guard let self, let instance else { return [] }
            return self.setupEnded(
                result, on: instance, bootIdentity: identity.unattended)
        }
    }

    /// Reports how a guest setup ended, at its ending commit, answering the
    /// boot a successful one owes — which that commit admits before any other
    /// request can be decided against the VM.
    private func setupEnded(
        _ result: Result<Void, any Error>, on instance: VMInstance,
        bootIdentity: VMIdentityOverride
    ) -> [VMFollowUp] {
        switch result {
        case .failure(is CancellationError):
            #log(
                Self.logger, .notice,
                "Setup cancelled for '\(instance.name, privacy: .public)' — VM remains in .initialBoot"
            )
            return []
        case .failure(let error):
            if let explained = explainedFailure(for: error, verb: .start, on: instance) {
                reportUnattendedFailure(
                    .operationFailed(
                        verb: .start, title: explained.title, message: explained.message),
                    on: instance)
            } else {
                reportUnattendedFailure(failure(error, verb: .start, on: instance), on: instance)
            }
            return []
        case .success:
            break
        }
        // Before the boot, which would otherwise ask about an account this is
        // about to end: the setup that just landed is the first thing to read
        // the guest's real version. A drop that does not land stops the chain,
        // since the boot would ask about that account.
        do {
            try dropGuestAccountBelowProvisioningFloor(on: instance)
        } catch {
            reportUnattendedFailure(
                .operationFailed(verb: .start, message: error.localizedDescription),
                on: instance)
            return []
        }
        return [startFollowUp(instance, policy: .command(bootIdentity))]
    }

    /// Drops the account a VM owes when the guest a finished setup produced
    /// cannot act on one.
    ///
    /// The image the install ran from is the first authoritative reading of the
    /// guest's version — the account was offered against a filename, and a
    /// pinned URL or a picked file can name anything. Dropped rather than
    /// refused: the install has already landed, and there is no per-VM editor to
    /// turn the intent off with.
    private func dropGuestAccountBelowProvisioningFloor(on instance: VMInstance) throws {
        guard instance.configuration.pendingGuestAccount != nil,
            !MacOSGuestProvisioning.canProvision(instance.effectiveConfiguration)
        else { return }
        let image = instance.configuration.installedImage?.displayName ?? "the installed image"
        #log(
            Self.logger, .warning,
            "Dropping the guest account for '\(instance.name, privacy: .public)': \(image, privacy: .public) does not run the guest provisioning protocol"
        )
        try instance.activity.edit(.observations) { try library.retractGuestAccount($0).get() }
    }

    /// Cancels the in-progress guest setup — a macOS install, or a Linux
    /// installer image being fetched or verified.
    ///
    /// The VM returns to `.initialBoot` so a subsequent Start can resume, and the
    /// bundle is preserved — this is the non-destructive cancel.
    func cancelGuestSetup(_ selector: VMSelector, consent: Consent) throws {
        let instance = try resolve(selector)
        try require(.cancelGuestSetup, on: instance)
        guard consent.covers(.cancelGuestSetup) else {
            throw CommandError.confirmationRequired(Self.cancelGuestSetupPrompt(instance))
        }
        #log(Self.logger, .info, "Cancelling setup for '\(instance.name, privacy: .public)'")
        do {
            // The setup operation's own ending owns the status transition and
            // the `setupState` cleanup.
            try instance.activity.cancel(.guestSetup)
        } catch {
            throw failure(error, verb: .cancelGuestSetup, on: instance)
        }
    }

    /// The confirmation a guest-setup cancel raises, worded for the step
    /// running now: a download's progress resumes, an install restarts from
    /// the beginning (the image stays cached), a verify or checksum is simply
    /// redone.
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
        case .checksum:
            title = "Cancel Checksum?"
            message =
                "The downloaded image is kept, and its checksum will be computed the next time you start the virtual machine."
            confirmTitle = "Cancel Checksum"
            confirmIsDestructive = false
            dismissTitle = "Keep Computing"
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
        _ selector: VMSelector, disposition: StopDisposition, consent: Consent,
        timeout: TimeInterval?
    ) async throws {
        try Self.requireUsable(timeout)
        try await stop(
            try resolve(selector), disposition: disposition, consent: consent, timeout: timeout)
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
        _ instance: VMInstance, disposition: StopDisposition, consent: Consent,
        timeout: TimeInterval? = nil
    ) async throws {
        try await requestStop(instance, disposition: disposition, consent: consent)
        guard let timeout else { return }
        try await awaitPowerOff(instance, within: timeout, verb: .stop)
    }

    private func requestStop(
        _ instance: VMInstance, disposition: StopDisposition, consent: Consent
    ) async throws {
        switch disposition {
        case .graceful:
            // A VM holding a saved state has no guest to send the request to, so
            // this is not a shutdown at all: it deletes the suspended session
            // exactly as the force path does, and an Ephemeral VM's rolls the
            // disks back to the baseline on top of that. It passes the gate
            // alongside the VMs that do take a shutdown, and asks the same
            // consent the force path does — which is also what the UI asks at
            // every suspended Stop.
            try require(anyOf: [.stop, .discardSavedState], on: instance)
            // VZ rejects `requestStop()` on a paused VM ("Invalid virtual
            // machine state"), so a live-paused guest has to be resumed first
            // or terminated — which is a choice, not a detail.
            if instance.isLivePaused {
                guard consent.covers(.stopPaused) else {
                    throw CommandError.confirmationRequired(Self.stopPausedPrompt(instance))
                }
                try await resumeThenShutDown(
                    instance, identity: VMIdentityOverride(consent).unattended)
                return
            }
            guard consent.covers(.forceStop) || !instance.holdsSuspendedSession else {
                throw CommandError.confirmationRequired(Self.forceStopPrompt(instance))
            }
            if try await discardedSavedStateAsEphemeralRevert(instance) { return }
            do {
                if instance.holdsSuspendedSession {
                    try lifecycle.discardSavedState(instance)
                } else {
                    try await lifecycle.requestStop(instance)
                }
            } catch {
                throw failure(error, verb: .stop, on: instance)
            }
        case .resumeThenShutDown:
            // Decided with the identity the restore will claim under, which
            // the `.resume` capability's gate would decide without.
            let identity = VMIdentityOverride(consent).unattended
            switch instance.activity.decide(.resume, posture: .commit, identity: identity) {
            case .admit, .join: break
            case .refuse(let reason): throw admissionRefusal(reason, on: instance, verb: .resume)
            }
            try await resumeThenShutDown(instance, identity: identity)
        case .force:
            // Both capabilities, for the reason the graceful branch states: a
            // VM resting on a slot has nothing to terminate and this deletes
            // the suspended session instead. Gated before the consent, so a
            // machine Virtualization would refuse to stop is turned back
            // without first taking the user's agreement to terminate it.
            try require(anyOf: [.forceStop, .discardSavedState], on: instance)
            guard consent.covers(.forceStop) else {
                throw CommandError.confirmationRequired(Self.forceStopPrompt(instance))
            }
            if try await discardedSavedStateAsEphemeralRevert(instance) { return }
            do {
                if instance.holdsSuspendedSession {
                    try lifecycle.discardSavedState(instance)
                } else {
                    try await lifecycle.forceStop(instance)
                }
            } catch {
                throw failure(error, verb: .stop, on: instance)
            }
        }
    }

    /// Resumes a paused VM, or restores a suspended one, then requests a
    /// graceful ACPI shutdown.
    ///
    /// A restore beside a VM sharing the machine identity is asked about by no
    /// one — the caller asked for a stop — so `identity` is unattended.
    private func resumeThenShutDown(
        _ instance: VMInstance, identity: VMIdentityOverride
    ) async throws {
        do {
            try await resumeOrRestore(instance, identity: identity)
            try await lifecycle.requestStop(instance)
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
        // Both choices end in a power-off, and an Ephemeral VM's power-off is
        // a revert, so the outcome the mode produces belongs here as much as in
        // the force-stop refusal.
        let ephemeralReturn =
            instance.ephemeralBaselineSnapshot.map {
                " Either way it is ephemeral, so it returns to \u{201C}\($0.name)\u{201D}."
            } ?? ""
        return ConfirmationPrompt(
            kind: .stopPaused,
            title: "Stop \u{201C}\(instance.name)\u{201D}?",
            message:
                "\u{201C}\(instance.name)\u{201D} is paused and cannot be shut down directly. Resume it to send a graceful shutdown, or force stop to terminate it immediately (any unsaved data inside the guest will be lost).\(ephemeralReturn)",
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
        // Read without reference to what the VM is resting on: every route out
        // of here ends in a power-off, and `onPoweredOff` runs the baseline
        // revert for a termination exactly as it does for a guest that shut
        // itself down (``ephemeralBaselineRevert(for:)``).
        let ephemeralBaseline = instance.ephemeralBaselineSnapshot
        // A VM resting on a slot is not terminated at all — this deletes the
        // suspended session, which an Ephemeral VM performs as the revert, so
        // the button names that outcome rather than the deletion it isn't.
        let discardsSavedState = instance.holdsSuspendedSession
        let revertsInsteadOfTerminating = discardsSavedState && ephemeralBaseline != nil
        // The file, not an inference from the phase: a live guest normally
        // holds no slot, because a start that finds one restores it rather than
        // booting over it and the restore consumes the file — but
        // ``VMBundle/MachineFiles/removeSaveFile()`` reports a refusal by
        // logging it, so a slot can outlive the restore that meant to spend it,
        // and the VM does come back on it
        // (``VMActivity/restingPhase(withoutSlot:)``).
        let keepsSuspendedSession = instance.hasSaveFile
        let suspendedSessionLost =
            "The suspended session, and everything changed inside the guest during it, are discarded."
        let guestDataLost = "Any unsaved data inside the guest will be lost."
        let terminated = "\u{201C}\(instance.name)\u{201D} will be immediately terminated."

        let message: String
        switch (discardsSavedState, ephemeralBaseline) {
        case (true, let baseline?):
            message =
                "\u{201C}\(instance.name)\u{201D} is ephemeral, so it returns to "
                + "\u{201C}\(baseline.name)\u{201D}. \(suspendedSessionLost)"
        case (true, nil):
            message =
                "\u{201C}\(instance.name)\u{201D} has its state saved to disk. Discarding will permanently delete the saved state."
        case (false, let baseline?):
            // The power-off the termination causes rolls the disks back too, so
            // a slot it would otherwise have left in place is replaced by the
            // baseline's rather than resumed.
            message =
                "\(terminated) It is ephemeral, so it returns to "
                + "\u{201C}\(baseline.name)\u{201D}. "
                + (keepsSuspendedSession ? suspendedSessionLost : guestDataLost)
        case (false, nil):
            message =
                keepsSuspendedSession
                ? "\(terminated) Its saved state is kept, so it returns to being suspended."
                : "\(terminated) \(guestDataLost)"
        }

        let confirmTitle: String
        if discardsSavedState {
            confirmTitle = revertsInsteadOfTerminating ? "Revert to Baseline" : "Discard"
        } else {
            // The user asked to terminate, not to revert — the revert is a
            // consequence the message names rather than the command.
            confirmTitle = "Force Stop"
        }
        // A paused VM routes through the stop-paused refusal instead, so
        // offering the graceful shutdown here would chain one onto the other.
        let alternatives =
            instance.activity.decide(.sessionAction(.requestStop), posture: .commit) == .admit
                && !instance.isLivePaused
            ? [ConfirmationAlternative(title: "Shut Down", disposition: .graceful)]
            : []
        let title: String
        if revertsInsteadOfTerminating, let baseline = ephemeralBaseline {
            // The discard *is* a revert to that snapshot, so it asks in the
            // words `revertPrompt` asks in.
            title = "Revert \u{201C}\(instance.name)\u{201D} to \u{201C}\(baseline.name)\u{201D}?"
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

    /// A hot resume of a live-paused VM, or the restore of the saved state one
    /// holds — joining a restore already in flight.
    ///
    /// A remedy the caller chose for a MAC address conflict lands first, and
    /// the bring-up is then the start the VM's state names: a restore while
    /// the saved state survives it, a boot once it was discarded.
    func resume(
        _ selector: VMSelector, consent: Consent, macAddressRemedy: MACAddressRemedy? = nil
    ) async throws {
        let instance = try resolve(selector)
        let identity = VMIdentityOverride(consent)
        let decision = instance.activity.decide(.resume, posture: .commit, identity: identity)
        do {
            if let remedy = try macAddressRemedyToTake(
                macAddressRemedy, answering: decision, on: instance, identity: identity,
                holdingSavedState: instance.hasSaveFile, accountFor: false, verb: .resume)
            {
                try takeMACAddressRemedy(remedy, on: instance, verb: .resume)
                try await startNow(instance, policy: .command(identity)).value()
                return
            }
        } catch {
            throw bringUpFailure(error, verb: .resume, on: instance)
        }
        switch decision {
        case .refuse(let reason):
            throw admissionRefusal(reason, on: instance, verb: .resume)
        case .join(let outcome):
            logJoin(instance)
            readyDisplay?(instance)
            do {
                try await outcome.value()
            } catch {
                throw bringUpFailure(error, verb: .resume, on: instance)
            }
            return
        case .admit:
            break
        }
        // A restore readies the display as every start does.
        if VMAdmission.resumeWork(phase: instance.phase) == .hot { readyDisplay?(instance) }
        do {
            try await resumeOrRestore(instance, identity: identity)
        } catch {
            throw bringUpFailure(error, verb: .resume, on: instance)
        }
    }

    /// The Resume `instance`'s state names: the restore of the saved state it
    /// holds — which is what a start of that VM performs — or a hot resume
    /// from memory.
    private func resumeOrRestore(
        _ instance: VMInstance, identity: VMIdentityOverride
    ) async throws {
        switch VMAdmission.resumeWork(phase: instance.phase) {
        case .restore:
            try await startNow(instance, policy: .command(identity)).value()
        case .hot:
            try await lifecycle.resume(instance)
        }
    }

    func suspend(_ selector: VMSelector) async throws {
        try await suspend(try resolve(selector))
    }

    func suspend(_ instance: VMInstance, origin: VMRequestOrigin = .newWork) async throws {
        do {
            try await lifecycle.save(instance, origin: origin)
        } catch {
            #log(
                Self.logger, .error,
                "Failed to save '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw failure(error, verb: .suspend, on: instance)
        }
    }

    // MARK: - Restart

    /// Shuts the guest down and starts it again once its session has ended.
    ///
    /// Composed rather than a VZ operation of its own, so it inherits every
    /// gate and refusal the two verbs already state.
    ///
    /// The boot is a start owed to the end of the session being shut down
    /// (``VMActivity/follow(_:whenSessionEnds:)``): the step that rests the VM
    /// queues it, behind the baseline revert an Ephemeral VM's power-off owes,
    /// so nothing else can be decided against the VM in between and nothing
    /// here waits for the VM to come free. Where the VM lands decides what the
    /// start performs: a power-off normally lands it stopped, but an Ephemeral
    /// VM's baseline revert can hand it back suspended on the baseline's memory
    /// image, and that is the state the mode promises — so the start restores
    /// it rather than booting.
    ///
    /// The power-off is the one wait, and what a `timeout` bounds; without
    /// one it is unbounded, matching what a graceful shutdown means. A guest
    /// whose session is still live when the wait fails is neither restarted
    /// nor terminated behind the user's back: the owed boot is withdrawn. Once
    /// the session has ended, the boot is owed whatever the wait reported, and
    /// is awaited. A VM deleted in the meantime is refused by the bring-up it
    /// would have got.
    ///
    /// A VM still owing its guest the account it was set up with is refused
    /// before the stop. Running is not evidence the window is spent — an
    /// install can finish and the guest be booted into Recovery, which reads no
    /// account — and finding that out after the guest is down would leave the
    /// VM powered off half way through a restart. Another active VM sharing
    /// the machine identity the boot would claim is refused, or asked about,
    /// before the stop for the same reason; `consent` answers it, and the boot
    /// carries that answer.
    ///
    /// A remedy the caller chose for a MAC address conflict is decided before
    /// the stop, on the same terms, and lands between the power-off and the
    /// boot.
    func restart(
        _ selector: VMSelector, timeout: TimeInterval?, consent: Consent,
        macAddressRemedy: MACAddressRemedy? = nil
    ) async throws {
        try Self.requireUsable(timeout)
        let instance = try resolve(selector)
        try require(.restart, on: instance)
        // Before the stop, not at the boot half: a VM still owing its account
        // has a question outstanding, and discovering that after the guest is
        // down leaves it powered off mid-restart. Refused here it keeps
        // running, and the door that can ask answers and restarts again.
        try refuseOwedGuestAccount(instance)
        let identity = VMIdentityOverride(consent)
        let conflict = instance.identityConflict(
            for: .guestStart(.starting(recovery: false)), override: identity)
        let remedy = try macAddressRemedyToTake(
            macAddressRemedy, answering: conflict.map { .refuse(.identityConflict($0)) } ?? .admit,
            on: instance, identity: identity,
            holdingSavedState: instance.ephemeralBaselineSnapshot?.kind == .warm,
            accountFor: nil, verb: .restart)
        if let conflict, remedy == nil {
            throw admissionRefusal(.identityConflict(conflict), on: instance, verb: .restart)
        }
        guard let sessionID = instance.activity.liveSessionID else {
            throw admissionRefusal(.invalidState, on: instance, verb: .restart)
        }
        // A start request, so a second restart's boot owed to the same end
        // joins this one rather than meeting the VM this one brought up.
        let boot = VMFollowUp(scope: .vm, rank: .ordinary, request: .start(recovery: false)) {
            [weak self, weak instance] outcome in
            guard let self, let instance else { throw CancellationError() }
            // Asks nobody: the boot runs once the guest is down, after the
            // call that asked has moved on. The remedy is decided again
            // against where the power-off left the VM.
            let bootIdentity = identity.unattended
            if let taken = try self.macAddressRemedyToTake(
                remedy,
                answering: instance.activity.decide(
                    .start(recovery: false), posture: .commit, identity: bootIdentity),
                on: instance, identity: bootIdentity, holdingSavedState: instance.hasSaveFile,
                accountFor: false, verb: .restart)
            {
                try self.takeMACAddressRemedy(taken, on: instance, verb: .restart)
            }
            try self.startNow(instance, policy: .command(bootIdentity), resolving: outcome)
        }
        instance.activity.follow(boot, whenSessionEnds: sessionID)
        do {
            try await stop(instance, disposition: .graceful, consent: .all)
            try await awaitPowerOff(instance, within: timeout, verb: .restart)
        } catch {
            // The session ending is what the boot is owed to, so once it has
            // ended the boot is under way whatever this wait reported.
            guard instance.activity.liveSessionID != sessionID else {
                instance.activity.withdraw(boot)
                throw error
            }
        }
        do {
            try await boot.outcome.value()
        } catch {
            throw bringUpFailure(error, verb: .start, on: instance)
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
        try require(.open, on: instance)
        ActivationRequester.requestActivation()
        surfaceDisplay?(instance)
    }

    // MARK: - Reveal

    /// Brings the VM — or the arrival still writing one — in front of the user
    /// whatever state it is in.
    ///
    /// The branch is the ``VMCapability/open`` gate rather than a display test
    /// of its own, so a VM whose display is not the right thing to surface
    /// lands on its library row instead, by the same predicate that refuses it
    /// an ``open(_:)``. An arrival has no display, so it always lands there.
    func reveal(_ selector: VMSelector) throws {
        let instance: VMInstance
        switch try resolveEntry(selector) {
        case .arriving(let arrival):
            ActivationRequester.requestActivation()
            revealInLibrary?(arrival.id)
            return
        case .vm(let found):
            instance = found
        }
        try require(.reveal, on: instance)
        ActivationRequester.requestActivation()
        if capabilities.accepts(.open, on: instance) {
            surfaceDisplay?(instance)
        } else {
            revealInLibrary?(instance.id)
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
