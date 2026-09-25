import Foundation
import KernovaKit
import KernovaLogging
import Virtualization

/// The library verbs — create, clone, rename, delete, import, and the cancel
/// that stops any of them still writing a bundle.
extension VMCommandCore {
    // MARK: - Bounded Copies

    /// Bounds the blocking bundle copies import and clone run.
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
        switch library.updateConfiguration(
            of: instance, mutate: { $0.name = trimmed })
        {
        case .saved:
            return
        case .refused(let refusal):
            throw refusalError(refusal, on: instance)
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
            guard let failure = arrivalFailure(error, of: arrival) else {
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
                guard let self, let failure = self.arrivalFailure(error, of: arrival) else { return }
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
        do {
            bundleURL = try storageService.bundleURL(for: configuration)
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
        let arrival = library.beginArrival(
            kind: .creating, configuration: configuration, destination: bundleURL,
            write: { staged in
                // Off the bounded `copyQueue`, which exists to serialize the
                // multi-gigabyte `copyItem` calls clone and import make: this
                // write is a `createDirectory` and one small atomic
                // `config.json`, and queueing it behind two in-flight imports
                // would hold the new VM at "Creating…" for their copies.
                try await Task.detached {
                    try storage.createVMBundle(at: staged)
                    try VMBundleFiles(url: staged, access: storage.bundleFiles)
                        .writeInitial(configuration)
                }.value
                try await diskImages.createDiskImage(
                    at: VMBundleLayout(bundleURL: staged).diskImageURL, sizeInGB: diskSizeInGB)
            })
        followUnwaited(arrival) { [weak self] instance in
            #log(
                Self.logger, .notice,
                "Created VM '\(name, privacy: .public)' (status: \(instance.status.displayName, privacy: .public))"
            )
            guard startAfterCreate, let self else { return }
            #log(Self.logger, .notice, "Auto-starting new VM '\(name, privacy: .public)'")
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
        return summary(arrival)
    }

    // MARK: - Clone

    @discardableResult
    func clone(
        _ selector: VMSelector, machineIdentity: CloneMachineIdentity, waitForOutcome: Bool
    ) async throws -> VMSummary {
        guard waitForOutcome else { return try beginClone(selector, machineIdentity: machineIdentity) }
        return summary(
            try await awaitOutcome(of: registerClone(selector, machineIdentity: machineIdentity)))
    }

    @discardableResult
    func beginClone(
        _ selector: VMSelector, machineIdentity: CloneMachineIdentity
    ) throws -> VMSummary {
        let arrival = try registerClone(selector, machineIdentity: machineIdentity)
        followUnwaited(arrival)
        return summary(arrival)
    }

    /// Registers a clone's arrival and starts its copy, with no suspension point
    /// between the checks and the registration.
    private func registerClone(
        _ selector: VMSelector, machineIdentity: CloneMachineIdentity
    ) throws -> VMArrival {
        let instance = try resolve(selector)
        try require(.clone, on: instance)

        let generateNewID: Bool
        switch machineIdentity {
        case .followPreference: generateNewID = preferences.cloneGeneratesNewMachineID
        case .new: generateNewID = true
        case .keep: generateNewID = false
        }

        // Arrivals included, so two clones taken in quick succession never pick
        // the same name.
        let existingNames = library.entries.map(\.name)
        var clonedConfig = instance.configuration.clonedForNewInstance(existingNames: existingNames)

        clonedConfig.macAddress = GuestMACAddress.random()

        if generateNewID {
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
            // clone through `filesToCopy` below, untouched here.
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

        // The bundle disk is copied only while the source still references it:
        // a `Disk.asif` removed entry-only would otherwise ride into the clone
        // unreferenced.
        var filesToCopy =
            instance.effectiveStorageDisks.contains {
                ConfigurationBuilder.isMainBundleDisk($0, layout: instance.bundleLayout)
            } ? ["Disk.asif"] : []
        switch clonedConfig.guestOS {
        case .macOS:
            filesToCopy.append(contentsOf: ["AuxiliaryStorage", "HardwareModel"])
            if !generateNewID {
                filesToCopy.append("MachineIdentifier")
            }
        case .linux:
            if clonedConfig.bootMode == .efi {
                filesToCopy.append("EFIVariableStore")
            }
        }

        // `Disk.asif` lives at a fixed relative path, so only
        // `AdditionalDisks/<id>.asif` entries need remapping — their cloned ids
        // differ from the originals.
        let originalDisks = instance.configuration.storageDisks ?? []
        let clonedDisks = clonedConfig.storageDisks ?? []
        let internalDiskMapping: [(sourceID: UUID, clonedDisk: StorageDisk)] = zip(
            originalDisks, clonedDisks
        )
        .compactMap { original, cloned in
            guard cloned.isInternal,
                cloned.path.hasPrefix(VMBundleLayout.additionalDisksRelativePath + "/")
            else { return nil }
            return (sourceID: original.id, clonedDisk: cloned)
        }

        let bundleURL: URL
        do {
            bundleURL = try storageService.bundleURL(for: clonedConfig)
        } catch {
            #log(
                Self.logger, .error,
                "Failed to derive bundle URL for clone of '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw CommandError.operationFailed(verb: .clone, message: error.localizedDescription)
        }

        let sourceBundleURL = instance.bundleURL
        let sourceName = instance.name
        let config = clonedConfig
        let storage = storageService
        let diskMapping = internalDiskMapping
        let bundleFilesToCopy = filesToCopy
        return library.beginArrival(
            kind: .cloning(sourceID: instance.id), configuration: clonedConfig,
            destination: bundleURL,
            // Everything the clone writes lands in `staged`, the disk remap
            // included: the remap is what makes the cloned configuration name the
            // files beside it, so it has to precede publication rather than land
            // on a bundle the library can already read.
            write: { staged in
                let log = Self.logger
                let skippedDiskIDs: Set<UUID> = try await Self.runBoundedCopy {
                    try storage.cloneVMBundle(
                        from: sourceBundleURL, to: staged, filesToCopy: bundleFilesToCopy)

                    if let machineIDData = config.machineIdentifierData, config.guestOS == .macOS {
                        let layout = VMBundleLayout(bundleURL: staged)
                        try machineIDData.write(to: layout.machineIdentifierURL, options: .atomic)
                    }

                    var skipped: Set<UUID> = []
                    if !diskMapping.isEmpty {
                        let sourceLayout = VMBundleLayout(bundleURL: sourceBundleURL)
                        let destLayout = VMBundleLayout(bundleURL: staged)
                        let fm = FileManager.default
                        try fm.createDirectory(
                            at: destLayout.additionalDisksDirectoryURL,
                            withIntermediateDirectories: true)
                        for mapping in diskMapping {
                            let sourceFile = sourceLayout.additionalDiskURL(id: mapping.sourceID)
                            let destFile = destLayout.additionalDiskURL(id: mapping.clonedDisk.id)
                            if fm.fileExists(atPath: sourceFile.path(percentEncoded: false)) {
                                try fm.copyItem(at: sourceFile, to: destFile)
                            } else {
                                #log(
                                    log, .warning,
                                    "Internal disk '\(mapping.clonedDisk.label, privacy: .public)' source file missing at '\(sourceFile.lastPathComponent, privacy: .public)' — removing from clone"
                                )
                                skipped.insert(mapping.clonedDisk.id)
                            }
                        }
                    }
                    return skipped
                }

                // The one configuration the clone writes: remapped onto the
                // disks the copy wrote, when it copied any.
                let stagedFiles = VMBundleFiles(url: staged, access: storage.bundleFiles)
                // `clonedForNewInstance` gives every disk a fresh `id` but copies its
                // `path` verbatim, while the copy above wrote each file to
                // `AdditionalDisks/<new-id>.asif` — without this remap, boot-time
                // resolution looks for the source bundle's id and fails with
                // `storageDiskNotFound`.
                guard !diskMapping.isEmpty else {
                    try stagedFiles.writeInitial(config)
                    return
                }
                let remappedPaths: [UUID: String] = Dictionary(
                    uniqueKeysWithValues: diskMapping.map { mapping in
                        (
                            mapping.clonedDisk.id,
                            VMBundleLayout.additionalDiskRelativePath(id: mapping.clonedDisk.id)
                        )
                    }
                )
                let remapped: [StorageDisk] =
                    config.storageDisks?
                    .filter { !skippedDiskIDs.contains($0.id) }
                    .map { disk in
                        guard let newPath = remappedPaths[disk.id] else { return disk }
                        var updated = disk
                        updated.path = newPath
                        return updated
                    } ?? []
                // An empty list would store `nil`, which re-synthesizes a
                // `Disk.asif` row for a file the copy never wrote — so a
                // clone left with no disk fails instead of publishing.
                guard !remapped.isEmpty else {
                    throw CommandError.operationFailed(
                        verb: .clone,
                        message:
                            "None of the disk files of \u{201C}\(sourceName)\u{201D} could be copied, so the clone would have no storage disk."
                    )
                }
                var remappedConfig = config
                remappedConfig.setStorageDisks(remapped)
                try stagedFiles.writeInitial(remappedConfig)
            })
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
                library.selectedID = existing.id
                #log(
                    Self.logger, .info,
                    "VM '\(config.name, privacy: .public)' already in library — selected existing instance"
                )
                return .existing(existing)
            case .arriving(let arrival):
                library.selectedID = arrival.id
                return .joined(arrival)
            case nil:
                break
            }

            let storage = storageService
            return .started(
                library.beginArrival(
                    kind: .importing, configuration: config,
                    destination: library.reserveDestination(for: sourceURL, in: vmsDir),
                    write: { staged in
                        try await Self.runBoundedCopy {
                            try FileManager.default.copyItem(at: sourceURL, to: staged)
                            // Auto-start is the one setting that runs a guest with
                            // no user action, so it is local intent rather than
                            // something a bundle carries in: a VM arriving
                            // pre-marked would boot on the next launch without
                            // ever being asked for. The local user marks it.
                            try VMBundleFiles(url: staged, access: storage.bundleFiles).update(
                                .hostState
                            ) {
                                $0.startsAutomaticallyOnLaunch = false
                            }
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
    func cancelPreparing(_ selector: VMSelector, confirmed: Bool) throws {
        let arrival: VMArrival
        switch try resolveEntry(selector) {
        case .vm(let instance): throw invalidState(instance)
        case .arriving(let found): arrival = found
        }
        guard confirmed else {
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
        _ selector: VMSelector, permanently: Bool, alsoRemoving: Set<UUID>, confirmed: Bool
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
        guard confirmed else {
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
        do {
            try await instance.activity.perform(.deleting) { _ in
                do {
                    if permanently {
                        try storageService.permanentlyDeleteVMBundle(at: instance.bundleURL)
                    } else {
                        try storageService.deleteVMBundle(at: instance.bundleURL)
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
                for attachment in toDelete {
                    await trashExternalFile(
                        at: URL(fileURLWithPath: attachment.path),
                        bookmark: attachment.reference.bookmark,
                        label: attachment.label,
                        vmName: vmName,
                        verb: .delete,
                        permanently: permanently)
                }
                // Dropped in the step that removes the VM, with nothing
                // suspending in between.
                library.evict(instance)
                library.persistOrder()
                return .removed(())
            }
        } catch {
            throw failure(error, verb: .delete, on: instance)
        }
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
            message:
                "\(name) moves to the Trash with \(taken)\(externalsClause). Restore them with "
                + "Finder's Put Back, or empty the Trash to delete them permanently.",
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
