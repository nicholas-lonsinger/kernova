import Foundation
import KernovaKit
import KernovaLogging

/// A file the user picked, carrying the app-scoped bookmark minted at the pick.
///
/// The core never opens a panel, so a caller that can picks first and hands the
/// grant across as data.
struct PickedFile: Sendable, Hashable {
    let path: String
    let bookmark: Data?

    /// One open-panel URL as the core takes it — path plus the app-scoped
    /// bookmark minted from this pick's grant.
    init(picking url: URL) {
        (path, bookmark) = SecurityScopedBookmark.capture(url)
    }

    init(path: String, bookmark: Data?) {
        self.path = path
        self.bookmark = bookmark
    }
}

/// What a guest-agent disk mount found in front of the guest.
///
/// Both outcomes are a success — the distinction is what a surface logs, and
/// which of the two ways the disk got there it can state.
enum GuestAgentDiskMountOutcome: Equatable, Sendable {
    /// The installer image was just added to the VM's removable-media list.
    case attached(GuestAgentDiskDelivery)
    /// The image was already in front of the guest — mounted by an earlier
    /// call, or riding `storageDevices` for the whole session on a guest whose
    /// kernel binds no USB mass storage driver.
    case alreadyPresent(GuestAgentDiskDelivery)

    /// The bus the guest takes the image on.
    var delivery: GuestAgentDiskDelivery {
        switch self {
        case .attached(let delivery), .alreadyPresent(let delivery): delivery
        }
    }
}

/// The attachment verbs — a VM's storage disks, its hot-pluggable removable
/// media, its shared directories, and the bundled guest-agent installer disk.
///
/// Every one resolves through a ``VMSelector``. An edit refuses through
/// ``VMCommandCore/require(_:on:)`` and writes under the permit its admission
/// mints (``VMCommandCore/writeConfiguration(of:as:verb:_:)``); a verb that
/// writes or trashes a disk image runs as an operation holding the VM, and
/// writes as that operation (``VMCommandCore/writeConfiguration(in:verb:_:)``).
/// Consent is a parameter: trashing the file behind an attachment refuses
/// without it.
extension VMCommandCore {
    // MARK: - Storage Disks

    /// Appends `files` to the VM's storage-disk list, skipping paths it already
    /// carries.
    func attachStorageDisks(_ selector: VMSelector, paths files: [PickedFile]) throws {
        let instance = try resolve(selector)
        try require(.editStorageDisks, on: instance)
        guard !files.isEmpty else { return }
        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        try writeConfiguration(of: instance, as: .editStorageDisks, verb: .editStorageDisk) { config in
            var disks = config.effectiveStorageDisks(layout: layout)
            var known = Set(disks.map(\.path))
            for file in files where known.insert(file.path).inserted {
                disks.append(StorageDisk(path: file.path, bookmark: file.bookmark))
            }
            config.setStorageDisks(disks)
        }
    }

    /// Writes a new ASIF sparse image inside the VM's bundle and appends it,
    /// holding the VM from the image write through the configuration write.
    func createStorageDisk(_ selector: VMSelector, sizeInGB: Int) async throws {
        let instance = try resolve(selector)
        let diskID = UUID()
        try await perform(.creatingStorageDisk, on: instance, verb: .editStorageDisk) { context in
            let relativePath: String
            do {
                relativePath = try await context.bundle.createInternalDisk(
                    id: diskID, sizeInGB: sizeInGB, using: diskImageService)
            } catch {
                #log(
                    Self.logger, .error,
                    "Failed to create storage disk for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                throw CommandError.operationFailed(
                    verb: .editStorageDisk, message: error.localizedDescription)
            }
            let layout = VMBundleLayout(bundleURL: context.bundle.url)
            var createdLabel = "\(sizeInGB) GB Disk"
            try await writeConfiguration(in: context, verb: .editStorageDisk) { config in
                var disks = config.effectiveStorageDisks(layout: layout)
                let label = StorageDisk.uniqueLabel(
                    base: "\(sizeInGB) GB Disk", existingLabels: disks.map(\.label))
                createdLabel = label
                disks.append(
                    StorageDisk(
                        id: diskID, path: relativePath, readOnly: false, label: label,
                        isInternal: true, kind: .virtio))
                config.setStorageDisks(disks)
            }
            #log(
                Self.logger, .notice,
                "Created in-bundle storage disk '\(createdLabel, privacy: .public)' (\(sizeInGB, privacy: .public) GB) for VM '\(instance.name, privacy: .public)'"
            )
        }
    }

    /// Drops a storage disk's entry, and with `trashFile` the file behind it.
    ///
    /// A file another VM still references is never trashed, however `trashFile`
    /// is set — only the entry goes. A VM's only disk is refused outright,
    /// whichever file backs it: a VM keeps at least one storage disk, an empty
    /// list re-synthesizes `Disk.asif`, and the same exclusion already keeps it
    /// out of the start-failure removal offer. Any disk with a sibling goes,
    /// `Disk.asif` included.
    func removeStorageDisk(
        _ selector: VMSelector, disk id: UUID, trashFile: Bool, confirmed: Bool
    ) async throws {
        let instance = try resolve(selector)
        try require(trashFile ? .trashStorageDisk : .editStorageDisks, on: instance)
        let disk = try removableStorageDisk(id, on: instance)
        guard trashFile else {
            try detachStorageDisk(id, from: instance)
            return
        }
        // Only an external disk can be shared — a bundle-relative path is
        // per-VM by construction.
        var shared: [String] = []
        if !disk.isInternal {
            shared = await sharingVMNames(
                forPath: disk.path, bookmark: disk.bookmark, excluding: instance)
            #if DEBUG
            await afterSharingResolveForTesting?()
            #endif
        }
        guard confirmed else {
            throw CommandError.confirmationRequired(
                Self.attachmentDeletePrompt(
                    label: disk.label, isInternal: disk.isInternal, isGuestAgent: false,
                    sharedVMNames: shared))
        }
        // Admitted on the far side of the resolve, so a Start that landed in
        // it refuses the removal; the disk is read again under the operation,
        // since one detached, re-pointed or left the VM's last in the gap is
        // not the removal this call resolved sharing for.
        try await perform(.removingStorageDisk, on: instance, verb: .editStorageDisk) { context in
            let current = try removableStorageDisk(id, on: instance)
            guard current.path == disk.path, current.bookmark == disk.bookmark else {
                throw staleAttachment(id, on: instance, verb: .editStorageDisk)
            }
            let layout = VMBundleLayout(bundleURL: context.bundle.url)
            try await writeConfiguration(
                in: context, verb: .editStorageDisk,
                Self.dropStorageDisk(id, layout: layout))
            guard shared.isEmpty else {
                #log(
                    Self.logger, .notice,
                    "Kept shared disk '\(disk.label, privacy: .public)' — still used by another VM; removed entry only"
                )
                return
            }
            guard disk.isInternal else {
                await trashExternalFile(
                    at: URL(fileURLWithPath: disk.path), bookmark: disk.bookmark,
                    label: disk.label, vmName: instance.name, verb: .editStorageDisk)
                return
            }
            await reportFileRemoval(
                of: context.bundle.url.appendingPathComponent(disk.path), label: disk.label,
                vmName: instance.name, verb: .editStorageDisk
            ) {
                try await context.bundle.trashInternalDisk(atRelativePath: disk.path)
            }
        }
    }

    /// The storage disk `id` names, refusing when the VM no longer carries it
    /// or when it is the VM's only disk.
    private func removableStorageDisk(_ id: UUID, on instance: VMInstance) throws -> StorageDisk {
        guard let disk = storageDisk(id: id, on: instance) else {
            throw staleAttachment(id, on: instance, verb: .editStorageDisk)
        }
        try refuseSoleStorageDiskRemoval(of: disk, on: instance)
        return disk
    }

    private func refuseSoleStorageDiskRemoval(of disk: StorageDisk, on instance: VMInstance) throws {
        guard instance.isSoleStorageDisk(disk) else { return }
        #log(
            Self.logger, .debug,
            "Refusing to remove the only disk of '\(instance.name, privacy: .public)'")
        throw CommandError.operationFailed(
            verb: .editStorageDisk,
            message:
                "\u{201C}\(disk.label)\u{201D} is the only disk \u{201C}\(instance.name)\u{201D} has. A virtual machine keeps at least one storage disk."
        )
    }

    /// Replaces a storage disk's user-facing label; an empty label is ignored.
    ///
    /// The label is cosmetic — the virtio block identifier derives from the
    /// disk's UUID and the backing file keeps its UUID name — so any disk takes
    /// one, the main disk included. Duplicate labels are allowed on an explicit
    /// rename; only machine-generated defaults are uniqued.
    func renameStorageDisk(_ selector: VMSelector, disk id: UUID, to newLabel: String) throws {
        let instance = try resolve(selector)
        try require(.editStorageDisks, on: instance)
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try mutateStorageDisk(id, on: instance) { $0.label = trimmed }
    }

    /// Replaces a storage disk's note; an unchanged value is a no-op.
    ///
    /// Unlike a label, an empty note is a legitimate value — it clears the note.
    /// Leading and trailing whitespace is trimmed; interior newlines are kept.
    func setStorageDiskNotes(_ selector: VMSelector, disk id: UUID, notes: String) throws {
        let instance = try resolve(selector)
        try require(.editStorageDisks, on: instance)
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        try mutateStorageDisk(id, on: instance) { $0.notes = trimmed }
    }

    /// Marks a storage disk read-only, or writable again.
    func setStorageDiskReadOnly(_ selector: VMSelector, disk id: UUID, readOnly: Bool) throws {
        let instance = try resolve(selector)
        try require(.editStorageDisks, on: instance)
        try mutateStorageDisk(id, on: instance) { $0.readOnly = readOnly }
    }

    /// Rewrites the boot order to `order`.
    ///
    /// Disks the list does not name keep their relative order behind those it
    /// does, so a disk added while a reorder sheet was up is not dropped.
    func reorderStorageDisks(_ selector: VMSelector, order: [UUID]) throws {
        let instance = try resolve(selector)
        try require(.editStorageDisks, on: instance)
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        try writeConfiguration(of: instance, as: .editStorageDisks, verb: .editStorageDisk) { config in
            let disks = config.effectiveStorageDisks(layout: layout)
            config.setStorageDisks(
                disks.enumerated()
                    .sorted { left, right in
                        let leftRank = rank[left.element.id] ?? Int.max
                        let rightRank = rank[right.element.id] ?? Int.max
                        return leftRank == rightRank
                            ? left.offset < right.offset : leftRank < rightRank
                    }
                    .map(\.element))
        }
    }

    // MARK: - Removable Media

    /// Appends `files` to the VM's removable-media list, skipping paths it
    /// already carries.
    func attachRemovableMedia(_ selector: VMSelector, paths files: [PickedFile]) throws {
        let instance = try resolve(selector)
        try require(.editRemovableMedia, on: instance)
        guard !files.isEmpty else { return }
        try writeConfiguration(of: instance, as: .editRemovableMedia, verb: .editRemovableMedia) { config in
            var items = config.removableMedia ?? []
            var known = Set(items.map(\.path))
            for file in files where known.insert(file.path).inserted {
                items.append(
                    RemovableMediaItem(path: file.path, readOnly: true, bookmark: file.bookmark))
            }
            config.removableMedia = items.isEmpty ? nil : items
        }
    }

    /// Writes a new ASIF sparse image at `destinationURL` and attaches it as a
    /// hot-pluggable removable disk, holding the VM from the image write until
    /// a live guest has the disk attached.
    ///
    /// The file is **not** bundle-owned: removing the entry does not trash it,
    /// and cloning the VM references the same path rather than copying it.
    func createRemovableMedia(
        _ selector: VMSelector, sizeInGB: Int, destinationURL: URL
    ) async throws {
        let instance = try resolve(selector)
        try await perform(.creatingRemovableMedia, on: instance, verb: .editRemovableMedia) { context in
            let item: RemovableMediaItem
            do {
                try await diskImageService.createDiskImage(at: destinationURL, sizeInGB: sizeInGB)
                // Bookmarked after the write succeeds: the file has to exist to
                // be bookmarked, and the write rides the still-live save-panel
                // grant.
                item = RemovableMediaItem(
                    path: destinationURL.path(percentEncoded: false),
                    readOnly: false,
                    label: destinationURL.deletingPathExtension().lastPathComponent,
                    bookmark: SecurityScopedBookmark.make(for: destinationURL))
            } catch {
                // Only when the write itself failed — the earlier phases throw
                // before the destination is touched, and the path is
                // user-chosen, so trashing there could remove an unrelated
                // pre-existing file.
                if case DiskImageError.writeFailed = error {
                    cleanUpPartialDiskImage(at: destinationURL)
                }
                #log(
                    Self.logger, .error,
                    "Failed to create removable disk for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                throw CommandError.operationFailed(
                    verb: .editRemovableMedia, message: error.localizedDescription)
            }
            // The file is the user's, and stays whatever becomes of the entry.
            let created = destinationURL.path(percentEncoded: false)
            let write = await library.updateConfiguration(in: context) { config in
                config.removableMedia = (config.removableMedia ?? []) + [item]
            }
            switch write {
            case .saved:
                break
            case .refused(let refusal):
                #log(
                    Self.logger, .notice,
                    "Removable disk written at '\(destinationURL.path, privacy: .public)' but not attached to '\(instance.name, privacy: .public)': \(refusal.localizedDescription, privacy: .public)"
                )
                throw CommandError.operationFailed(
                    verb: .editRemovableMedia,
                    message:
                        "The disk image was created at \(created), but it was not attached. \(refusal.localizedDescription)"
                )
            case .notSaved:
                #log(
                    Self.logger, .notice,
                    "Removable disk written at '\(destinationURL.path, privacy: .public)' but not attached to '\(instance.name, privacy: .public)': the configuration was not saved"
                )
                throw CommandError.operationFailed(
                    verb: .editRemovableMedia,
                    message:
                        "The disk image was created at \(created), but the change to \u{201C}\(instance.name)\u{201D} was not saved, so it is not attached."
                )
            }
            #log(
                Self.logger, .notice,
                "Created removable disk '\(item.label, privacy: .public)' (\(sizeInGB, privacy: .public) GB) at '\(destinationURL.path, privacy: .public)' for VM '\(instance.name, privacy: .public)'"
            )
        }
    }

    /// Drops a removable medium's entry, and with `trashFile` the file behind
    /// it.
    ///
    /// The bundled Guest Agent installer and a file another VM still references
    /// are never trashed, however `trashFile` is set — only the entry goes.
    func removeRemovableMedia(
        _ selector: VMSelector, item id: UUID, trashFile: Bool, confirmed: Bool
    ) async throws {
        let instance = try resolve(selector)
        try require(.editRemovableMedia, on: instance)
        guard let item = removableMediaItem(id: id, on: instance) else {
            throw staleAttachment(id, on: instance, verb: .editRemovableMedia)
        }
        let isAgentInstaller = item.isBundledGuestAgentInstaller
        var shared: [String] = []
        if trashFile, !isAgentInstaller {
            shared = await sharingVMNames(
                forPath: item.path, bookmark: item.bookmark, excluding: instance)
            #if DEBUG
            await afterSharingResolveForTesting?()
            #endif
            // Same far-side gate and re-read as `removeStorageDisk`. Removable
            // media is hot-pluggable, so the gate refuses the states a live
            // session doesn't cover — a start still bringing the VM up, above
            // all.
            try require(.editRemovableMedia, on: instance)
            guard let current = removableMediaItem(id: id, on: instance),
                current.path == item.path, current.bookmark == item.bookmark
            else {
                throw staleAttachment(id, on: instance, verb: .editRemovableMedia)
            }
        }
        if trashFile, !confirmed {
            throw CommandError.confirmationRequired(
                Self.attachmentDeletePrompt(
                    label: item.label, isInternal: false,
                    isGuestAgent: isAgentInstaller, sharedVMNames: shared))
        }
        try detachRemovableMedia(id, from: instance)

        guard trashFile else { return }
        // The bundled Guest Agent installer is app-owned: removing it only
        // detaches the entry — trashing it would corrupt the app bundle for
        // every VM.
        guard !isAgentInstaller else {
            #log(
                Self.logger, .notice,
                "Kept Guest Agent installer '\(item.label, privacy: .public)' — app-owned; removed entry only"
            )
            return
        }
        guard shared.isEmpty else {
            #log(
                Self.logger, .notice,
                "Kept shared media '\(item.label, privacy: .public)' — still used by another VM; removed entry only"
            )
            return
        }
        await trashExternalFile(
            at: URL(fileURLWithPath: item.path), bookmark: item.bookmark, label: item.label,
            vmName: instance.name, verb: .editRemovableMedia)
    }

    /// Detaches a removable medium and keeps its file — what a running guest
    /// sees as an eject.
    ///
    /// No consent: nothing is destroyed, and re-attaching is one click away.
    func ejectRemovableMedia(_ selector: VMSelector, item id: UUID) throws {
        let instance = try resolve(selector)
        try require(.editRemovableMedia, on: instance)
        guard let item = removableMediaItem(id: id, on: instance) else {
            throw staleAttachment(id, on: instance, verb: .editRemovableMedia)
        }
        #log(
            Self.logger, .notice,
            "Ejecting removable media '\(item.label, privacy: .public)' from '\(instance.name, privacy: .public)'"
        )
        try detachRemovableMedia(id, from: instance)
    }

    /// Replaces a removable medium's user-facing label; an empty label is
    /// ignored.
    ///
    /// Safe while the VM runs: the live reconciliation detaches and reattaches
    /// only when `path` or `readOnly` differs, so a label-only edit leaves the
    /// medium mounted.
    func renameRemovableMedia(_ selector: VMSelector, item id: UUID, to newLabel: String) throws {
        let instance = try resolve(selector)
        try require(.editRemovableMedia, on: instance)
        let trimmed = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try mutateRemovableMedia(id, on: instance) { $0.label = trimmed }
    }

    /// Replaces a removable medium's note; an unchanged value is a no-op.
    ///
    /// Mount-safe for the reason ``renameRemovableMedia(_:item:to:)`` states.
    /// An empty note is a legitimate value — it clears the note.
    func setRemovableMediaNotes(_ selector: VMSelector, item id: UUID, notes: String) throws {
        let instance = try resolve(selector)
        try require(.editRemovableMedia, on: instance)
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        try mutateRemovableMedia(id, on: instance) { $0.notes = trimmed }
    }

    /// Marks a removable medium read-only, or writable again.
    ///
    /// Unlike a label or a note this *is* part of the mount identity, so a live
    /// guest sees the medium ejected and re-inserted.
    func setRemovableMediaReadOnly(
        _ selector: VMSelector, item id: UUID, readOnly: Bool
    ) throws {
        let instance = try resolve(selector)
        try require(.editRemovableMedia, on: instance)
        try mutateRemovableMedia(id, on: instance) { $0.readOnly = readOnly }
    }

    // MARK: - Shared Directories

    /// Appends `files` to the VM's shared-directory list, skipping paths it
    /// already carries.
    func addSharedDirectories(_ selector: VMSelector, paths files: [PickedFile]) throws {
        let instance = try resolve(selector)
        try require(.editSharedDirectories, on: instance)
        guard !files.isEmpty else { return }
        try writeConfiguration(of: instance, as: .editSharedDirectories, verb: .editSharedDirectory) { config in
            var directories = config.sharedDirectories ?? []
            // The one spelling the core compares folder paths in, so a pick of
            // `/x/` finds the `/x` this VM already shares.
            var known = Set(directories.map { Self.comparablePath($0.path) })
            for file in files where known.insert(Self.comparablePath(file.path)).inserted {
                directories.append(SharedDirectory(path: file.path, bookmark: file.bookmark))
            }
            config.sharedDirectories = directories.isEmpty ? nil : directories
        }
    }

    /// Drops a shared directory's entry, leaving the folder itself alone.
    ///
    /// No consent: nothing is destroyed, for the reason
    /// ``ejectRemovableMedia(_:item:)`` states.
    func removeSharedDirectory(_ selector: VMSelector, directory id: UUID) throws {
        let instance = try resolve(selector)
        try require(.editSharedDirectories, on: instance)
        guard sharedDirectory(id: id, on: instance) != nil else {
            throw staleAttachment(id, on: instance, verb: .editSharedDirectory)
        }
        try writeConfiguration(of: instance, as: .editSharedDirectories, verb: .editSharedDirectory) { config in
            var directories = config.sharedDirectories ?? []
            directories.removeAll { $0.id == id }
            config.sharedDirectories = directories.isEmpty ? nil : directories
        }
    }

    /// Marks a shared directory read-only, or writable again.
    func setSharedDirectoryReadOnly(
        _ selector: VMSelector, directory id: UUID, readOnly: Bool
    ) throws {
        let instance = try resolve(selector)
        try require(.editSharedDirectories, on: instance)
        guard let current = sharedDirectory(id: id, on: instance) else {
            throw staleAttachment(id, on: instance, verb: .editSharedDirectory)
        }
        guard current.readOnly != readOnly else { return }
        try writeConfiguration(of: instance, as: .editSharedDirectories, verb: .editSharedDirectory) { config in
            var directories = config.sharedDirectories ?? []
            guard let index = directories.firstIndex(where: { $0.id == id }) else { return }
            directories[index].readOnly = readOnly
            config.sharedDirectories = directories
        }
    }

    // MARK: - Guest Agent Disk

    /// Puts the bundled `KernovaMacOSAgent.dmg` in front of the guest, so the
    /// user can run `install.command` inside it.
    ///
    /// Answers how the image reached the guest: a guest whose kernel binds no
    /// USB mass storage driver already carries it on `storageDevices` for the
    /// whole session, so there the verb attaches nothing and says so.
    @discardableResult
    func mountGuestAgentDisk(_ selector: VMSelector) throws -> GuestAgentDiskMountOutcome {
        let instance = try resolve(selector)
        try require(.toggleGuestAgentDisk, on: instance)
        guard let url = KernovaMacOSAgentInfo.installerDiskImageURL else {
            #log(Self.logger, .fault, "Guest agent installer DMG missing from app bundle")
            assertionFailure(
                "KernovaMacOSAgent.dmg missing — check 'Package Guest Agent DMG' build phase outputs"
            )
            throw CommandError.operationFailed(
                verb: .guestAgentDisk,
                message: "The Guest Agent installer is missing from this copy of Kernova.")
        }
        let delivery = GuestAgentDiskDelivery.mode(for: instance.effectiveConfiguration)
        guard delivery == .usb else {
            #log(
                Self.logger, .debug,
                "Guest agent disk reaches '\(instance.name, privacy: .public)' over virtio; nothing to attach"
            )
            return .alreadyPresent(delivery)
        }
        guard !instance.hasGuestAgentInstallerMounted else {
            #log(
                Self.logger, .debug,
                "Guest agent installer already mounted on '\(instance.name, privacy: .public)'")
            return .alreadyPresent(delivery)
        }
        #log(
            Self.logger, .notice,
            "Mounting guest agent installer on '\(instance.name, privacy: .public)'")
        try writeConfiguration(of: instance, as: .toggleGuestAgentDisk, verb: .guestAgentDisk) { config in
            config.removableMedia =
                (config.removableMedia ?? [])
                + [
                    RemovableMediaItem(
                        path: url.path(percentEncoded: false), readOnly: true,
                        label: KernovaMacOSAgentInfo.diskLabel)
                ]
        }
        return .attached(delivery)
    }

    /// Takes the bundled installer image away again.
    func unmountGuestAgentDisk(_ selector: VMSelector) throws {
        let instance = try resolve(selector)
        try require(.toggleGuestAgentDisk, on: instance)
        detachGuestAgentDisk(from: instance)
    }

    /// Drops the bundled installer's `removableMedia` entry when it is there;
    /// the reconcile pass performs the runtime detach.
    ///
    /// The auto-eject an agent handshake triggers calls this rather than
    /// ``unmountGuestAgentDisk(_:)``: the Hello proves a live session, and the
    /// eject finishes an install the user already asked for, so a state gate
    /// between the two could only strand the disk.
    func detachGuestAgentDisk(from instance: VMInstance) {
        guard let url = KernovaMacOSAgentInfo.installerDiskImageURL,
            instance.hasGuestAgentInstallerMounted
        else { return }
        let path = url.path(percentEncoded: false)
        #log(
            Self.logger, .notice,
            "Unmounting guest agent installer from '\(instance.name, privacy: .public)'")
        let write: VMLibrary.SettingsWrite
        do {
            write = try instance.activity.edit(.hotPlugMedia) { permit in
                library.updateConfiguration(permit) { config in
                    let pruned = (config.removableMedia ?? []).filter { $0.path != path }
                    config.removableMedia = pruned.isEmpty ? nil : pruned
                }
            }
        } catch {
            #log(
                Self.logger, .notice,
                "Guest agent installer stays mounted on '\(instance.name, privacy: .public)' (\(instance.status.rawValue, privacy: .public)): \(String(describing: error), privacy: .public)"
            )
            return
        }
        switch write {
        case .saved:
            break
        case .refused(let refusal):
            #log(
                Self.logger, .notice,
                "Guest agent installer stays mounted on '\(instance.name, privacy: .public)': \(refusal.localizedDescription, privacy: .public)"
            )
        case .notSaved:
            #log(
                Self.logger, .notice,
                "Guest agent installer stays mounted on '\(instance.name, privacy: .public)': the configuration was not saved"
            )
        }
    }

    // MARK: - Start-Failure Recovery

    /// The removal half of the ``CommandRecovery/removeStartFailedAttachment(_:)``
    /// a failed bring-up offered: the attachment goes, then the VM's saved
    /// state, leaving a VM the caller's own Start can boot.
    ///
    /// The entry is checked before anything else, so an entry somebody removed
    /// meanwhile answers as the no-op
    /// ``VMCommanding/removeStartFailedAttachment(_:attachment:)`` promises
    /// rather than as that verb's stale-attachment refusal — and keeps its
    /// saved state, which a confirmation landing late must not destroy.
    ///
    /// On a VM resting on its saved state the removal is a write of the discard
    /// operation itself, committed *before* the saved state goes — the step
    /// nothing can undo: the alert is window-modal and every other door stays
    /// live behind it, so a bring-up or a copy can take the VM between the
    /// offer and the click — and the configuration write can refuse or fail
    /// to reach disk. Every one of those leaves the VM with both its session
    /// and its attachment, and tells the caller why. A VM holding no saved
    /// state — a bring-up consumed it while the alert was up, or a live session
    /// takes the change as a hot-plug — gets the plain edit.
    ///
    /// The edit's gate refuses while a saved state is on disk, so it is asked
    /// of the VM as it will stand once the discard lands; the removal is the
    /// same change the public verb makes — on these arguments (`trashFile:
    /// false`, already-confirmed, entry re-checked above) that verb adds
    /// nothing else.
    func removeStartFailedAttachment(
        _ selector: VMSelector, attachment failure: StartFailedAttachment
    ) async throws {
        guard let instance = try? resolve(selector) else {
            #log(
                Self.logger, .debug,
                "Ignoring start-failed removal for already-removed VM '\(selector.displayText, privacy: .public)'"
            )
            return
        }
        guard carriesStartFailedAttachment(failure, on: instance) else {
            #log(
                Self.logger, .debug,
                "Start-failed attachment '\(failure.label, privacy: .public)' is already off '\(instance.name, privacy: .public)'"
            )
            return
        }
        let capability: VMCapability =
            switch failure.kind {
            case .storageDisk: .editStorageDisks
            case .removableMedia: .editRemovableMedia
            }
        // Decided as the VM will stand once the discard lands, so only the term
        // that discard clears is lifted and every other blocker — a bring-up in
        // flight, a copy still writing it — answers exactly as it will answer
        // the verb.
        // The refusal names what this VM really accepts rather than what it
        // would accept after a discard that is not going to happen.
        guard capabilities.acceptsAsIfSavedStateDiscarded(capability, on: instance) else {
            throw refusal(for: [capability], on: instance)
        }
        if case .storageDisk = failure.kind, let disk = storageDisk(id: failure.id, on: instance) {
            try refuseSoleStorageDiskRemoval(of: disk, on: instance)
        }
        let removal: (inout VMConfiguration) -> Void =
            switch failure.kind {
            case .storageDisk:
                Self.dropStorageDisk(
                    failure.id, layout: VMBundleLayout(bundleURL: instance.bundleURL))
            case .removableMedia: Self.dropRemovableMedia(failure.id)
            }
        guard instance.holdsSuspendedSession else {
            try writeConfiguration(of: instance, as: capability, verb: failure.verb, removal)
            logStartFailedRemoval(failure, from: instance)
            return
        }
        var removed = false
        do {
            try lifecycle.discardSavedState(instance) { permit in
                try requireSaved(
                    library.updateConfiguration(permit, mutate: removal), of: instance,
                    verb: failure.verb)
                removed = true
            }
        } catch {
            guard removed else { throw self.failure(error, verb: failure.verb, on: instance) }
            // The device set no longer matches the one the state was written
            // under, so that state cannot be restored — and the discard that
            // would have cleared it is what just failed. Both facts are known,
            // so both are stated, and the discard the VM still offers is the
            // way out.
            throw CommandError.operationFailed(
                verb: failure.verb,
                message:
                    "\u{201C}\(failure.label)\u{201D} was removed from \u{201C}\(instance.name)\u{201D}, but its saved state could not be deleted. That state can no longer be restored — discard it to start the virtual machine."
            )
        }
        logStartFailedRemoval(failure, from: instance)
        #log(
            Self.logger, .notice,
            "Discarded saved state for '\(instance.name, privacy: .public)' along with the attachment its bring-up failed on"
        )
    }

    private func logStartFailedRemoval(_ failure: StartFailedAttachment, from instance: VMInstance) {
        #log(
            Self.logger, .notice,
            "Removed failed attachment '\(failure.label, privacy: .public)' from '\(instance.name, privacy: .public)'"
        )
    }

    /// Whether `failure`'s entry is still in the list the removal would edit.
    private func carriesStartFailedAttachment(
        _ failure: StartFailedAttachment, on instance: VMInstance
    ) -> Bool {
        switch failure.kind {
        case .storageDisk:
            storageDisk(id: failure.id, on: instance) != nil
        case .removableMedia:
            removableMediaItem(id: failure.id, on: instance) != nil
        }
    }

    // MARK: - Consent

    /// The confirmation a removal raises, decided purely from the attachment's
    /// nature — the settings pane draws it, and a wire client receives it.
    ///
    /// The Guest Agent installer and files shared with another VM can only be
    /// detached, never trashed, so their confirm keeps the file and destroys
    /// nothing.
    static func attachmentDeletePrompt(
        label: String,
        isInternal: Bool,
        isGuestAgent: Bool,
        sharedVMNames: [String]
    ) -> ConfirmationPrompt {
        let title = "Remove \u{201C}\(label)\u{201D}?"

        if isGuestAgent {
            return ConfirmationPrompt(
                kind: .removeAttachment,
                title: title,
                message:
                    "Detaches the Guest Agent installer from this VM. It's part of Kernova, so the file isn't deleted.",
                confirmTitle: "Remove from VM",
                confirmIsDestructive: false,
                dismissTitle: "Cancel")
        }

        if !sharedVMNames.isEmpty {
            return ConfirmationPrompt(
                kind: .removeAttachment,
                title: title,
                message:
                    "Detaches it from this VM. Its file is kept — still used by \(DataFormatters.quotedList(sharedVMNames)).",
                confirmTitle: "Remove from VM",
                confirmIsDestructive: false,
                dismissTitle: "Cancel")
        }

        if isInternal {
            return ConfirmationPrompt(
                kind: .removeAttachment,
                title: title,
                message:
                    "Moves the disk image to the Trash and removes the disk from this VM.",
                confirmTitle: "Move to Trash",
                dismissTitle: "Cancel")
        }

        return ConfirmationPrompt(
            kind: .removeAttachment,
            title: title,
            message:
                "Move to Trash sends the file to the Trash. Remove from VM detaches it but keeps the file.",
            confirmTitle: "Move to Trash",
            dismissTitle: "Cancel",
            alternatives: [ConfirmationAlternative(title: "Remove from VM", keepsFile: true)])
    }

    // MARK: - Trashing

    /// Trashes one file an attachment or a deleted VM referenced outside any
    /// bundle, to the Trash or immediately depending on `permanently`.
    ///
    /// The blocking call runs off the main actor: `trashItem` can hang for
    /// seconds on a slow or unresponsive volume.
    func trashExternalFile(
        at url: URL, bookmark: Data?, label: String, vmName: String, verb: VMVerb,
        permanently: Bool = false
    ) async {
        let fileSystem = fileSystem
        await reportFileRemoval(of: url, label: label, vmName: vmName, verb: verb) {
            try await Task.detached(priority: .userInitiated) {
                try SecurityScopedBookmark.withResolvedURL(bookmark: bookmark, fallback: url) {
                    target in
                    if permanently {
                        try fileSystem.removeItem(at: target)
                    } else {
                        try fileSystem.trashItem(at: target)
                    }
                }
            }.value
        }
    }

    /// Runs `remove` for the file at `url` an attachment or a deleted VM
    /// referenced, and says how it went.
    ///
    /// Missing files are swallowed at `.notice` — the source may have been
    /// moved or deleted out of band, and there is nothing for the user to act
    /// on; every other failure logs `.warning` and surfaces one error.
    private func reportFileRemoval(
        of url: URL, label: String, vmName: String, verb: VMVerb,
        _ remove: () async throws -> Void
    ) async {
        do {
            try await remove()
            #log(
                Self.logger, .notice,
                "Removed the file behind '\(label, privacy: .public)' for VM '\(vmName, privacy: .public)'"
            )
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
        {
            #log(
                Self.logger, .notice,
                "File already gone for '\(label, privacy: .public)' (\(url.lastPathComponent, privacy: .public)) on VM '\(vmName, privacy: .public)'; skipping"
            )
        } catch {
            let message = error.localizedDescription
            #log(
                Self.logger, .warning,
                "Failed to remove the file behind '\(label, privacy: .public)' (\(url.lastPathComponent, privacy: .public)) on VM '\(vmName, privacy: .public)': \(message, privacy: .public)"
            )
            // Instance-less: the VM delete that shares this helper has evicted
            // its instance by the time the externals run.
            report(.operationFailed(verb: verb, message: message), on: nil)
        }
    }

    /// Trashes what a failed disk-image write may have left behind.
    private func cleanUpPartialDiskImage(at url: URL) {
        do {
            try fileSystem.trashItem(at: url)
        } catch {
            #log(
                Self.logger, .warning,
                "Failed to clean up partial disk image at '\(url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Lookups and writes

    /// The removable medium `id` names, or `nil` when the VM no longer carries
    /// it.
    func removableMediaItem(id: UUID, on instance: VMInstance) -> RemovableMediaItem? {
        (instance.configuration.removableMedia ?? []).first { $0.id == id }
    }

    /// The shared directory `id` names, or `nil` when the VM no longer carries
    /// it.
    private func sharedDirectory(id: UUID, on instance: VMInstance) -> SharedDirectory? {
        (instance.configuration.sharedDirectories ?? []).first { $0.id == id }
    }

    /// The refusal an edit naming an attachment that is no longer attached
    /// raises.
    ///
    /// A rename field committing after the row went, or a second alert for a
    /// disk the first already removed: silent on the surface that raced itself,
    /// and answered on the wire.
    private func staleAttachment(_ id: UUID, on instance: VMInstance, verb: VMVerb) -> CommandError {
        #log(
            Self.logger, .debug,
            "\(verb.displayName, privacy: .public) named \(id.uuidString, privacy: .public), which is no longer attached to '\(instance.name, privacy: .public)'"
        )
        return .operationFailed(
            verb: verb,
            message:
                "That attachment is no longer attached to \u{201C}\(instance.name)\u{201D}.")
    }

    /// Applies `edit` to one storage disk, refusing when the VM no longer
    /// carries it and returning without a write when it changes nothing.
    ///
    /// The early-out is what keeps an unchanged edit a no-op: materializing the
    /// synthesized main disk into `storageDisks` is itself a configuration
    /// change, so the write funnel's own diff cannot catch this one.
    private func mutateStorageDisk(
        _ id: UUID, on instance: VMInstance, _ edit: (inout StorageDisk) -> Void
    ) throws {
        guard let current = storageDisk(id: id, on: instance) else {
            throw staleAttachment(id, on: instance, verb: .editStorageDisk)
        }
        var edited = current
        edit(&edited)
        guard edited != current else { return }
        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        try writeConfiguration(of: instance, as: .editStorageDisks, verb: .editStorageDisk) { config in
            var disks = config.effectiveStorageDisks(layout: layout)
            guard let index = disks.firstIndex(where: { $0.id == id }) else { return }
            disks[index] = edited
            config.setStorageDisks(disks)
        }
    }

    /// Applies `edit` to one removable medium, refusing when the VM no longer
    /// carries it and returning without a write when it changes nothing.
    private func mutateRemovableMedia(
        _ id: UUID, on instance: VMInstance, _ edit: (inout RemovableMediaItem) -> Void
    ) throws {
        guard let current = removableMediaItem(id: id, on: instance) else {
            throw staleAttachment(id, on: instance, verb: .editRemovableMedia)
        }
        var edited = current
        edit(&edited)
        guard edited != current else { return }
        try writeConfiguration(of: instance, as: .editRemovableMedia, verb: .editRemovableMedia) { config in
            var items = config.removableMedia ?? []
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index] = edited
            config.removableMedia = items.isEmpty ? nil : items
        }
    }

    /// Drops one storage disk's entry, leaving its file alone.
    private func detachStorageDisk(_ id: UUID, from instance: VMInstance) throws {
        try writeConfiguration(
            of: instance, as: .editStorageDisks, verb: .editStorageDisk,
            Self.dropStorageDisk(id, layout: VMBundleLayout(bundleURL: instance.bundleURL)))
    }

    /// The configuration change that drops storage disk `id`'s entry.
    private static func dropStorageDisk(
        _ id: UUID, layout: VMBundleLayout
    ) -> (inout VMConfiguration) -> Void {
        { config in
            var disks = config.effectiveStorageDisks(layout: layout)
            disks.removeAll { $0.id == id }
            config.setStorageDisks(disks)
        }
    }

    /// Drops one removable medium's entry, leaving its file alone.
    private func detachRemovableMedia(_ id: UUID, from instance: VMInstance) throws {
        try writeConfiguration(
            of: instance, as: .editRemovableMedia, verb: .editRemovableMedia,
            Self.dropRemovableMedia(id))
    }

    /// The configuration change that drops removable medium `id`'s entry.
    private static func dropRemovableMedia(_ id: UUID) -> (inout VMConfiguration) -> Void {
        { config in
            var items = config.removableMedia ?? []
            items.removeAll { $0.id == id }
            config.removableMedia = items.isEmpty ? nil : items
        }
    }
}
