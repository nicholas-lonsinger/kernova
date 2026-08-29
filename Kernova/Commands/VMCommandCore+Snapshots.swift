import Foundation
import KernovaKit

/// The snapshot verbs, and the Ephemeral Mode revert that rides the same path.
extension VMCommandCore {
    // MARK: - Gates

    /// Whether Take Snapshot is offered right now — the single gate every
    /// surface enables its command from.
    ///
    /// ``VMInstance/canTakeSnapshot`` alone answers the VM's state; an
    /// operation still settling would reject the capture, so it has to be part
    /// of the same read or the command reads as available and errors instead.
    func canTakeSnapshot(_ instance: VMInstance) -> Bool {
        instance.canTakeSnapshot && !library.isBusy(instance)
    }

    /// Whether a revert is offered right now — the counterpart gate to
    /// ``canTakeSnapshot(_:)``.
    func canRevertToSnapshot(_ instance: VMInstance) -> Bool {
        instance.canRevertToSnapshot && !library.isBusy(instance)
    }

    /// Whether a snapshot may be deleted — the one snapshot-list edit that
    /// goes through the same per-VM serialization a revert holds.
    func canDeleteSnapshots(_ instance: VMInstance) -> Bool {
        !library.isBusy(instance)
    }

    /// Whether `snapshot` may be deleted: the manifest has to be editable, and
    /// a VM's Ephemeral baseline is the restore point its every power-off needs.
    func canDeleteSnapshot(_ instance: VMInstance, snapshot: VMSnapshot) -> Bool {
        canDeleteSnapshots(instance) && !instance.isEphemeralBaseline(snapshot)
    }

    /// Re-reads a bundle's snapshot manifest into its instance.
    ///
    /// Every instance is seeded at construction; this is for the paths that put
    /// files in the bundle afterwards (an import copying a bundle that already
    /// carries snapshots).
    func reloadSnapshots(for instance: VMInstance) {
        instance.snapshotManifest = snapshotStore.loadManifest(bundleURL: instance.bundleURL)
    }

    /// Bytes each of this VM's snapshots occupies on disk, read off the main
    /// actor — the copies live on the same volume and can be many gigabytes.
    func snapshotOnDiskBytes(for instance: VMInstance) async -> [UUID: UInt64] {
        let store = snapshotStore
        let bundleURL = instance.bundleURL
        let ids = instance.snapshotManifest.snapshots.map(\.id)
        guard !ids.isEmpty else { return [:] }
        return await Task.detached {
            store.onDiskBytes(bundleURL: bundleURL, snapshotIDs: ids)
        }.value
    }

    // MARK: - Take

    @discardableResult
    func takeSnapshot(_ selector: VMSelector, name: String, notes: String) async throws
        -> SnapshotSummary
    {
        try await takeSnapshot(try resolve(selector), name: name, notes: notes)
    }

    /// Captures a snapshot and lists it in the manifest.
    ///
    /// The gate is re-read here rather than trusted from whenever the caller
    /// last looked: a sheet gathers a name and notes, and the VM can start,
    /// stop, or suspend while it is up.
    @discardableResult
    func takeSnapshot(_ instance: VMInstance, name: String, notes: String) async throws
        -> SnapshotSummary
    {
        try refuseIfBusy(instance)
        guard instance.canTakeSnapshot else { throw invalidState(instance) }
        let snapshot = try await captureSnapshot(instance, name: name, notes: notes)
        return snapshotSummary(snapshot, on: instance)
    }

    /// The capture itself, answering the snapshot that landed.
    ///
    /// Throws rather than reporting a nil, so a caller chaining off it (the
    /// revert's check-point) stops rather than proceeding on a lost checkpoint.
    private func captureSnapshot(
        _ instance: VMInstance, name: String, notes: String
    ) async throws -> VMSnapshot {
        // Stamped at confirm time, not when the caller decided: the VM can
        // start, stop, or suspend in between.
        guard let mode = instance.snapshotCaptureMode else {
            Self.logger.notice(
                "Refusing to snapshot '\(instance.name, privacy: .public)': the VM is no longer in a state to capture"
            )
            throw invalidState(instance)
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = VMSnapshot(
            name: trimmedName.isEmpty ? instance.snapshotManifest.defaultNewName : trimmedName,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: mode.kind)
        do {
            try await lifecycle.takeSnapshot(instance, snapshot: snapshot, store: snapshotStore)
        } catch {
            Self.logger.error(
                "Failed to take a snapshot of '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw failure(error, verb: .takeSnapshot, on: instance)
        }
        var manifest = instance.snapshotManifest
        manifest.insert(snapshot)
        do {
            try writeSnapshotManifest(manifest, for: instance, verb: .takeSnapshot)
        } catch {
            // Unlisted files are files no surface can reach or remove, so the
            // capture is undone rather than left orphaned in the bundle.
            let store = snapshotStore
            let bundleURL = instance.bundleURL
            let id = snapshot.id
            await Task.detached {
                store.removeSnapshotDirectory(bundleURL: bundleURL, snapshotID: id)
            }.value
            throw error
        }
        return snapshot
    }

    // MARK: - Revert

    func revertToSnapshot(
        _ selector: VMSelector, snapshot id: UUID, takingCheckpoint: Bool, confirmed: Bool
    ) async throws {
        let instance = try resolve(selector)
        let snapshot = try requireSnapshot(id, on: instance, verb: .revertToSnapshot)
        guard instance.canRevertToSnapshot else { throw invalidState(instance) }
        try refuseIfBusy(instance)
        guard confirmed else {
            throw CommandError.confirmationRequired(
                Self.revertPrompt(snapshot, on: instance))
        }
        if takingCheckpoint {
            // Required, not conditional: a VM that stopped being capturable
            // before the confirm landed aborts rather than falling through to
            // the destructive revert with no check-point.
            _ = try await captureSnapshot(
                instance, name: instance.snapshotManifest.defaultNewName, notes: "")
        }
        await startRevert(instance, to: snapshot).value
    }

    /// The refusal a revert raises, and the copy every surface renders it with.
    static func revertPrompt(_ snapshot: VMSnapshot, on instance: VMInstance) -> ConfirmationPrompt {
        // The safe path — check-point the current state, then revert — is
        // offered wherever a capture can be taken, which covers every at-rest
        // state; only a VM mid-operation is offered the revert alone.
        let alternatives =
            instance.canTakeSnapshot
            ? [
                ConfirmationAlternative(
                    title: "Take Snapshot, Then Revert", takesCheckpoint: true)
            ]
            : []
        return ConfirmationPrompt(
            kind: .revertToSnapshot,
            title: "Revert \u{201C}\(instance.name)\u{201D} to \u{201C}\(snapshot.name)\u{201D}?",
            message: revertMessage(snapshot, instance),
            confirmTitle: "Revert",
            alternatives: alternatives)
    }

    /// What the revert says the user is trading away, by what the target
    /// snapshot holds and what the VM holds now.
    static func revertMessage(_ snapshot: VMSnapshot, _ vm: VMInstance) -> String {
        let taken = SnapshotDateFormat.string(from: snapshot.createdAt)
        let guestLoss =
            vm.canTakeSnapshot
            ? "Everything changed inside the guest since then will be lost unless you take a snapshot first."
            : "Everything changed inside the guest since then will be lost."

        switch snapshot.kind {
        case .warm:
            // A cold-paused VM's own suspend slot is the state it would
            // otherwise resume into, and the revert writes over it.
            let loss =
                vm.isColdPaused
                ? "The suspended session this VM would resume into is replaced by the snapshot\u{2019}s, "
                    + "and everything changed inside the guest since then will be lost unless you "
                    + "take a snapshot first."
                : guestLoss
            return "The VM will return to the state and settings captured \(taken). "
                + "\(loss) The snapshot itself is kept."
        case .cold:
            // No memory image to come back on, so whatever session the VM holds
            // now — running or suspended — is gone rather than replaced.
            let session: String
            if vm.hasLiveVirtualMachine {
                session = "The session it is running now ends. "
            } else if vm.isColdPaused {
                session = "The suspended session it would resume into is discarded. "
            } else {
                session = ""
            }
            return "The VM will return to the disks and settings captured \(taken), powered off. "
                + "\(session)\(guestLoss) The snapshot itself is kept."
        }
    }

    /// Registers a revert and runs it.
    ///
    /// Registration happens *before this returns*, not when the copy starts:
    /// the task body runs no earlier than the caller's next suspension, so a
    /// termination gate that reads ``VMLibrary/hasRevertInFlight`` immediately
    /// after a power-off sees the revert the power-off requested. Registering
    /// from inside the task instead would leave a window where the revert is
    /// pending and invisible.
    @discardableResult
    func startRevert(_ instance: VMInstance, to snapshot: VMSnapshot) -> Task<Void, Never> {
        let requestID = UUID()
        let task = Task { [weak self] in
            await self?.performRevert(instance, to: snapshot)
            self?.library.revertTasks[requestID] = nil
        }
        library.revertTasks[requestID] = task
        return task
    }

    private func performRevert(_ instance: VMInstance, to snapshot: VMSnapshot) async {
        guard instance.snapshotManifest.snapshot(id: snapshot.id) != nil else {
            Self.logger.notice(
                "Refusing to revert '\(instance.name, privacy: .public)': the snapshot is no longer listed"
            )
            return
        }
        // A VM that is live goes back to being live once the files are in
        // place, so the window it comes up in is chosen before the teardown. A
        // cold snapshot ends the session for good, so there is none to choose.
        if instance.hasLiveVirtualMachine, snapshot.kind == .warm {
            surfaceDisplay?(instance)
        }
        do {
            try await lifecycle.revertToSnapshot(
                instance, snapshot: snapshot, store: snapshotStore)
        } catch {
            Self.logger.error(
                "Failed to revert '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            surfaceFailure(error)
            // A resume that failed left the reverted files in place, so the VM's
            // state does descend from this snapshot and the marker says so.
            guard case VirtualizationError.revertResumeFailed = error else { return }
        }
        var manifest = instance.snapshotManifest
        manifest.currentID = snapshot.id
        do {
            try writeSnapshotManifest(manifest, for: instance, verb: .revertToSnapshot)
        } catch {
            surfaceFailure(error)
        }
    }

    // MARK: - Ephemeral Mode

    /// Returns an Ephemeral Mode VM to its baseline after a power-off; a no-op
    /// for every other VM.
    ///
    /// Reached from ``VMInstance/onPoweredOff``, which fires inside the stop
    /// that caused it — so the revert runs in its own task, after that stop has
    /// released the VM.
    func revertToEphemeralBaselineIfNeeded(_ instance: VMInstance) {
        guard let baseline = instance.ephemeralBaselineSnapshot else { return }
        revertToEphemeralBaseline(instance, baseline)
    }

    /// The revert an ephemeral power-off performs, on the same path a
    /// user-confirmed revert takes — including its error surfacing, so a
    /// baseline that cannot be restored is never silently skipped.
    @discardableResult
    private func revertToEphemeralBaseline(
        _ instance: VMInstance, _ baseline: VMSnapshot
    ) -> Task<Void, Never> {
        Self.logger.notice(
            "Reverting ephemeral VM '\(instance.name, privacy: .public)' to its baseline '\(baseline.name, privacy: .public)'"
        )
        return startRevert(instance, to: baseline)
    }

    /// Routes a cold-paused ephemeral VM's Discard Saved State through the
    /// baseline revert instead, and reports whether it took the request.
    ///
    /// Discarding alone would drop the suspended session and leave the guest's
    /// disks as the session left them — the opposite of what the mode promises.
    func discardedSavedStateAsEphemeralRevert(_ instance: VMInstance) async -> Bool {
        guard instance.isColdPaused, let baseline = instance.ephemeralBaselineSnapshot else {
            return false
        }
        await revertToEphemeralBaseline(instance, baseline).value
        return true
    }

    // MARK: - Delete

    func deleteSnapshot(_ selector: VMSelector, snapshot id: UUID, confirmed: Bool) async throws {
        let instance = try resolve(selector)
        let snapshot = try requireSnapshot(id, on: instance, verb: .deleteSnapshot)
        // Re-checked at the write as well as at the confirmation: the baseline
        // is what every power-off of this VM needs back, and the mode can be
        // switched on while a confirmation is up.
        guard !instance.isEphemeralBaseline(snapshot) else {
            Self.logger.notice(
                "Refusing to delete snapshot '\(snapshot.name, privacy: .public)': it is the Ephemeral baseline of '\(instance.name, privacy: .public)'"
            )
            throw CommandError.unsupported(capability: "deleting a VM's Ephemeral Mode baseline")
        }
        try refuseIfBusy(instance)
        guard confirmed else {
            throw CommandError.confirmationRequired(
                Self.deleteSnapshotPrompt(snapshot, on: instance))
        }
        do {
            try await lifecycle.discardSnapshot(instance, snapshotID: id, store: snapshotStore)
        } catch {
            Self.logger.error(
                "Failed to trash snapshot '\(snapshot.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw failure(error, verb: .deleteSnapshot, on: instance)
        }
        var manifest = instance.snapshotManifest
        manifest.remove(id: id)
        try writeSnapshotManifest(manifest, for: instance, verb: .deleteSnapshot)
        Self.logger.notice(
            "Deleted snapshot '\(snapshot.name, privacy: .public)' of VM '\(instance.name, privacy: .public)'"
        )
    }

    /// The refusal a snapshot delete raises.
    static func deleteSnapshotPrompt(
        _ snapshot: VMSnapshot, on instance: VMInstance
    ) -> ConfirmationPrompt {
        ConfirmationPrompt(
            kind: .deleteSnapshot,
            title: "Delete \u{201C}\(snapshot.name)\u{201D}?",
            message:
                "Moves this snapshot\u{2019}s saved state and disk copies to the Trash. "
                + "\u{201C}\(instance.name)\u{201D} keeps the state it has now.",
            confirmTitle: "Delete")
    }

    // MARK: - Metadata

    /// Renames a snapshot; an empty or unchanged name is a no-op. A
    /// metadata-only manifest write: no VM operation reads it mid-flight, so
    /// it lands whether or not the VM is busy.
    func renameSnapshot(_ selector: VMSelector, snapshot id: UUID, to newName: String) throws {
        let instance = try resolve(selector)
        let snapshot = try requireSnapshot(id, on: instance, verb: .renameSnapshot)
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != snapshot.name else { return }
        var manifest = instance.snapshotManifest
        manifest.rename(id: id, to: trimmed)
        guard manifest != instance.snapshotManifest else { return }
        try writeSnapshotManifest(manifest, for: instance, verb: .renameSnapshot)
    }

    /// Replaces a snapshot's note; an unchanged value is a no-op. A
    /// metadata-only manifest write, like a rename.
    ///
    /// Unlike a name, an empty note is a legitimate value — it clears the note.
    /// Leading and trailing whitespace is trimmed; interior newlines are kept.
    func setSnapshotNotes(_ selector: VMSelector, snapshot id: UUID, notes: String) throws {
        let instance = try resolve(selector)
        let snapshot = try requireSnapshot(id, on: instance, verb: .setSnapshotNotes)
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != snapshot.notes else { return }
        var manifest = instance.snapshotManifest
        manifest.setNotes(id: id, to: trimmed)
        guard manifest != instance.snapshotManifest else { return }
        try writeSnapshotManifest(manifest, for: instance, verb: .setSnapshotNotes)
    }

    // MARK: - Manifest

    /// The snapshot `id` names on `instance`, or the refusal for one the
    /// manifest no longer lists.
    private func requireSnapshot(
        _ id: UUID, on instance: VMInstance, verb: VMVerb
    ) throws -> VMSnapshot {
        guard let snapshot = instance.snapshotManifest.snapshot(id: id) else {
            throw CommandError.operationFailed(
                verb: verb,
                message:
                    "\u{201C}\(instance.name)\u{201D} has no snapshot with the identifier \(id.uuidString)."
            )
        }
        return snapshot
    }

    /// Writes `manifest` to the bundle and mirrors it onto the instance.
    ///
    /// On failure the in-memory manifest is left alone, so what the UI shows
    /// still matches what is stored.
    private func writeSnapshotManifest(
        _ manifest: VMSnapshotManifest, for instance: VMInstance, verb: VMVerb
    ) throws {
        do {
            try snapshotStore.saveManifest(manifest, bundleURL: instance.bundleURL)
            instance.snapshotManifest = manifest
        } catch {
            Self.logger.error(
                "Failed to write the snapshot manifest for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw CommandError.operationFailed(verb: verb, message: error.localizedDescription)
        }
    }
}
