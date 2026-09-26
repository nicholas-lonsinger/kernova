import Foundation
import KernovaKit
import KernovaLogging

/// The snapshot verbs, and the Ephemeral Mode revert that rides the same path.
extension VMCommandCore {
    // MARK: - Sizes

    func snapshotOnDiskBytes(of selector: VMSelector) async throws -> [UUID: UInt64] {
        await snapshotOnDiskBytes(for: try resolve(selector))
    }

    /// Bytes each of this VM's snapshots occupies on disk.
    func snapshotOnDiskBytes(for instance: VMInstance) async -> [UUID: UInt64] {
        await instance.bundle.snapshotSizes()
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
        try require(.takeSnapshot, on: instance)
        let snapshot = try await captureSnapshot(instance, name: name, notes: notes)
        return snapshotSummary(snapshot, on: instance)
    }

    /// The capture itself, listed in the manifest inside the same capture
    /// operation, answering the snapshot that landed.
    ///
    /// Throws rather than reporting a nil, so a caller chaining off it (the
    /// revert's check-point) stops rather than proceeding on a lost checkpoint.
    private func captureSnapshot(
        _ instance: VMInstance, name: String, notes: String
    ) async throws -> VMSnapshot {
        // Stamped at confirm time, not when the caller decided: the VM can
        // start, stop, or suspend in between.
        guard
            let mode = VMAdmission.settledCaptureMode(
                phase: instance.phase, facts: instance.admissionFacts)
        else {
            #log(
                Self.logger, .notice,
                "Refusing to snapshot '\(instance.name, privacy: .public)': the VM is no longer in a state to capture"
            )
            throw invalidState(instance)
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = VMSnapshotCaptureRequest(
            name: trimmedName.isEmpty ? instance.snapshotManifest.defaultNewName : trimmedName,
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines))
        do {
            return try await lifecycle.takeSnapshot(instance, mode: mode, snapshot: snapshot) {
                captured in
                try self.commitSnapshotManifest(of: instance, verb: .takeSnapshot) {
                    $0.insert(captured)
                }
            }
        } catch {
            #log(
                Self.logger, .error,
                "Failed to take a snapshot of '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw failure(error, verb: .takeSnapshot, on: instance)
        }
    }

    // MARK: - Revert

    func revertToSnapshot(
        _ selector: VMSelector, snapshot id: UUID, takingCheckpoint: Bool, confirmed: Bool
    ) async throws {
        let instance = try resolve(selector)
        let snapshot = try requireSnapshot(id, on: instance)
        try require(.revertToSnapshot, on: instance)
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
        // Awaited *and* answered for: a caller that waited on the revert is told
        // whether the rollback happened, rather than getting a success while an
        // alert about the failure goes somewhere else.
        try await awaitRevert(instance, startRevert(instance, to: snapshot))
    }

    /// The refusal a revert raises, and the copy every surface renders it with.
    static func revertPrompt(_ snapshot: VMSnapshot, on instance: VMInstance) -> ConfirmationPrompt {
        // The safe path — check-point the current state, then revert — is
        // offered wherever a capture can be taken, which covers every at-rest
        // state; only a VM mid-operation is offered the revert alone.
        let alternatives =
            instance.snapshotCaptureMode != nil
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
            dismissTitle: "Cancel",
            alternatives: alternatives)
    }

    /// What the revert says the user is trading away, by what the target
    /// snapshot holds and what the VM holds now.
    static func revertMessage(_ snapshot: VMSnapshot, _ vm: VMInstance) -> String {
        let taken = SnapshotDateFormat.string(from: snapshot.createdAt)
        let guestLoss =
            vm.snapshotCaptureMode != nil
            ? "Everything changed inside the guest since then will be lost unless you take a snapshot first."
            : "Everything changed inside the guest since then will be lost."

        switch snapshot.kind {
        case .warm:
            // The VM's own suspend slot is the state it would otherwise resume
            // into, and the revert writes over it.
            let loss =
                vm.holdsSuspendedSession
                ? "The suspended session this VM would resume into is replaced by the snapshot's, "
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
            } else if vm.holdsSuspendedSession {
                session = "The suspended session it would resume into is discarded. "
            } else {
                session = ""
            }
            return "The VM will return to the disks and settings captured \(taken), powered off. "
                + "\(session)\(guestLoss) The snapshot itself is kept."
        }
    }

    /// Starts the revert of `instance` to `snapshot`, admitted and committed
    /// before this returns — so a termination gate or a Start that reads the
    /// VM right after a power-off finds the revert that power-off requested —
    /// and answers its outcome.
    ///
    /// The manifest's current marker is written inside the revert operation,
    /// once the snapshot's files are in the bundle.
    func startRevert(
        _ instance: VMInstance, to snapshot: VMSnapshot, origin: VMRequestOrigin = .newWork
    ) throws -> VMOutcome {
        guard instance.snapshotManifest.snapshot(id: snapshot.id) != nil else {
            #log(
                Self.logger, .notice,
                "Refusing to revert '\(instance.name, privacy: .public)': the snapshot is no longer listed"
            )
            throw CommandError.operationFailed(
                verb: .revertToSnapshot,
                message:
                    "\u{201C}\(instance.name)\u{201D} no longer lists the snapshot \u{201C}\(snapshot.name)\u{201D}."
            )
        }
        // A VM that is live goes back to being live once the files are in
        // place; a cold snapshot ends the session for good.
        let resumesAfter = instance.phase.isSettledLive && snapshot.kind == .warm
        let outcome: VMOutcome
        do {
            outcome = try lifecycle.startRevert(
                instance, to: snapshot, resumesAfter: resumesAfter, origin: origin,
                commitConfiguration: { [library] plan in
                    try library.commitRevertedConfiguration(plan, on: instance)
                },
                landed: { [weak self] in
                    try self?.commitSnapshotManifest(of: instance, verb: .revertToSnapshot) {
                        $0.currentID = snapshot.id
                    }
                })
        } catch {
            throw failure(error, verb: .revertToSnapshot, on: instance)
        }
        // The window the VM comes back up in is chosen before the teardown
        // the revert's task begins with.
        if resumesAfter { readyDisplay?(instance) }
        return outcome
    }

    /// Waits for the revert `outcome` belongs to and throws how it failed.
    private func awaitRevert(_ instance: VMInstance, _ outcome: VMOutcome) async throws {
        do {
            try await outcome.value()
        } catch {
            #log(
                Self.logger, .error,
                "Failed to revert '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw failure(error, verb: .revertToSnapshot, on: instance)
        }
    }

    // MARK: - Ephemeral Mode

    /// Returns an Ephemeral Mode VM to its baseline after a power-off; a no-op
    /// for every other VM.
    ///
    /// Reached from ``VMActivity/onPoweredOff``, which fires in the step that
    /// rests the VM — so the revert is admitted there, before anything else can
    /// be decided against the VM, and a failure nobody waits on is reported.
    func revertToEphemeralBaselineIfNeeded(_ instance: VMInstance) {
        guard let baseline = instance.ephemeralBaselineSnapshot else { return }
        #log(
            Self.logger, .notice,
            "Reverting ephemeral VM '\(instance.name, privacy: .public)' to its baseline '\(baseline.name, privacy: .public)'"
        )
        let outcome: VMOutcome
        do {
            outcome = try startRevert(instance, to: baseline, origin: .powerOffRevert)
        } catch {
            report(failure(error, verb: .revertToSnapshot, on: instance), on: instance)
            return
        }
        Task { [weak self] in
            do {
                try await outcome.value()
            } catch {
                guard let self else { return }
                self.report(self.failure(error, verb: .revertToSnapshot, on: instance), on: instance)
            }
        }
    }

    /// Routes an ephemeral VM's Discard Saved State through the baseline revert
    /// instead, and reports whether it took the request.
    ///
    /// Discarding alone would drop the suspended session and leave the guest's
    /// disks as the session left them — the opposite of what the mode promises.
    ///
    /// Throws what the revert failed with: the caller asked for a stop, and a
    /// baseline that did not come back is not one.
    func discardedSavedStateAsEphemeralRevert(_ instance: VMInstance) async throws -> Bool {
        guard instance.holdsSuspendedSession, let baseline = instance.ephemeralBaselineSnapshot
        else { return false }
        #log(
            Self.logger, .notice,
            "Reverting ephemeral VM '\(instance.name, privacy: .public)' to its baseline '\(baseline.name, privacy: .public)'"
        )
        try await awaitRevert(instance, startRevert(instance, to: baseline))
        return true
    }

    // MARK: - Delete

    func deleteSnapshot(_ selector: VMSelector, snapshot id: UUID, confirmed: Bool) async throws {
        let instance = try resolve(selector)
        let snapshot = try requireSnapshot(id, on: instance)
        // Re-checked at the write as well as at the confirmation: the baseline
        // is what every power-off of this VM needs back, and the mode can be
        // switched on while a confirmation is up.
        guard !instance.isEphemeralBaseline(snapshot) else {
            #log(
                Self.logger, .notice,
                "Refusing to delete snapshot '\(snapshot.name, privacy: .public)': it is the Ephemeral baseline of '\(instance.name, privacy: .public)'"
            )
            throw CommandError.unsupported(capability: "deleting a VM's Ephemeral Mode baseline")
        }
        try require(.deleteSnapshot, on: instance)
        guard confirmed else {
            throw CommandError.confirmationRequired(
                Self.deleteSnapshotPrompt(snapshot, on: instance))
        }
        // Unlisted first, then trashed: a manifest write that fails leaves the
        // snapshot listed with its files in place, and a trash that fails
        // leaves no entry pointing at files that are gone — only an unlisted
        // directory, which costs space and no data.
        var unlisted = false
        do {
            try await lifecycle.discardSnapshot(instance, snapshotID: id) {
                try self.commitSnapshotManifest(of: instance, verb: .deleteSnapshot) {
                    $0.remove(id: id)
                }
                unlisted = true
            }
        } catch let failure as CommandError {
            throw failure
        } catch {
            #log(
                Self.logger, .error,
                "Failed to trash snapshot '\(snapshot.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            guard unlisted else { throw failure(error, verb: .deleteSnapshot, on: instance) }
            throw CommandError.operationFailed(
                verb: .deleteSnapshot,
                message:
                    "\u{201C}\(snapshot.name)\u{201D} was removed from the list, but its files could not be moved to the Trash. \(error.localizedDescription)"
            )
        }
        #log(
            Self.logger, .notice,
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
                "Moves this snapshot's saved state and disk copies to the Trash. "
                + "\u{201C}\(instance.name)\u{201D} keeps the state it has now.",
            confirmTitle: "Delete",
            dismissTitle: "Cancel")
    }

    // MARK: - Metadata

    /// Renames a snapshot; an empty name, an unchanged one, and one naming a
    /// snapshot the manifest no longer lists are all no-ops, and a rename that
    /// would change the name is refused while the VM's state holds its
    /// snapshot metadata.
    ///
    /// What decides is whether the write would change anything, rather than
    /// whether the snapshot is still there: the inline field commits on
    /// end-editing whether or not the text changed, so a row deleted while its
    /// editor was open must not raise an alert about a rename nobody made.
    func renameSnapshot(_ selector: VMSelector, snapshot id: UUID, to newName: String) throws {
        let instance = try resolve(selector)
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let snapshot = instance.snapshotManifest.snapshot(id: id),
            snapshot.name != trimmed
        else { return }
        try require(.renameSnapshot, on: instance)
        try commitSnapshotManifest(of: instance, verb: .renameSnapshot) {
            $0.rename(id: id, to: trimmed)
        }
    }

    /// Replaces a snapshot's note; a write that would change nothing is a
    /// no-op, and one that would is refused, on the same terms a rename's are.
    ///
    /// Unlike a name, an empty note is a legitimate value — it clears the note.
    /// Leading and trailing whitespace is trimmed; interior newlines are kept.
    func setSnapshotNotes(_ selector: VMSelector, snapshot id: UUID, notes: String) throws {
        let instance = try resolve(selector)
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let snapshot = instance.snapshotManifest.snapshot(id: id), snapshot.notes != trimmed
        else { return }
        try require(.setSnapshotNotes, on: instance)
        try commitSnapshotManifest(of: instance, verb: .setSnapshotNotes) {
            $0.setNotes(id: id, to: trimmed)
        }
    }

    // MARK: - Manifest

    /// The snapshot `id` names on `instance`, or the refusal for one the
    /// manifest no longer lists.
    private func requireSnapshot(_ id: UUID, on instance: VMInstance) throws -> VMSnapshot {
        guard let snapshot = instance.snapshotManifest.snapshot(id: id) else {
            throw itemNotFound(instance, item: "snapshot with the identifier \(id.uuidString)")
        }
        return snapshot
    }

    /// Commits `change` to the bundle's manifest, applied to what the file
    /// holds; a change that moves nothing writes nothing.
    ///
    /// On failure the manifest stays as the bundle holds it, and the verb is
    /// refused.
    private func commitSnapshotManifest(
        of instance: VMInstance, verb: VMVerb, _ change: (inout VMSnapshotManifest) -> Void
    ) throws {
        do {
            try instance.bundle.commitSnapshotManifest(change)
        } catch {
            #log(
                Self.logger, .error,
                "Failed to write the snapshot manifest for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw CommandError.operationFailed(verb: verb, message: error.localizedDescription)
        }
    }
}
