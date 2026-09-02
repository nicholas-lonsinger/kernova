import Foundation
import KernovaKit
import Virtualization

/// The library verbs — create, clone, rename, delete, import, and the cancel
/// that undoes any of them still writing a bundle.
extension VMCommandCore {
    // MARK: - Bounded Copies

    /// Bounds the blocking bundle copies import and clone run.
    ///
    /// Uncapped, a large multi-select drop would spawn N concurrent blocking
    /// `FileManager` calls on Swift's cooperative pool and saturate it. The cap is
    /// deliberately small — copies serialize at the device anyway, so a low bound
    /// avoids cross-volume disk thrash without losing throughput.
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
        Self.logger.debug(
            "Renaming '\(instance.name, privacy: .public)' to '\(trimmed, privacy: .public)'")
        guard library.updateConfiguration(of: instance, mutate: { $0.name = trimmed }) else {
            // The new name is in memory but not on disk, so the next library
            // read takes it back. Answering `ok` here would report a rename the
            // user is about to lose.
            throw CommandError.operationFailed(
                verb: .rename,
                message:
                    "\u{201C}\(instance.name)\u{201D} could not be renamed — the change was not saved."
            )
        }
    }

    // MARK: - Create

    @discardableResult
    func create(configuration: VMConfiguration, startAfterCreate: Bool) throws -> VMSummary {
        let bundleURL: URL
        do {
            bundleURL = try storageService.bundleURL(for: configuration)
        } catch {
            Self.logger.error(
                "Failed to derive bundle URL for new VM '\(configuration.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw CommandError.operationFailed(verb: .create, message: error.localizedDescription)
        }

        let phantom = VMInstance(
            configuration: configuration, bundleURL: bundleURL,
            phase: VMLibrary.initialPhase(
                for: configuration, layout: VMBundleLayout(bundleURL: bundleURL)),
            preferences: preferences)

        let storage = storageService
        let diskImages = diskImageService
        let diskSizeInGB = configuration.diskSizeInGB
        let name = configuration.name
        library.prepareBundle(
            phantom, operation: .creating,
            copyWork: { staged in
                // Off the bounded `copyQueue`, which exists to serialize the
                // multi-gigabyte `copyItem` calls clone and import make: this
                // write is a `createDirectory` and one small atomic
                // `config.json`, and queueing it behind two in-flight imports
                // would hold the new VM at "Creating…" for their copies.
                try await Task.detached { try storage.createVMBundle(configuration, at: staged) }
                    .value
                try await diskImages.createDiskImage(
                    at: VMBundleLayout(bundleURL: staged).diskImageURL, sizeInGB: diskSizeInGB)
            },
            onSuccess: { [weak self] in
                Self.logger.notice(
                    "Created VM '\(name, privacy: .public)' (status: \(phantom.status.displayName, privacy: .public))"
                )
                guard startAfterCreate, let self else { return }
                Self.logger.notice("Auto-starting new VM '\(name, privacy: .public)'")
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.start(phantom)
                    } catch let failure as CommandError {
                        self.report(failure, on: phantom)
                    } catch {
                        self.report(
                            .operationFailed(verb: .start, message: error.localizedDescription),
                            on: phantom)
                    }
                }
            },
            onFailure: { [weak self] error in
                self?.reportPreparingFailure(error, verb: .create, phantom: phantom)
            })
        return summary(phantom)
    }

    // MARK: - Clone

    @discardableResult
    func clone(_ selector: VMSelector, machineIdentity: CloneMachineIdentity) throws -> VMSummary {
        let instance = try resolve(selector)
        try require(.clone, on: instance)

        let generateNewID: Bool
        switch machineIdentity {
        case .followPreference: generateNewID = preferences.cloneGeneratesNewMachineID
        case .new: generateNewID = true
        case .keep: generateNewID = false
        }

        let existingNames = library.instances.map(\.configuration.name)
        var clonedConfig = instance.configuration.clonedForNewInstance(existingNames: existingNames)

        clonedConfig.macAddress = VZMACAddress.randomLocallyAdministered().string

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
                Self.logger.notice(
                    "Clone of '\(instance.name, privacy: .public)' had no machine identifier to keep — generated a new one"
                )
            }
            if clonedConfig.bootMode == .efi || clonedConfig.bootMode == .linuxKernel,
                clonedConfig.genericMachineIdentifierData == nil
            {
                clonedConfig.genericMachineIdentifierData =
                    VZGenericMachineIdentifier().dataRepresentation
                Self.logger.notice(
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
            guard cloned.isInternal, cloned.path.hasPrefix("AdditionalDisks/") else { return nil }
            return (sourceID: original.id, clonedDisk: cloned)
        }

        let bundleURL: URL
        do {
            bundleURL = try storageService.bundleURL(for: clonedConfig)
        } catch {
            Self.logger.error(
                "Failed to derive bundle URL for clone of '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw CommandError.operationFailed(verb: .clone, message: error.localizedDescription)
        }

        let phantom = VMInstance(
            configuration: clonedConfig, bundleURL: bundleURL, preferences: preferences)

        let sourceBundleURL = instance.bundleURL
        let sourceName = instance.name
        let config = clonedConfig
        let storage = storageService
        let diskMapping = internalDiskMapping
        let bundleFilesToCopy = filesToCopy
        library.prepareBundle(
            phantom, operation: .cloning,
            // Everything the clone writes lands in `staged`, the disk remap
            // included: the remap is what makes the cloned configuration name the
            // files beside it, so it has to precede publication rather than land
            // on a bundle the library can already read.
            copyWork: { staged in
                let log = Self.logger
                let skippedDiskIDs: Set<UUID> = try await Self.runBoundedCopy {
                    try storage.cloneVMBundle(
                        from: sourceBundleURL, to: staged, newConfiguration: config,
                        filesToCopy: bundleFilesToCopy)

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
                                log.warning(
                                    "Internal disk '\(mapping.clonedDisk.label, privacy: .public)' source file missing at '\(sourceFile.lastPathComponent, privacy: .public)' — removing from clone"
                                )
                                skipped.insert(mapping.clonedDisk.id)
                            }
                        }
                    }
                    return skipped
                }

                // `clonedForNewInstance` gives every disk a fresh `id` but copies its
                // `path` verbatim, while the copy above wrote each file to
                // `AdditionalDisks/<new-id>.asif` — without this remap, boot-time
                // resolution looks for the source bundle's id and fails with
                // `storageDiskNotFound`.
                if !diskMapping.isEmpty {
                    let remappedPaths: [UUID: String] = Dictionary(
                        uniqueKeysWithValues: diskMapping.map { mapping in
                            (
                                mapping.clonedDisk.id,
                                "AdditionalDisks/\(mapping.clonedDisk.id.uuidString).asif"
                            )
                        }
                    )
                    let remapped: [StorageDisk] =
                        phantom.configuration.storageDisks?
                        .filter { !skippedDiskIDs.contains($0.id) }
                        .map { disk in
                            guard let newPath = remappedPaths[disk.id] else { return disk }
                            var updated = disk
                            updated.path = newPath
                            return updated
                        } ?? []
                    phantom.configuration.setStorageDisks(remapped)
                    try storage.saveConfiguration(phantom.configuration, to: staged)
                }
            },
            onSuccess: {
                Self.logger.notice(
                    "Cloned VM '\(sourceName, privacy: .public)' as '\(config.name, privacy: .public)'"
                )
            },
            onFailure: { [weak self] error in
                self?.reportPreparingFailure(error, verb: .clone, phantom: phantom)
            })
        return summary(phantom)
    }

    // MARK: - Import

    /// Reserves a collision-free destination for one `.kernova` bundle, registers its phantom row
    /// synchronously, and spawns the file copy — answering the existing row when the source is
    /// already in the library by UUID.
    ///
    /// Synchronous by design, all the way to the copy `Task`: a batch's reservations — and two
    /// overlapping triggers' — run atomically on the MainActor and see each other's phantoms in
    /// `instances`, which one suspension point between them would break. The copies then run
    /// concurrently.
    @discardableResult
    func importVM(from sourceURL: URL) throws -> VMSummary {
        do {
            let vmsDir = try storageService.vmsDirectory
            var config = try storageService.loadConfiguration(from: sourceURL)

            // Auto-start is the one setting that runs a guest with no user
            // action, so it is local intent rather than something a bundle
            // carries in: a VM arriving pre-marked would boot on the next
            // launch without ever being asked for. The local user marks it.
            let arrivedMarkedForAutoStart = config.startsAutomaticallyOnLaunch
            config.startsAutomaticallyOnLaunch = false

            // Already in the library by UUID (including a source already inside the VMs
            // directory) — select it rather than re-importing.
            if let existing = library.instances.first(where: { $0.id == config.id }) {
                library.selectedID = existing.id
                Self.logger.info(
                    "VM '\(config.name, privacy: .public)' already in library — selected existing instance"
                )
                return summary(existing)
            }

            // The save file has to come from the source bundle — the destination doesn't exist yet.
            let sourceLayout = VMBundleLayout(bundleURL: sourceURL)
            let initialPhase = VMLibrary.initialPhase(for: config, layout: sourceLayout)

            let destinationURL = library.reserveDestination(for: sourceURL, in: vmsDir)
            let phantom = VMInstance(
                configuration: config, bundleURL: destinationURL, phase: initialPhase,
                preferences: preferences)

            let storage = storageService
            let sanitizedConfig = config
            library.prepareBundle(
                phantom, operation: .importing,
                copyWork: { staged in
                    try await Self.runBoundedCopy {
                        try FileManager.default.copyItem(at: sourceURL, to: staged)
                    }
                    // The copy reproduces the source `config.json` verbatim, so
                    // the cleared flag only reaches disk by writing it back.
                    if arrivedMarkedForAutoStart {
                        try storage.saveConfiguration(sanitizedConfig, to: staged)
                    }
                },
                onSuccess: { [weak self] in
                    // The phantom was wired before its bundle existed, so any
                    // snapshots that arrived with the copy are read now.
                    self?.reloadSnapshots(for: phantom)
                    Self.logger.notice(
                        "Imported VM '\(config.name, privacy: .public)' from \(sourceURL.lastPathComponent, privacy: .public)"
                    )
                },
                onFailure: { [weak self] error in
                    self?.reportPreparingFailure(error, verb: .importVM, phantom: phantom)
                })
            return summary(phantom)
        } catch {
            Self.logger.error(
                "Failed to import VM from \(sourceURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw CommandError.operationFailed(verb: .importVM, message: error.localizedDescription)
        }
    }

    // MARK: - Cancel Preparing

    /// Stops a clone or import that is still copying, and removes what it has
    /// written.
    ///
    /// The copy can settle while the confirmation is up, so a confirmed cancel
    /// covers both: an in-flight copy is marked "Cancelling…" for the copy task
    /// to clean up, and a settled one is cleaned up here — the row removed and
    /// the finished bundle trashed. Only an unconsented cancel needs a copy in
    /// flight, because that is what there is a confirmation to describe.
    ///
    /// The settled cleanup is gated exactly as ``delete(_:permanently:alsoRemoving:confirmed:)``
    /// is, and for the same reason: the sheet leaves the menu key equivalents
    /// live, so the finished clone can have been started before the confirm
    /// landed, and trashing its bundle would pull the disks out from under a
    /// guest that is running or about to be.
    func cancelPreparing(_ selector: VMSelector, confirmed: Bool) throws {
        let instance = try resolve(selector)
        guard confirmed else {
            try require(.cancelPreparing, on: instance)
            guard let state = instance.preparingState else { throw invalidState(instance) }
            throw CommandError.confirmationRequired(
                Self.cancelPreparingPrompt(state.operation, on: instance))
        }
        guard var state = instance.preparingState else {
            try require(.delete, on: instance)
            guard !lifecycle.hasActiveOperation(for: instance.id) else {
                throw CommandError.busy(
                    vm: summary(instance), operation: instance.status.displayName.lowercased())
            }
            Self.logger.notice(
                "Cancel confirmed after the copy settled for '\(instance.name, privacy: .public)' — removing the row and trashing the bundle"
            )
            library.cleanupPhantomInstance(instance)
            return
        }
        guard !state.isCancelling else { return }  // already cancelling

        // Mark the row "Cancelling…" but keep it in `instances`: the copy is uninterruptible, so
        // removing it now would race the still-writing copy and briefly drop `hasPreparing`,
        // letting reconcile resurrect the bundle. The copy task cleans up once it settles.
        state.task.cancel()
        state.isCancelling = true
        instance.preparingState = state

        Self.logger.notice(
            "Cancelling \(state.operation.displayNoun, privacy: .public) for '\(instance.name, privacy: .public)'"
        )
    }

    /// The refusal a create, clone or import cancel raises.
    static func cancelPreparingPrompt(
        _ operation: VMInstance.PreparingOperation, on instance: VMInstance
    ) -> ConfirmationPrompt {
        ConfirmationPrompt(
            kind: .cancelPreparing,
            title: operation.cancelAlertTitle,
            message:
                "The operation will be stopped and any partially copied files will be removed.",
            confirmTitle: operation.cancelLabel,
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
        guard !lifecycle.hasActiveOperation(for: instance.id) else {
            throw CommandError.busy(
                vm: summary(instance), operation: instance.status.displayName.lowercased())
        }
        guard confirmed else {
            throw CommandError.confirmationRequired(
                Self.deletePrompt(instance, permanently: permanently))
        }

        var toDelete: [ExternalAttachment] = []
        if !alsoRemoving.isEmpty {
            toDelete = await externalAttachments(for: instance).filter {
                alsoRemoving.contains($0.id) && !$0.isShared
            }
            // Resolving the externals suspends, and the sheet's key equivalents
            // stay live, so both gates run again on the far side of it — a Start
            // that landed in the gap must still refuse. Nothing between here and
            // the bundle delete suspends.
            try require(.delete, on: instance)
            guard !lifecycle.hasActiveOperation(for: instance.id) else {
                throw CommandError.busy(
                    vm: summary(instance), operation: instance.status.displayName.lowercased())
            }
        }
        do {
            if permanently {
                try storageService.permanentlyDeleteVMBundle(at: instance.bundleURL)
            } else {
                try storageService.deleteVMBundle(at: instance.bundleURL)
            }
        } catch {
            Self.logger.error(
                "Failed to delete VM '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw CommandError.operationFailed(verb: .delete, message: error.localizedDescription)
        }
        // Ordered after the delete, which throws on a volume with no Trash or a
        // bundle another process holds: `canDelete` admits a suspended VM, and
        // one that survives a failed delete has to keep naming the slot still
        // sitting in its bundle — resting stopped early would take Resume away
        // and stamp a later capture as disks-only. Nothing live can reach here,
        // so the teardown releases a stale context rather than a running VM.
        instance.tearDownSession(restingAt: .stopped)
        cleanupSetupResumeData(for: instance, permanently: permanently)
        lifecycle.clearActiveOperation(for: instance.id)
        library.evict(instance)
        library.persistOrder()
        if permanently {
            Self.logger.notice("Permanently deleted VM '\(instance.name, privacy: .public)'")
        } else {
            Self.logger.notice("Moved VM '\(instance.name, privacy: .public)' to Trash")
        }
        // Externals go *after* the bundle, so the VM disappears from the
        // library even if one of these fails.
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
    }

    /// The refusal a VM delete raises.
    static func deletePrompt(_ instance: VMInstance, permanently: Bool) -> ConfirmationPrompt {
        ConfirmationPrompt(
            kind: .deleteVM,
            title: permanently
                ? "Delete \u{201C}\(instance.name)\u{201D} Immediately?"
                : "Move \u{201C}\(instance.name)\u{201D} to the Trash?",
            message: permanently
                ? "The virtual machine bundle is deleted immediately, bypassing the Trash. External files are only removed when you name them."
                : "The virtual machine bundle is moved to the Trash. External files are only moved when you name them.",
            confirmTitle: permanently ? "Delete Immediately" : "Move to Trash",
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
        Self.logger.notice(
            "Discarded in-progress download bundle for deleted VM '\(instance.name, privacy: .public)'"
        )
    }

    // MARK: - Attachment Projections

    /// The VM's in-bundle (internal) disks, shown read-only in the delete
    /// sheet's "Removed with the VM" section.
    func bundledDisks(for instance: VMInstance) -> [StorageDisk] {
        instance.effectiveStorageDisks.filter(\.isInternal)
    }

    /// The references behind ``externalAttachments(for:)`` — the kinds
    /// ``ExternalFileReference/Kind/isOfferedOnVMDelete`` admits, less the
    /// bundled Guest Agent installer DMG.
    ///
    /// The DMG's path points *inside the app bundle*, so trashing it would
    /// corrupt the app for every VM.
    private func offeredExternalReferences(for instance: VMInstance) -> [ExternalFileReference] {
        let agentPath = Self.guestAgentInstallerPath
        return instance.configuration.externalFileReferences
            .filter { $0.kind.isOfferedOnVMDelete && $0.path != agentPath }
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

    /// `true` when `item` is the bundled Guest Agent installer DMG.
    ///
    /// The installer lives *inside the app bundle*, so a "remove" of it must only
    /// detach the entry and never trash the file.
    func isGuestAgentInstaller(_ item: RemovableMediaItem) -> Bool {
        guard let agentPath = Self.guestAgentInstallerPath else { return false }
        return item.path == agentPath
    }

    /// Filesystem path of the bundled Guest Agent installer DMG, if present.
    ///
    /// Resolved at the call site (not cached) so it always reflects the running app
    /// bundle's location.
    static var guestAgentInstallerPath: String? {
        KernovaMacOSAgentInfo.installerDiskImageURL?.path(percentEncoded: false)
    }

    /// `true` when the bundled Guest Agent installer DMG is currently in this
    /// VM's `removableMedia` list (live-attached, pending attach, or cold).
    func isGuestAgentInstallerMounted(on instance: VMInstance) -> Bool {
        guard let path = Self.guestAgentInstallerPath else { return false }
        return (instance.configuration.removableMedia ?? []).contains { $0.path == path }
    }
}
