import Foundation
import KernovaKit
import KernovaLogging
import Virtualization

/// The library verbs — create, clone, rename, delete, import, and the cancel
/// that stops any of them still writing a bundle.
extension VMCommandCore {
    // MARK: - Bounded Copies

    /// Bounds the blocking bundle copies import runs.
    ///
    /// Uncapped, a large multi-select drop would spawn N concurrent blocking
    /// `FileManager` calls on Swift's cooperative pool and saturate it. The cap is
    /// small: copies serialize at the device anyway, so a low bound avoids
    /// cross-volume disk thrash without losing throughput.
    private static let copyQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// Runs blocking file work off the cooperative pool on the bounded
    /// ``copyQueue``, awaiting its result.
    static func runBoundedCopy<T: Sendable>(
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            copyQueue.addOperation {
                continuation.resume(with: Result(catching: work))
            }
        }
    }

    // MARK: - Rename

    /// Renames a VM; an empty or unchanged name is a no-op.
    ///
    /// What the rename takes is wider than what the sidebar and the settings
    /// pane offer — ``VMCapabilityCatalog/accepts(_:on:)`` states the split.
    func rename(_ selector: VMSelector, to newName: String) throws {
        let instance = try resolve(selector)
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != instance.name else { return }
        try require(.rename, on: instance)
        #log(
            Self.logger, .debug,
            "Renaming '\(instance.name, privacy: .public)' to '\(trimmed, privacy: .public)'")
        let write = try edit(VMCapability.rename, on: instance, verb: .rename) { permit in
            library.updateConfiguration(permit) { $0.name = trimmed }
        }
        switch write {
        case .saved:
            return
        case .refused(let refusal):
            throw refusalError(refusal, on: instance, verb: .rename)
        case .notSaved:
            throw CommandError.operationFailed(
                verb: .rename,
                message:
                    "\u{201C}\(instance.name)\u{201D} could not be renamed — the change was not saved."
            )
        }
    }

    // MARK: - Arrival Outcomes

    /// The outcome of `arrival` for the caller that waits on it: the VM its
    /// bundle became, or the failure thrown here — and reported nowhere else,
    /// unless the waiter has gone by the time it settles. The event stream
    /// already carries the failure (``arrivalFailed(_:with:)``).
    ///
    /// Awaiting ``VMArrival/settled`` does not return early when the waiting
    /// task is cancelled, so whether the waiter is still there is read after
    /// the outcome is known. A cancel the user took throws and reports nothing.
    func awaitOutcome(of arrival: VMArrival) async throws -> VMInstance {
        do {
            return try await arrival.settled.value
        } catch {
            guard let failure = arrival.failure(for: error) else {
                throw CommandError.operationFailed(
                    verb: arrival.kind.verb,
                    message: "The \(arrival.kind.displayNoun.lowercased()) was cancelled.")
            }
            if Task.isCancelled { report(failure, on: nil) }
            throw failure
        }
    }

    /// Routes the outcome of an arrival nobody waits on: a failure is
    /// reported, and a VM is handed to `onSettled`.
    func followUnwaited(
        _ arrival: VMArrival, onSettled: (@MainActor (VMInstance) async -> Void)? = nil
    ) {
        Task { [weak self] in
            do {
                let instance = try await arrival.settled.value
                await onSettled?(instance)
            } catch {
                guard let self, let failure = arrival.failure(for: error) else { return }
                self.report(failure, on: nil)
            }
        }
    }

    // MARK: - Create

    @discardableResult
    func create(
        configuration: VMConfiguration, startAfterCreate: Bool,
        guestAccountPassword: String?
    ) throws -> VMSummary {
        let bundleURL: URL
        let staged: VMStagedBundle
        do {
            bundleURL = try storageService.bundleURL(for: configuration)
            staged = try VMStagedBundle.mint(in: storageService)
        } catch {
            #log(
                Self.logger, .error,
                "Failed to derive bundle URL for new VM '\(configuration.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw CommandError.operationFailed(verb: .create, message: error.localizedDescription)
        }

        // Before the write, so a password macOS turns down refuses a create that
        // has put nothing on disk. Held whether or not anything is started: the
        // account is owed until a boot spends it, and a Start taken later in the
        // session asks nothing.
        if let guestAccountPassword {
            try holdGuestAccountPassword(
                guestAccountPassword, for: configuration.id, configuredAs: configuration)
        }

        let storage = storageService
        let diskImages = diskImageService
        let diskSizeInGB = configuration.diskSizeInGB
        let name = configuration.name
        let autoStart: @MainActor (VMInstance) -> [VMFollowUp] = { [weak self] instance in
            guard let self else { return [] }
            #log(Self.logger, .notice, "Auto-starting new VM '\(name, privacy: .public)'")
            return [self.startFollowUp(instance, policy: .command(.unavailable))]
        }
        let arrival = library.beginArrival(
            kind: .creating, configuration: configuration, destination: bundleURL,
            staged: staged, source: nil,
            write: { staged in
                // Off the bounded `copyQueue`, which exists to serialize the
                // multi-gigabyte `copyItem` calls import makes: this write is
                // a `createDirectory` and one small atomic `config.json`, and
                // queueing it behind two in-flight imports would hold the new
                // VM at "Creating…" for their copies.
                try await Task.detached {
                    try storage.createVMBundle(at: staged.url)
                    try staged.writeInitial(configuration)
                }.value
                try await diskImages.createDiskImage(
                    at: staged.layout.diskImageURL, sizeInGB: diskSizeInGB)
            },
            whenAdopted: startAfterCreate ? autoStart : nil)
        followUnwaited(arrival) { instance in
            #log(
                Self.logger, .notice,
                "Created VM '\(name, privacy: .public)' (status: \(instance.status.displayName, privacy: .public))"
            )
        }
        return summary(arrival)
    }

    // MARK: - Clone

    @discardableResult
    func clone(
        _ selector: VMSelector, outcome: CloneOutcome?, waitForOutcome: Bool
    ) async throws -> VMSummary {
        guard waitForOutcome else { return try beginClone(selector, outcome: outcome) }
        return summary(
            try await awaitOutcome(of: registerClone(selector, outcome: outcome)))
    }

    @discardableResult
    func beginClone(
        _ selector: VMSelector, outcome: CloneOutcome?
    ) throws -> VMSummary {
        let arrival = try registerClone(selector, outcome: outcome)
        followUnwaited(arrival)
        return summary(arrival)
    }

    /// Holds the source for a clone's copy and registers the clone's arrival,
    /// with no suspension point between the decision and the registration.
    ///
    /// ``VMOperationKind/copyingOut(_:)`` holds the source only while its files
    /// and state are copied into the staged bundle, in the mode the source's
    /// phase admits (``VMAdmission/cloneMode(phase:facts:)``); the arrival's
    /// write then lays down the clone's configuration. An Exact Copy of a
    /// suspended or live source arrives suspended on the source's saved
    /// state, and every other clone arrives stopped.
    private func registerClone(
        _ selector: VMSelector, outcome: CloneOutcome?
    ) throws -> VMArrival {
        let instance = try resolve(selector)

        let resolved = outcome ?? preferences.cloneOutcome(for: instance.configuration)
        guard resolved == .exactCopy || instance.configuration.offersNewMachineClone else {
            throw CommandError.unsupported(capability: "cloning as a New Machine")
        }
        let generateNewID = resolved == .newMachine

        // Arrivals included, so two clones taken in quick succession never pick
        // the same name.
        let existingNames = library.entries.map(\.name)
        var clonedConfig = instance.configuration.clonedForNewInstance(existingNames: existingNames)

        if generateNewID {
            // A source with no address and no device leaves minting to the
            // change that gives the clone one (`applyNetworkMode`).
            clonedConfig.macAddress = nil
            if instance.configuration.macAddress != nil || clonedConfig.networkEnabled {
                clonedConfig.mintMACAddressIfNeeded()
            }
            if clonedConfig.guestOS == .macOS {
                clonedConfig.machineIdentifierData = VZMacMachineIdentifier().dataRepresentation
            }
            if clonedConfig.bootMode == .efi || clonedConfig.bootMode == .linuxKernel {
                clonedConfig.genericMachineIdentifierData =
                    VZGenericMachineIdentifier().dataRepresentation
            }
        } else {
            // Keep mode mints only what there is no identity to keep: a source
            // whose identifier lives in the bundle file alone hands it to the
            // clone through ``CloneCopy``, untouched here.
            if clonedConfig.guestOS == .macOS, instance.effectiveMachineIdentifierData == nil {
                clonedConfig.machineIdentifierData = VZMacMachineIdentifier().dataRepresentation
                #log(
                    Self.logger, .notice,
                    "Clone of '\(instance.name, privacy: .public)' had no machine identifier to keep — generated a new one"
                )
            }
            if clonedConfig.bootMode == .efi || clonedConfig.bootMode == .linuxKernel,
                clonedConfig.genericMachineIdentifierData == nil
            {
                clonedConfig.genericMachineIdentifierData =
                    VZGenericMachineIdentifier().dataRepresentation
                #log(
                    Self.logger, .notice,
                    "Clone of '\(instance.name, privacy: .public)' had no generic machine identifier to keep — generated a new one"
                )
            }
        }

        let bundleURL: URL
        let staged: VMStagedBundle
        do {
            bundleURL = try storageService.bundleURL(for: clonedConfig)
            staged = try VMStagedBundle.mint(in: storageService)
        } catch {
            #log(
                Self.logger, .error,
                "Failed to derive bundle URL for clone of '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw CommandError.operationFailed(verb: .clone, message: error.localizedDescription)
        }

        let machineIdentifier = clonedConfig.guestOS == .macOS ? clonedConfig.machineIdentifierData : nil
        let storage = storageService
        let virtualization = lifecycle.virtualizationService
        // The settled mode, as the catalog offers Clone in: an operation in
        // flight then refuses the copy as busy.
        let mode =
            VMAdmission.settledCloneMode(phase: instance.phase, facts: instance.admissionFacts)
            ?? .stopped
        // Run directly rather than on the bounded `copyQueue`: the source is
        // held for as long as the copy takes, and an APFS clone takes
        // milliseconds where a queued import copy can take minutes.
        let copied: VMOutcome
        do {
            copied = try instance.activity.launchCopyOut(mode) { context in
                let copy = CloneCopy(
                    of: context.operation.instance.bundle, outcome: resolved, mode: context.mode,
                    machineIdentifier: machineIdentifier)
                let source = context.operation.bundle.url
                guard context.mode == .live else {
                    try await Task.detached {
                        try Self.copyOut(
                            copy, .settledAndGuestWritten, from: source, into: staged,
                            storage: storage)
                    }.value
                    return .rest(.asStarted, ())
                }
                // Only what the guest writes is copied inside the pause, so
                // the freeze does not grow with the snapshots an Exact Copy
                // carries.
                let ending = try await virtualization.copyLive(
                    context.operation.instance, context,
                    savingStateTo: staged.layout.saveFileURL,
                    prepare: {
                        try await Task.detached {
                            try Self.copyOut(
                                copy, .settled, from: source, into: staged, storage: storage)
                        }.value
                    },
                    copy: {
                        try await Task.detached {
                            try Self.copyOut(
                                copy, .guestWritten, from: source, into: staged, storage: storage)
                        }.value
                    })
                guard case .rest = ending, !copy.carriesSavedState else { return ending }
                // A New Machine boots cold: the state saved with its disks does
                // not restore under a new machine identifier.
                try await Task.detached {
                    try FileManager.default.removeItem(at: staged.layout.saveFileURL)
                }.value
                return ending
            }
        } catch {
            throw failure(error, verb: .clone, on: instance)
        }

        let config = clonedConfig
        return library.beginArrival(
            kind: .cloning, configuration: clonedConfig, destination: bundleURL, staged: staged,
            source: VMArrival.Source(bundleURL: instance.bundleURL, label: instance.name)
        ) { staged in
            // The copy's failure is the clone's.
            try await copied.value()
            try await Task.detached { try staged.writeInitial(config) }.value
        }
    }

    /// What a clone copies out of its source's bundle, read from the source's
    /// committed state while the clone holds it.
    private struct CloneCopy: Sendable {
        let outcome: CloneOutcome
        /// How the copy is taken, which says where the source's saved state
        /// is: in its suspend slot, in a live guest's memory, or nowhere.
        let mode: VMCaptureMode
        /// The source's configuration, which names the disks to copy.
        let configuration: VMConfiguration
        /// The macOS machine identifier the clone boots as, written over any
        /// the copy brought across.
        let machineIdentifier: Data?
        /// What the clone's own state files start from — the defaults for a
        /// New Machine, the source's for an Exact Copy.
        let hostState: VMHostState
        let snapshotManifest: VMSnapshotManifest

        @MainActor
        init(
            of source: VMBundle, outcome: CloneOutcome, mode: VMCaptureMode,
            machineIdentifier: Data?
        ) {
            self.outcome = outcome
            self.mode = mode
            configuration = source.configuration
            self.machineIdentifier = machineIdentifier
            switch outcome {
            case .newMachine:
                hostState = VMHostState()
                snapshotManifest = VMSnapshotManifest()
            case .exactCopy:
                var carried = source.hostState
                carried.arriveAsCopy()
                hostState = carried
                snapshotManifest = source.snapshotManifest
            }
        }

        /// Whether the clone arrives on its source's saved state: an Exact
        /// Copy of a suspended or live source. A New Machine arrives without
        /// one, as a saved state does not restore under a new machine
        /// identifier.
        var carriesSavedState: Bool { outcome == .exactCopy && mode != .stopped }

        /// The bundle-relative files a running guest writes: its internal
        /// disks and firmware state — what a live copy takes inside its pause.
        func guestWrittenPaths(in source: VMBundleLayout) -> [String] {
            VMBundleMachineFiles.capturedRelativePaths(for: configuration, layout: source)
        }

        /// The bundle-relative files nothing writes while the clone holds its
        /// source: the hardware model for both outcomes, and for an Exact Copy
        /// its machine identifier and every snapshot the manifest lists.
        func settledPaths() -> [String] {
            var paths = [VMBundleLayout.hardwareModelRelativePath]
            if outcome == .exactCopy {
                paths.append(VMBundleLayout.machineIdentifierRelativePath)
                paths += snapshotManifest.snapshots.map {
                    VMBundleLayout.snapshotRelativePath(id: $0.id)
                }
            }
            return paths
        }
    }

    /// Which of a clone's files one ``copyOut(_:_:from:into:storage:)`` takes.
    private enum CloneCopyPart {
        /// The files and state files nothing writes under the hold
        /// (``CloneCopy/settledPaths()``), plus a suspended source's slot.
        case settled
        /// The files a running guest writes (``CloneCopy/guestWrittenPaths(in:)``).
        case guestWritten
        /// Both, for a source with no guest running.
        case settledAndGuestWritten
    }

    /// Clones `part` of what `copy` names out of the bundle at `source` into
    /// `staged`, creating `staged` first if it is not there yet.
    nonisolated private static func copyOut(
        _ copy: CloneCopy, _ part: CloneCopyPart, from source: URL, into staged: VMStagedBundle,
        storage: any VMStorageProviding
    ) throws {
        let sourceLayout = VMBundleLayout(bundleURL: source)
        let paths: [String] =
            switch part {
            case .settled: copy.settledPaths()
            case .guestWritten: copy.guestWrittenPaths(in: sourceLayout)
            case .settledAndGuestWritten:
                copy.guestWrittenPaths(in: sourceLayout) + copy.settledPaths()
            }
        try storage.cloneVMBundle(from: source, to: staged.url, relativePaths: paths)
        guard part != .guestWritten else { return }
        // A live copy's saved state is written into the clone by VZ; a
        // suspended one's is the slot, which admission found on disk and the
        // hold keeps there.
        if copy.carriesSavedState, copy.mode == .suspended {
            try VMBundleMachineFiles.copyItems(
                [VMBundleLayout.saveFileRelativePath], from: source, to: staged.url,
                ifMissing: .unchecked)
        }
        if let machineIdentifier = copy.machineIdentifier {
            try machineIdentifier.write(to: staged.layout.machineIdentifierURL, options: .atomic)
        }
        // After the snapshot directories: reading the manifest back reads each
        // snapshot's own configuration.
        try staged.update(.snapshotManifest) { $0 = copy.snapshotManifest }
        try staged.update(.hostState) { $0 = copy.hostState }
    }

    // MARK: - Import

    /// Copies the `.kernova` bundle at `path` into the library, obtaining the
    /// grant this sandboxed process needs to read it first.
    ///
    /// The awaited grant is the whole of what separates this from
    /// ``importVM(from:waitForOutcome:)``: the reservation it wraps still runs
    /// with no suspension point inside it, so overlapping imports cannot claim
    /// the same destination.
    @discardableResult
    func importVM(atPath path: String, waitForOutcome: Bool) async throws -> VMSummary {
        let source = try await requireSourceAuthority(.importVM)
            .readableURL(for: URL(fileURLWithPath: path), as: .vmBundle)
        return try await importVM(from: source, waitForOutcome: waitForOutcome)
    }

    /// Copies one `.kernova` bundle into the library — answering the existing
    /// VM when the source is already in the library by identifier, and joining
    /// the arrival already importing it when one is.
    @discardableResult
    func importVM(from sourceURL: URL, waitForOutcome: Bool) async throws -> VMSummary {
        guard waitForOutcome else { return try beginImport(from: sourceURL) }
        switch try registerImport(from: sourceURL) {
        case .existing(let instance):
            return summary(instance)
        case .joined(let arrival), .started(let arrival):
            return summary(try await awaitOutcome(of: arrival))
        }
    }

    @discardableResult
    func beginImport(from sourceURL: URL) throws -> VMSummary {
        switch try registerImport(from: sourceURL) {
        case .existing(let instance):
            return summary(instance)
        case .joined(let arrival):
            // Its own initiating call already routes an unwaited outcome.
            return summary(arrival)
        case .started(let arrival):
            followUnwaited(arrival)
            return summary(arrival)
        }
    }

    /// Where an import's source already stands in the library, or the arrival
    /// it started.
    private enum ImportStart {
        case existing(VMInstance)
        case joined(VMArrival)
        case started(VMArrival)
    }

    /// Reserves a collision-free destination for one `.kernova` bundle,
    /// registers its arrival, and starts the copy.
    ///
    /// Synchronous all the way to the registration: a batch's reservations —
    /// and two overlapping triggers' — run atomically on the main actor and see
    /// each other's arrivals, which one suspension point between them would
    /// break. The copies then run concurrently.
    private func registerImport(from sourceURL: URL) throws -> ImportStart {
        do {
            let vmsDir = try storageService.vmsDirectory
            let config = try VMBundleFiles(url: sourceURL, access: storageService.bundleFiles)
                .readConfiguration()

            // Already in the library by UUID (including a source already inside the VMs
            // directory) — select it rather than re-importing.
            switch library.entries.first(where: { $0.id == config.id }) {
            case .vm(let existing):
                library.selectRevealing(existing.id)
                #log(
                    Self.logger, .info,
                    "VM '\(config.name, privacy: .public)' already in library — selected existing instance"
                )
                return .existing(existing)
            case .arriving(let arrival):
                library.selectRevealing(arrival.id)
                return .joined(arrival)
            case nil:
                break
            }

            return .started(
                library.beginArrival(
                    kind: .importing, configuration: config,
                    destination: library.reserveDestination(for: sourceURL, in: vmsDir),
                    staged: try VMStagedBundle.mint(in: storageService),
                    source: .importing(sourceURL),
                    write: { staged in
                        try await Self.runBoundedCopy {
                            try FileManager.default.copyItem(at: sourceURL, to: staged.url)
                            try staged.update(.hostState) { $0.arriveAsCopy() }
                        }
                    }))
        } catch {
            #log(
                Self.logger, .error,
                "Failed to import VM from \(sourceURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw CommandError.operationFailed(verb: .importVM, message: error.localizedDescription)
        }
    }

    // MARK: - Cancel Preparing

    /// Cancels a create, clone or import, which then becomes no VM.
    ///
    /// An arrival still writing is stopped and its staged tree discarded once
    /// the uninterruptible copy settles. One already renaming into the VMs
    /// directory moves its published bundle to the Trash before it settles, so
    /// nothing following its outcome — a waiter, a create's auto-start — ever
    /// receives the VM. A VM is not something being prepared, so a cancel
    /// naming one is refused.
    func cancelPreparing(_ selector: VMSelector, consent: Consent) throws {
        let arrival: VMArrival
        switch try resolveEntry(selector) {
        case .vm(let instance): throw invalidState(instance)
        case .arriving(let found): arrival = found
        }
        guard consent.covers(.cancelPreparing) else {
            guard !arrival.isCancelling else { return }
            throw CommandError.confirmationRequired(Self.cancelPreparingPrompt(arrival.kind))
        }
        switch arrival.requestCancel() {
        case .cancelled:
            #log(
                Self.logger, .notice,
                "Cancelling \(arrival.kind.displayNoun, privacy: .public) for '\(arrival.name, privacy: .public)'"
            )
        case .withdrawn:
            #log(
                Self.logger, .notice,
                "Cancel confirmed while '\(arrival.name, privacy: .public)' was publishing — its bundle moves to the Trash"
            )
        case .alreadyCancelling:
            return
        case .adopted:
            throw invalidState(try resolve(selector))
        }
    }

    /// The refusal a create, clone or import cancel raises.
    static func cancelPreparingPrompt(_ kind: VMArrival.Kind) -> ConfirmationPrompt {
        ConfirmationPrompt(
            kind: .cancelPreparing,
            title: kind.cancelAlertTitle,
            message:
                "The operation will be stopped and any partially copied files will be removed.",
            confirmTitle: kind.cancelLabel,
            dismissTitle: "Continue")
    }

    // MARK: - Delete

    func delete(
        _ selector: VMSelector, permanently: Bool, alsoRemoving: Set<UUID>, consent: Consent
    ) async throws {
        // Resolution is the membership re-check: a delete sheet is window-modal
        // but doesn't disable the menu bar, so two sheets can be queued for the
        // same VM and the second confirm names a VM the first already removed.
        let instance = try resolve(selector)
        // The sheet leaves the menu key equivalents live, so a Start or Resume
        // can land between opening it and confirming, which is what this
        // re-check catches — trashing the bundle then would pull the disk
        // image out from under a guest that is running or about to be.
        try require(.delete, on: instance)
        guard consent.covers(.deleteVM) else {
            throw CommandError.confirmationRequired(
                Self.deletePrompt(
                    instance, permanently: permanently,
                    externals: await externalAttachments(for: instance)))
        }

        var toDelete: [ExternalAttachment] = []
        if !alsoRemoving.isEmpty {
            toDelete = await externalAttachments(for: instance).filter {
                alsoRemoving.contains($0.id) && !$0.isShared
            }
        }
        // One operation from the bundle's removal to the last external file's,
        // so nothing can start the VM, or be decided against it, while its
        // files go — and a Start that landed while the externals resolved is
        // what refuses it here.
        let kept: [FilesKept.File]
        do {
            kept = try await instance.activity.delete { context -> [FilesKept.File] in
                do {
                    if permanently {
                        try storageService.permanentlyDeleteVMBundle(at: context.bundle.url)
                    } else {
                        try storageService.deleteVMBundle(at: context.bundle.url)
                    }
                } catch {
                    #log(
                        Self.logger, .error,
                        "Failed to delete VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                    )
                    throw CommandError.operationFailed(
                        verb: .delete, message: error.localizedDescription)
                }
                cleanupSetupResumeData(for: instance, permanently: permanently)
                if permanently {
                    #log(
                        Self.logger, .notice,
                        "Permanently deleted VM '\(instance.name, privacy: .public)'")
                } else {
                    #log(
                        Self.logger, .notice,
                        "Moved VM '\(instance.name, privacy: .public)' to Trash")
                }
                // Externals go *after* the bundle, so a failure here leaves no
                // VM naming files that are gone.
                let vmName = instance.name
                var kept: [FilesKept.File] = []
                for attachment in toDelete {
                    if let file = await trashExternalFile(
                        at: URL(fileURLWithPath: attachment.path),
                        bookmark: attachment.reference.bookmark,
                        label: attachment.label,
                        vmName: vmName,
                        permanently: permanently)
                    {
                        kept.append(file)
                    }
                }
                // Dropped in the step that removes the VM, with nothing
                // suspending in between.
                library.evict(instance)
                library.persistOrder()
                return kept
            }
        } catch {
            throw failure(error, verb: .delete, on: instance)
        }
        try Self.requireRemoved(kept, after: .vm(name: instance.name, permanently: permanently))
    }

    /// The refusal a VM delete raises, and the copy the delete sheet renders.
    ///
    /// The message enumerates what goes with the bundle, so it names the saved
    /// state and the snapshots when the bundle holds them. `externals` names
    /// the files outside the bundle a caller may choose to take too — a list of
    /// only shared or missing ones offers no choice, so the clause is left out
    /// unless one of them is selectable.
    static func deletePrompt(
        _ instance: VMInstance, permanently: Bool, externals: [ExternalAttachment]
    ) -> ConfirmationPrompt {
        let name = "\u{201C}\(instance.name)\u{201D}"
        var items = ["its disks"]
        if instance.hasSaveFile { items.append("its saved state") }
        if !instance.snapshotManifest.snapshots.isEmpty { items.append("its snapshots") }
        let offersExternals = externals.contains(where: \.isSelectable)

        if permanently {
            // The VM heads the list rather than sitting in front of it, so a
            // bundle holding nothing else reads "X and its disks" instead of
            // splicing two clauses with a comma.
            let deleted = ListFormatter.localizedString(byJoining: [name] + items)
            let externalsClause = offersExternals ? ", plus any external files you choose," : ""
            return ConfirmationPrompt(
                kind: .deleteVM,
                title: "Delete \(name) Immediately?",
                message:
                    "\(deleted)\(externalsClause) will be deleted immediately, bypassing the "
                    + "Trash. You can't undo this action.",
                confirmTitle: "Delete Immediately",
                dismissTitle: "Cancel")
        }
        // Here the VM is the subject of its own sentence, so the list is what
        // travels with it.
        let taken = ListFormatter.localizedString(byJoining: items)
        let externalsClause = offersExternals ? ", and any external files you choose" : ""
        return ConfirmationPrompt(
            kind: .deleteVM,
            title: "Move \(name) to the Trash?",
            message: "\(name) moves to the Trash with \(taken)\(externalsClause).",
            confirmTitle: "Move to Trash",
            dismissTitle: "Cancel")
    }

    /// Trashes any in-progress image download bundle for a VM that's being
    /// deleted.
    ///
    /// Every setup source that fetches its image — a macOS restore image from
    /// any of its three downloading sources, or a Linux installer ISO — writes
    /// the same `.kernovadownload` sidecar, so all of them are covered; the
    /// "delete externals" toggle does not gate it, and the disposition matches
    /// the VM's own. The completed image at `downloadDestinationPath` lives at a
    /// user-known path and is left alone.
    private func cleanupSetupResumeData(for instance: VMInstance, permanently: Bool) {
        if let context = instance.configuration.installContext,
            context.source.downloadsImage,
            let destinationURL = context.downloadDestinationURL
        {
            lifecycle.ipswService.discardResumeData(at: destinationURL, permanently: permanently)
        } else if let destinationURL = instance.configuration.linuxInstallContext?
            .downloadDestinationURL
        {
            lifecycle.downloadService.discardResumeData(
                at: destinationURL, permanently: permanently)
        } else {
            return
        }
        #log(
            Self.logger, .notice,
            "Discarded in-progress download bundle for deleted VM '\(instance.name, privacy: .public)'"
        )
    }

    // MARK: - Attachment Projections

    /// The references behind ``externalAttachments(for:)`` — the kinds
    /// ``ExternalFileReference/Kind/isOfferedOnVMDelete`` admits, less the
    /// bundled Guest Agent installer DMG.
    ///
    /// The DMG's path points *inside the app bundle*, so trashing it would
    /// corrupt the app for every VM.
    private func offeredExternalReferences(for instance: VMInstance) -> [ExternalFileReference] {
        let agentPath = KernovaMacOSAgentInfo.installerPath
        return instance.configuration.externalFileReferences
            .filter { $0.kind.isOfferedOnVMDelete && $0.path != agentPath }
    }

    func externalAttachments(of selector: VMSelector) async throws -> [ExternalAttachment] {
        await externalAttachments(for: try resolve(selector))
    }

    /// The external (non-bundle) files referenced by `instance` that the delete
    /// sheet offers to trash, each annotated with whether it is still there and
    /// which other VMs name the same file.
    ///
    /// One detached pass answers both: the syscalls block, so a stale or
    /// unreachable mount must not reach the main actor. Existence probes go
    /// through each reference's bookmark — a raw check on an out-of-container
    /// path is sandbox-denied and would render every row as missing — and
    /// sharing compares the identity sets ``ExternalFileReference`` derives,
    /// which is what the trash itself acts on.
    func externalAttachments(for instance: VMInstance) async -> [ExternalAttachment] {
        let references = offeredExternalReferences(for: instance)
        guard !references.isEmpty else { return [] }
        let candidates = sharingCandidates(excluding: instance)
        return await Task.detached(priority: .userInitiated) { () -> [ExternalAttachment] in
            let targets = (references + candidates.flatMap(\.references)).resolvedTargets()
            let others = candidates.identified(resolvedTargets: targets)
            let bookmarksByPath = references.bookmarksByPath
            var missingByPath: [String: Bool] = [:]
            var attachments: [ExternalAttachment] = []
            for reference in references {
                let isMissing: Bool
                if let known = missingByPath[reference.path] {
                    isMissing = known
                } else {
                    isMissing = !SecurityScopedBookmark.fileExists(
                        atPath: reference.path, bookmark: bookmarksByPath[reference.path] ?? nil)
                    missingByPath[reference.path] = isMissing
                }
                attachments.append(
                    ExternalAttachment(
                        reference: reference,
                        sharedWithVMNames: Self.sharingVMNames(
                            matching: ExternalFileReference.fileIdentities(
                                forPath: reference.path,
                                resolvedTarget: reference.bookmark.flatMap { targets[$0] }),
                            among: others),
                        isMissing: isMissing))
            }
            return attachments
        }.value
    }

    func sharingVMNames(_ selector: VMSelector, path: String, bookmark: Data?) async throws
        -> [String]
    {
        await sharingVMNames(forPath: path, bookmark: bookmark, excluding: try resolve(selector))
    }

    /// Names of other VMs in the library naming the same file as
    /// `(path, bookmark)`.
    ///
    /// Only external paths count — a bundle-relative one is per-VM by
    /// construction and never reaches the projection. `instance` is excluded so
    /// the file isn't reported as shared with itself.
    ///
    /// The bookmark resolution runs detached: it blocks, and the caller is a
    /// main-actor surface.
    func sharingVMNames(
        forPath path: String, bookmark: Data?, excluding instance: VMInstance
    ) async -> [String] {
        let candidates = sharingCandidates(excluding: instance)
        guard !candidates.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) { () -> [String] in
            var targets = candidates.flatMap(\.references).resolvedTargets()
            if let bookmark, targets[bookmark] == nil,
                let target = SecurityScopedBookmark.resolvedTargetPath(bookmark)
            {
                targets[bookmark] = target
            }
            return Self.sharingVMNames(
                matching: ExternalFileReference.fileIdentities(
                    forPath: path, resolvedTarget: bookmark.flatMap { targets[$0] }),
                among: candidates.identified(resolvedTargets: targets))
        }.value
    }

    /// The names among `candidates` whose files intersect `identities`, in
    /// library order.
    ///
    /// Two VMs name the same file when their identity sets meet at any path —
    /// stored or resolved — which is what lets an unhealed sibling still block
    /// the trash of a file the subject already healed to its new home.
    nonisolated static func sharingVMNames(
        matching identities: Set<String>, among candidates: [(name: String, identities: Set<String>)]
    ) -> [String] {
        candidates.compactMap { $0.identities.isDisjoint(with: identities) ? nil : $0.name }
    }

    /// Every library VM but `instance`, snapshotted for the off-main sharing
    /// comparison.
    private func sharingCandidates(excluding instance: VMInstance)
        -> [ExternalFileReference.SharingCandidate]
    {
        library.instances.compactMap { other in
            guard other.id != instance.id else { return nil }
            return ExternalFileReference.SharingCandidate(
                name: other.name, references: other.configuration.externalFileReferences)
        }
    }
}
