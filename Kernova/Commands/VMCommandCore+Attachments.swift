import Foundation
import KernovaKit

/// A file the user picked, carrying the app-scoped bookmark minted at the pick.
///
/// The core never opens a panel, so a caller that can picks first and hands the
/// grant across as data.
struct PickedFile: Sendable, Hashable {
    let path: String
    let bookmark: Data?
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
/// media, and the bundled guest-agent installer disk.
///
/// Every one resolves through a ``VMSelector``, refuses through
/// ``VMCommandCore/require(_:on:)``, and writes through
/// ``VMLibrary/updateConfiguration(of:mutate:)``. Consent is a parameter:
/// trashing the file behind an attachment refuses without it.
extension VMCommandCore {
    // MARK: - Storage Disks

    /// Appends `files` to the VM's storage-disk list, skipping paths it already
    /// carries.
    func attachStorageDisks(_ selector: VMSelector, paths files: [PickedFile]) throws {
        let instance = try resolve(selector)
        try require(.editStorageDisks, on: instance)
        guard !files.isEmpty else { return }
        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        library.updateConfiguration(of: instance) { config in
            var disks = config.effectiveStorageDisks(layout: layout)
            var known = Set(disks.map(\.path))
            for file in files where known.insert(file.path).inserted {
                disks.append(StorageDisk(path: file.path, bookmark: file.bookmark))
            }
            config.setStorageDisks(disks)
        }
    }

    /// Writes a new ASIF sparse image inside the VM's bundle and appends it.
    func createStorageDisk(_ selector: VMSelector, sizeInGB: Int) async throws {
        let instance = try resolve(selector)
        try require(.editStorageDisks, on: instance)
        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        let diskID = UUID()
        let diskURL = layout.additionalDiskURL(id: diskID)
        do {
            try FileManager.default.createDirectory(
                at: layout.additionalDisksDirectoryURL, withIntermediateDirectories: true)
            try await diskImageService.createDiskImage(at: diskURL, sizeInGB: sizeInGB)
        } catch {
            // Only when the write itself failed — the earlier phases throw
            // before the destination file is touched.
            if case DiskImageError.writeFailed = error {
                cleanUpPartialDiskImage(at: diskURL)
            }
            Self.logger.error(
                "Failed to create storage disk for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw CommandError.operationFailed(
                verb: .editStorageDisk, message: error.localizedDescription)
        }

        // Bundle-relative so the entry travels with the bundle on clone / move.
        let relativePath = "AdditionalDisks/\(diskID.uuidString).asif"
        // The unique default label is picked *inside* the mutate closure against
        // the live config, so two rapid creates can't read the same snapshot and
        // land on the same "… 2" suffix.
        var createdLabel = "\(sizeInGB) GB Disk"
        library.updateConfiguration(of: instance) { config in
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
        Self.logger.notice(
            "Created in-bundle storage disk '\(createdLabel, privacy: .public)' (\(sizeInGB, privacy: .public) GB) for VM '\(instance.name, privacy: .public)'"
        )
    }

    /// Drops a storage disk's entry, and with `trashFile` the file behind it.
    ///
    /// A file another VM still references is never trashed, however `trashFile`
    /// is set — only the entry goes.
    func removeStorageDisk(
        _ selector: VMSelector, disk id: UUID, trashFile: Bool, confirmed: Bool
    ) async throws {
        let instance = try resolve(selector)
        try require(.editStorageDisks, on: instance)
        guard let disk = storageDisk(id: id, on: instance) else {
            throw staleAttachment(id, on: instance, verb: .editStorageDisk)
        }
        // Only external disks can be shared: a bundle-relative path is per-VM
        // by construction.
        var shared: [String] = []
        if !disk.isInternal {
            shared = await sharingVMNames(
                forPath: disk.path, bookmark: disk.bookmark, excluding: instance)
        }
        if trashFile, !confirmed {
            throw CommandError.confirmationRequired(
                Self.removalConsent(
                    Self.attachmentDeletePrompt(
                        label: disk.label, isInternal: disk.isInternal,
                        isMainDisk: isMainDisk(disk, of: instance), isGuestAgent: false,
                        sharedVMNames: shared)))
        }
        detachStorageDisk(id, from: instance)

        guard trashFile else { return }
        guard shared.isEmpty else {
            Self.logger.notice(
                "Kept shared disk '\(disk.label, privacy: .public)' — still used by another VM; removed entry only"
            )
            return
        }
        await trashExternalFile(
            at: disk.isInternal
                ? instance.bundleURL.appendingPathComponent(disk.path)
                : URL(fileURLWithPath: disk.path),
            bookmark: disk.isInternal ? nil : disk.bookmark,
            label: disk.label, vmName: instance.name, verb: .editStorageDisk)
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
        library.updateConfiguration(of: instance) { config in
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
        library.updateConfiguration(of: instance) { config in
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
    /// hot-pluggable removable disk.
    ///
    /// The file is **not** bundle-owned: removing the entry does not trash it,
    /// and cloning the VM references the same path rather than copying it.
    func createRemovableMedia(
        _ selector: VMSelector, sizeInGB: Int, destinationURL: URL
    ) async throws {
        let instance = try resolve(selector)
        try require(.editRemovableMedia, on: instance)
        let item: RemovableMediaItem
        do {
            try await diskImageService.createDiskImage(at: destinationURL, sizeInGB: sizeInGB)
            // Bookmarked after the write succeeds: the file has to exist to be
            // bookmarked, and the write rides the still-live save-panel grant.
            item = RemovableMediaItem(
                path: destinationURL.path(percentEncoded: false),
                readOnly: false,
                label: destinationURL.deletingPathExtension().lastPathComponent,
                bookmark: SecurityScopedBookmark.make(for: destinationURL))
        } catch {
            // Only when the write itself failed — the earlier phases throw
            // before the destination is touched, and the path is user-chosen,
            // so trashing there could remove an unrelated pre-existing file.
            if case DiskImageError.writeFailed = error {
                cleanUpPartialDiskImage(at: destinationURL)
            }
            Self.logger.error(
                "Failed to create removable disk for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw CommandError.operationFailed(
                verb: .editRemovableMedia, message: error.localizedDescription)
        }
        library.updateConfiguration(of: instance) { config in
            config.removableMedia = (config.removableMedia ?? []) + [item]
        }
        Self.logger.notice(
            "Created removable disk '\(item.label, privacy: .public)' (\(sizeInGB, privacy: .public) GB) at '\(destinationURL.path, privacy: .public)' for VM '\(instance.name, privacy: .public)'"
        )
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
        let isAgentInstaller = isGuestAgentInstaller(item)
        var shared: [String] = []
        if !isAgentInstaller {
            shared = await sharingVMNames(
                forPath: item.path, bookmark: item.bookmark, excluding: instance)
        }
        if trashFile, !confirmed {
            throw CommandError.confirmationRequired(
                Self.removalConsent(
                    Self.attachmentDeletePrompt(
                        label: item.label, isInternal: false, isMainDisk: false,
                        isGuestAgent: isAgentInstaller, sharedVMNames: shared)))
        }
        detachRemovableMedia(id, from: instance)

        guard trashFile else { return }
        // The bundled Guest Agent installer is app-owned: removing it only
        // detaches the entry — trashing it would corrupt the app bundle for
        // every VM.
        guard !isAgentInstaller else {
            Self.logger.notice(
                "Kept Guest Agent installer '\(item.label, privacy: .public)' — app-owned; removed entry only"
            )
            return
        }
        guard shared.isEmpty else {
            Self.logger.notice(
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
        Self.logger.notice(
            "Ejecting removable media '\(item.label, privacy: .public)' from '\(instance.name, privacy: .public)'"
        )
        detachRemovableMedia(id, from: instance)
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
            Self.logger.fault("Guest agent installer DMG missing from app bundle")
            assertionFailure(
                "KernovaMacOSAgent.dmg missing — check 'Package Guest Agent DMG' build phase outputs"
            )
            throw CommandError.operationFailed(
                verb: .guestAgentDisk,
                message: "The Guest Agent installer is missing from this copy of Kernova.")
        }
        let delivery = GuestAgentDiskDelivery.mode(for: instance.configuration)
        guard delivery == .usb else {
            Self.logger.debug(
                "Guest agent disk reaches '\(instance.name, privacy: .public)' over virtio; nothing to attach"
            )
            return .alreadyPresent(delivery)
        }
        guard !isGuestAgentInstallerMounted(on: instance) else {
            Self.logger.debug(
                "Guest agent installer already mounted on '\(instance.name, privacy: .public)'")
            return .alreadyPresent(delivery)
        }
        Self.logger.notice(
            "Mounting guest agent installer on '\(instance.name, privacy: .public)'")
        library.updateConfiguration(of: instance) { config in
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
            isGuestAgentInstallerMounted(on: instance)
        else { return }
        let path = url.path(percentEncoded: false)
        Self.logger.notice(
            "Unmounting guest agent installer from '\(instance.name, privacy: .public)'")
        library.updateConfiguration(of: instance) { config in
            let pruned = (config.removableMedia ?? []).filter { $0.path != path }
            config.removableMedia = pruned.isEmpty ? nil : pruned
        }
    }

    // MARK: - Start-Failure Recovery

    /// Confirmed action of the start-failed alert: detach the failing
    /// attachment (the file is untouched) and start again.
    ///
    /// Not a verb — it is the ``CommandRecovery/removeStartFailedAttachment(_:)``
    /// a failed start offered, performed. No-ops when the VM is gone or the
    /// entry has already been removed: alerts are serialized, so this
    /// confirmation can arrive long after the failed start, and retrying after
    /// a removal that found nothing would re-raise the same failure.
    func removeStartFailedAttachmentAndStart(
        _ failure: StartFailedAttachment, on instance: VMInstance
    ) async {
        guard library.instances.contains(where: { $0.id == instance.id }) else {
            Self.logger.debug(
                "Ignoring start-failed removal for already-removed VM '\(instance.name, privacy: .public)'"
            )
            return
        }
        do {
            switch failure.kind {
            case .storageDisk:
                try await removeStorageDisk(
                    .id(instance.id), disk: failure.id, trashFile: false, confirmed: true)
            case .removableMedia:
                try await removeRemovableMedia(
                    .id(instance.id), item: failure.id, trashFile: false, confirmed: true)
            }
        } catch {
            Self.logger.notice(
                "Failed attachment '\(failure.label, privacy: .public)' was not removed from '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public); not retrying start"
            )
            return
        }
        Self.logger.notice(
            "Removed failed attachment '\(failure.label, privacy: .public)' from '\(instance.name, privacy: .public)'; retrying start"
        )
        // A save file restores only into the exact device set it was saved
        // with, so it cannot outlive the removal — the alert disclosed the
        // discard before the user confirmed.
        if instance.hasSaveFile {
            instance.removeSaveFile()
            Self.logger.notice(
                "Discarded saved state for '\(instance.name, privacy: .public)' along with the removed attachment"
            )
            if instance.isColdPaused { instance.enter(.stopped) }
        }
        do {
            try await start(instance)
        } catch let refusal as CommandError {
            report(refusal, on: instance)
        } catch {
            report(.operationFailed(verb: .start, message: error.localizedDescription), on: instance)
        }
    }

    // MARK: - Consent

    /// Decides the per-row removal confirmation (title, message, offered
    /// actions) purely from the attachment's nature.
    ///
    /// The Guest Agent installer and files shared with another VM can only be
    /// detached, never trashed.
    static func attachmentDeletePrompt(
        label: String,
        isInternal: Bool,
        isMainDisk: Bool,
        isGuestAgent: Bool,
        sharedVMNames: [String]
    ) -> AttachmentDeletePrompt {
        let title = "Remove \u{201C}\(label)\u{201D}?"

        if isGuestAgent {
            return AttachmentDeletePrompt(
                title: title,
                message:
                    "Detaches the Guest Agent installer from this VM. It's part of Kernova, so the file isn't deleted.",
                actions: [.removeFromVM])
        }

        if !sharedVMNames.isEmpty {
            return AttachmentDeletePrompt(
                title: title,
                message:
                    "Detaches it from this VM. Its file is kept — still used by \(DataFormatters.quotedList(sharedVMNames)).",
                actions: [.removeFromVM])
        }

        if isInternal {
            let base = "Moves the disk image to the Trash. You can restore it with Finder's Put Back."
            return AttachmentDeletePrompt(
                title: title,
                message: isMainDisk
                    ? "\(base) This is the VM's startup disk — it won't boot without it."
                    : base,
                actions: [.moveToTrash])
        }

        return AttachmentDeletePrompt(
            title: title,
            message:
                "Move to Trash sends the file to the Trash. Remove from VM detaches it but keeps the file.",
            actions: [.moveToTrash, .removeFromVM])
    }

    /// The consent refusal a trashing removal raises, worded from the same
    /// decision the settings pane renders its alert from.
    static func removalConsent(_ prompt: AttachmentDeletePrompt) -> ConfirmationPrompt {
        ConfirmationPrompt(
            kind: .removeAttachment,
            title: prompt.title,
            message: prompt.message,
            confirmTitle: prompt.actions.first == .moveToTrash
                ? "Move to Trash" : "Remove from VM",
            dismissTitle: "Cancel")
    }

    // MARK: - Trashing

    /// Trashes one file an attachment or a deleted VM referenced, to the Trash
    /// or immediately depending on `permanently`.
    ///
    /// Missing files are swallowed at `.notice` — the source may have been
    /// moved or deleted out of band, and there is nothing for the user to act
    /// on; every other failure logs `.warning` and surfaces one error. The
    /// blocking call runs off the main actor: `trashItem` can hang for seconds
    /// on a slow or unresponsive volume.
    func trashExternalFile(
        at url: URL, bookmark: Data?, label: String, vmName: String, verb: VMVerb,
        permanently: Bool = false
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
                "Removed the file behind '\(label, privacy: .public)' for VM '\(vmName, privacy: .public)'"
            )
        case .some(let message) where message.isEmpty:
            Self.logger.notice(
                "File already gone for '\(label, privacy: .public)' (\(url.lastPathComponent, privacy: .public)) on VM '\(vmName, privacy: .public)'; skipping"
            )
        case .some(let message):
            Self.logger.warning(
                "Failed to remove the file behind '\(label, privacy: .public)' (\(url.lastPathComponent, privacy: .public)) on VM '\(vmName, privacy: .public)': \(message, privacy: .public)"
            )
            // Deliberately instance-less: the VM delete that shares this helper
            // evicts its instance before the externals run, which is the whole
            // point of doing them after the bundle.
            report(.operationFailed(verb: verb, message: message), on: nil)
        }
    }

    /// Trashes what a failed disk-image write may have left behind.
    private func cleanUpPartialDiskImage(at url: URL) {
        do {
            try fileSystem.trashItem(at: url)
        } catch {
            Self.logger.warning(
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

    /// The refusal an edit naming an attachment that is no longer attached
    /// raises.
    ///
    /// A rename field committing after the row went, or a second alert for a
    /// disk the first already removed: silent on the surface that raced itself,
    /// and answered on the wire.
    private func staleAttachment(_ id: UUID, on instance: VMInstance, verb: VMVerb) -> CommandError {
        Self.logger.debug(
            "\(verb.displayName, privacy: .public) named \(id.uuidString, privacy: .public), which is no longer attached to '\(instance.name, privacy: .public)'"
        )
        return .operationFailed(
            verb: verb,
            message:
                "That attachment is no longer attached to \u{201C}\(instance.name)\u{201D}.")
    }

    /// Applies `edit` to one storage disk, refusing when the VM no longer
    /// carries it.
    private func mutateStorageDisk(
        _ id: UUID, on instance: VMInstance, _ edit: (inout StorageDisk) -> Void
    ) throws {
        guard storageDisk(id: id, on: instance) != nil else {
            throw staleAttachment(id, on: instance, verb: .editStorageDisk)
        }
        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        library.updateConfiguration(of: instance) { config in
            var disks = config.effectiveStorageDisks(layout: layout)
            guard let index = disks.firstIndex(where: { $0.id == id }) else { return }
            edit(&disks[index])
            config.setStorageDisks(disks)
        }
    }

    /// Applies `edit` to one removable medium, refusing when the VM no longer
    /// carries it.
    private func mutateRemovableMedia(
        _ id: UUID, on instance: VMInstance, _ edit: (inout RemovableMediaItem) -> Void
    ) throws {
        guard removableMediaItem(id: id, on: instance) != nil else {
            throw staleAttachment(id, on: instance, verb: .editRemovableMedia)
        }
        library.updateConfiguration(of: instance) { config in
            var items = config.removableMedia ?? []
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            edit(&items[index])
            config.removableMedia = items.isEmpty ? nil : items
        }
    }

    /// Drops one storage disk's entry, leaving its file alone.
    private func detachStorageDisk(_ id: UUID, from instance: VMInstance) {
        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        library.updateConfiguration(of: instance) { config in
            var disks = config.effectiveStorageDisks(layout: layout)
            disks.removeAll { $0.id == id }
            config.setStorageDisks(disks)
        }
    }

    /// Drops one removable medium's entry, leaving its file alone.
    private func detachRemovableMedia(_ id: UUID, from instance: VMInstance) {
        library.updateConfiguration(of: instance) { config in
            var items = config.removableMedia ?? []
            items.removeAll { $0.id == id }
            config.removableMedia = items.isEmpty ? nil : items
        }
    }
}
