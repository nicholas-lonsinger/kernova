import Foundation
import KernovaKit
import Virtualization

/// The library verbs — clone, rename, delete, import, and the cancel that
/// undoes a clone or import still copying.
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

        var filesToCopy = ["Disk.asif"]
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

        // The main bundle disk lives at a fixed relative path, so only
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
            copyWork: {
                let log = Self.logger
                let skippedDiskIDs: Set<UUID> = try await Self.runBoundedCopy {
                    let resultURL = try storage.cloneVMBundle(
                        from: sourceBundleURL, newConfiguration: config,
                        filesToCopy: bundleFilesToCopy)

                    if let machineIDData = config.machineIdentifierData, config.guestOS == .macOS {
                        let layout = VMBundleLayout(bundleURL: resultURL)
                        try machineIDData.write(to: layout.machineIdentifierURL, options: .atomic)
                    }

                    var skipped: Set<UUID> = []
                    if !diskMapping.isEmpty {
                        let sourceLayout = VMBundleLayout(bundleURL: sourceBundleURL)
                        let destLayout = VMBundleLayout(bundleURL: resultURL)
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
                    phantom.configuration.storageDisks = phantom.configuration.storageDisks?
                        .filter { !skippedDiskIDs.contains($0.id) }
                        .map { disk in
                            guard let newPath = remappedPaths[disk.id] else { return disk }
                            var updated = disk
                            updated.path = newPath
                            return updated
                        }
                    if phantom.configuration.storageDisks?.isEmpty == true {
                        phantom.configuration.storageDisks = nil
                    }
                    try storage.saveConfiguration(phantom.configuration, to: phantom.bundleURL)
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
            let initialStatus = VMLibrary.initialStatus(for: config, layout: sourceLayout)

            let destinationURL = library.reserveDestination(for: sourceURL, in: vmsDir)
            let phantom = VMInstance(
                configuration: config, bundleURL: destinationURL, status: initialStatus,
                preferences: preferences)

            let storage = storageService
            let sanitizedConfig = config
            library.prepareBundle(
                phantom, operation: .importing,
                copyWork: {
                    try await Self.runBoundedCopy {
                        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    }
                    // The copy reproduces the source `config.json` verbatim, so
                    // the cleared flag only reaches disk by writing it back.
                    if arrivedMarkedForAutoStart {
                        try storage.saveConfiguration(sanitizedConfig, to: destinationURL)
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
            guard let state = instance.preparingState else { throw invalidState(instance) }
            throw CommandError.confirmationRequired(
                Self.cancelPreparingPrompt(state.operation, on: instance))
        }
        guard var state = instance.preparingState else {
            guard instance.canDelete else { throw invalidState(instance) }
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

    /// The refusal a clone or import cancel raises.
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
        // can land between opening it and confirming — and a cold resume holds
        // `.paused` with no live VM while it builds its configuration, which
        // `canDelete` alone still reads as deletable. Trashing the bundle then
        // pulls the disk image out from under a guest that is running or about
        // to.
        guard instance.canDelete else { throw invalidState(instance) }
        guard !lifecycle.hasActiveOperation(for: instance.id) else {
            throw CommandError.busy(
                vm: summary(instance), operation: instance.status.displayName.lowercased())
        }
        guard confirmed else {
            throw CommandError.confirmationRequired(
                Self.deletePrompt(instance, permanently: permanently))
        }

        instance.tearDownSession()
        let toDelete =
            alsoRemoving.isEmpty
            ? []
            : externalAttachments(for: instance).filter {
                alsoRemoving.contains($0.id) && !$0.isShared
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
        cleanupSetupResumeData(for: instance, permanently: permanently)
        lifecycle.clearActiveOperation(for: instance.id)
        library.sleepPausedInstanceIDs.remove(instance.id)
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
            await deleteExternalAttachment(
                at: URL(fileURLWithPath: attachment.path),
                bookmark: bookmark(for: attachment, in: instance.configuration),
                label: attachment.label,
                vmName: vmName,
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

    /// Deletes one external attachment, to Trash or immediately depending on
    /// `permanently`.
    ///
    /// Missing files are swallowed at `.notice` (the source may have been moved or
    /// deleted out-of-band); other failures log `.warning` and surface a single
    /// error. The blocking call runs off the main actor — `trashItem` can hang for
    /// seconds on a slow or unresponsive volume.
    private func deleteExternalAttachment(
        at url: URL, bookmark: Data?, label: String, vmName: String, permanently: Bool
    ) async {
        let fileSystem = fileSystem
        let outcome = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try SecurityScopedBookmark.withResolvedURL(bookmark: bookmark, fallback: url) {
                    target in
                    if permanently {
                        try fileSystem.removeItem(at: target)
                    } else {
                        try fileSystem.trashItem(at: target)
                    }
                }
                return nil
            } catch let error as CocoaError
                where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
            {
                return ""
            } catch {
                return error.localizedDescription
            }
        }.value
        switch outcome {
        case .none:
            Self.logger.notice(
                "Deleted external attachment '\(label, privacy: .public)' for deleted VM '\(vmName, privacy: .public)'"
            )
        case .some(let message) where message.isEmpty:
            Self.logger.notice(
                "External attachment already gone for '\(label, privacy: .public)' (\(url.lastPathComponent, privacy: .public)) on deleted VM '\(vmName, privacy: .public)'; skipping delete"
            )
        case .some(let message):
            Self.logger.warning(
                "Failed to delete external attachment '\(label, privacy: .public)' (\(url.lastPathComponent, privacy: .public)) on deleted VM '\(vmName, privacy: .public)': \(message, privacy: .public)"
            )
            // No instance to name: the VM was evicted before these ran, which is
            // the whole point of doing them after the bundle.
            report(.operationFailed(verb: .delete, message: message), on: nil)
        }
    }

    // MARK: - Attachment Projections

    /// The VM's in-bundle (internal) disks, shown read-only in the delete
    /// sheet's "Removed with the VM" section.
    ///
    /// Falls back to the synthesized main disk when `storageDisks` is `nil`, so a
    /// freshly created VM still shows its `Disk.asif`.
    func bundledDisks(for instance: VMInstance) -> [StorageDisk] {
        (instance.configuration.storageDisks ?? Self.defaultStorageDisks(for: instance))
            .filter(\.isInternal)
    }

    /// The external (non-bundle) files referenced by `instance`.
    ///
    /// Each is annotated with the names of other VMs sharing the same path. The
    /// bundled Guest Agent installer DMG is excluded: its path points *inside the
    /// app bundle*, so trashing it would corrupt the app for every VM.
    ///
    /// Existence is **not** resolved — every ``ExternalAttachment/isMissing`` is
    /// `false`; use ``externalAttachmentsResolvingExistence(for:)`` when it matters.
    func externalAttachments(for instance: VMInstance) -> [ExternalAttachment] {
        let agentPath = Self.guestAgentInstallerPath
        var attachments: [ExternalAttachment] = []
        for disk in instance.configuration.storageDisks ?? [] where !disk.isInternal {
            attachments.append(
                ExternalAttachment(
                    id: disk.id,
                    kind: .storageDisk,
                    label: disk.label,
                    path: disk.path,
                    sharedWithVMNames: sharingVMNames(forPath: disk.path, excluding: instance),
                    isMissing: false
                )
            )
        }
        for item in instance.configuration.removableMedia ?? [] where item.path != agentPath {
            attachments.append(
                ExternalAttachment(
                    id: item.id,
                    kind: .removableMedia,
                    label: item.label,
                    path: item.path,
                    sharedWithVMNames: sharingVMNames(forPath: item.path, excluding: instance),
                    isMissing: false
                )
            )
        }
        return attachments
    }

    /// ``externalAttachments(for:)`` with each attachment's
    /// ``ExternalAttachment/isMissing`` resolved against the filesystem.
    ///
    /// The syscalls run detached so a stale or unreachable mount can't freeze the
    /// main actor. Probes go through each attachment's security bookmark — a raw
    /// check on an out-of-container path is sandbox-denied and would render every
    /// row as missing.
    func externalAttachmentsResolvingExistence(for instance: VMInstance) async
        -> [ExternalAttachment]
    {
        let attachments = externalAttachments(for: instance)
        guard !attachments.isEmpty else { return attachments }
        let paths = attachments.map(\.path)
        let bookmarks = externalAttachmentRefs(for: instance.configuration)
        let missingByPath = await Task.detached(priority: .userInitiated) {
            var result: [String: Bool] = [:]
            for path in paths where result[path] == nil {
                result[path] = !SecurityScopedBookmark.fileExists(
                    atPath: path, bookmark: bookmarks[path] ?? nil)
            }
            return result
        }.value
        return attachments.map { attachment in
            ExternalAttachment(
                id: attachment.id,
                kind: attachment.kind,
                label: attachment.label,
                path: attachment.path,
                sharedWithVMNames: attachment.sharedWithVMNames,
                isMissing: missingByPath[attachment.path] ?? false
            )
        }
    }

    /// The persisted security bookmark backing an external attachment
    /// (``ExternalAttachment`` itself is a bookmark-free projection).
    private func bookmark(
        for attachment: ExternalAttachment, in config: VMConfiguration
    ) -> Data? {
        switch attachment.kind {
        case .storageDisk:
            (config.storageDisks ?? []).first { $0.id == attachment.id }?.bookmark
        case .removableMedia:
            (config.removableMedia ?? []).first { $0.id == attachment.id }?.bookmark
        }
    }

    /// Names of other VMs in the library that reference `path` as an external
    /// storage disk or removable medium.
    ///
    /// Only *external* (non-bundle) storage disks count — bundle-relative paths are
    /// per-VM by construction. `instance` is excluded so the file isn't reported as
    /// shared with itself.
    func sharingVMNames(forPath path: String, excluding instance: VMInstance) -> [String] {
        library.instances.compactMap { other -> String? in
            guard other.id != instance.id else { return nil }
            let externalDiskPaths = (other.configuration.storageDisks ?? [])
                .filter { !$0.isInternal }
                .map(\.path)
            let mediaPaths = (other.configuration.removableMedia ?? []).map(\.path)
            if externalDiskPaths.contains(path) || mediaPaths.contains(path) {
                return other.name
            }
            return nil
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
