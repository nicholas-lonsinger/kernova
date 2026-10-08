import Foundation
import KernovaKit
import KernovaLogging

/// The snapshot verbs, and the Ephemeral Mode revert that rides the same path.
extension VMCommandCore {
    // MARK: - Sizes

    func snapshotSizes(of selector: VMSelector) async throws -> [UUID: SnapshotSize] {
        await snapshotSizes(for: try resolve(selector))
    }

    /// The size of each of this VM's snapshots.
    func snapshotSizes(for instance: VMInstance) async -> [UUID: SnapshotSize] {
        await instance.bundle.snapshotSizes()
    }

    // MARK: - Take

    @discardableResult
    func takeSnapshot(
        _ selector: VMSelector, name: String, notes: String, asEphemeralBaseline: Bool
    ) async throws -> SnapshotSummary {
        try await takeSnapshot(
            try resolve(selector), name: name, notes: notes,
            asEphemeralBaseline: asEphemeralBaseline)
    }

    /// Captures a snapshot and lists it in the manifest.
    ///
    /// The gate is re-read here rather than trusted from whenever the caller
    /// last looked: a sheet gathers a name and notes, and the VM can start,
    /// stop, or suspend while it is up.
    @discardableResult
    func takeSnapshot(
        _ instance: VMInstance, name: String, notes: String, asEphemeralBaseline: Bool = false
    ) async throws -> SnapshotSummary {
        try require(.takeSnapshot, on: instance)
        var baselineFailure: (any Error)?
        let snapshot = try await captureSnapshot(instance, name: name, notes: notes) {
            permit, captured in
            guard asEphemeralBaseline else { return }
            // The snapshot stands as a restore point whether or not the mode
            // turns on, so this failure is reported rather than undoing it.
            do {
                try permit.bundle.commitHostState {
                    $0.applyEphemeralMode(enabled: true, baseline: captured.id)
                }
            } catch {
                baselineFailure = error
            }
        }
        if let baselineFailure {
            #log(
                Self.logger, .error,
                "Took a snapshot of '\(instance.name, privacy: .public)' but could not make it the Ephemeral baseline: \(baselineFailure.localizedDescription, privacy: .public)"
            )
            throw CommandError.operationFailed(
                verb: .takeSnapshot,
                message:
                    "The snapshot \u{201C}\(snapshot.name)\u{201D} was taken, but Ephemeral Mode "
                    + "could not be turned on: \(baselineFailure.localizedDescription)")
        }
        return snapshotSummary(snapshot, on: instance)
    }

    /// The capture itself, listed in the manifest inside the same capture
    /// operation, answering the snapshot that landed; `alsoRecord` writes
    /// beside that listing under the same permit.
    ///
    /// Throws rather than reporting a nil, so a caller chaining off it (the
    /// revert's check-point) stops rather than proceeding on a lost checkpoint.
    private func captureSnapshot(
        _ instance: VMInstance, name: String, notes: String,
        alsoRecord: @MainActor (borrowing VMEditPermit, VMSnapshot) -> Void = { _, _ in }
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
                permit, captured in
                try self.commitSnapshotManifest(permit, verb: .takeSnapshot) { $0.insert(captured) }
                alsoRecord(permit, captured)
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

    /// A remedy the caller chose for a MAC address conflict the resume would
    /// meet makes the revert land at rest, takes the remedy there — on the
    /// snapshot's saved state — and then starts the VM the way its state
    /// names.
    func revertToSnapshot(
        _ selector: VMSelector, snapshot id: UUID, takingCheckpoint: Bool, consent: Consent,
        macAddressRemedy: MACAddressRemedy? = nil
    ) async throws {
        let instance = try resolve(selector)
        let snapshot = try requireSnapshot(id, on: instance)
        try require(.revertToSnapshot, on: instance)
        if takingCheckpoint, let refusal = checkpointRefusal(on: instance) { throw refusal }
        guard consent.covers(.revertToSnapshot) else {
            throw CommandError.confirmationRequired(
                Self.revertPrompt(snapshot, on: instance))
        }
        let identity = VMIdentityOverride(consent)
        // Decided before the check-point, as a start is decided before
        // anything else: a revert refused — or asking whether to resume beside
        // a VM sharing its machine identity — refuses before a capture its
        // re-issue would take a second time.
        let decision = instance.activity.decide(
            .operation(
                .bringUp(
                    .reverting(
                        snapshotID: snapshot.id,
                        resumesAfter: Self.revertResumes(instance, to: snapshot)))),
            posture: .commit, identity: identity)
        let remedy = try macAddressRemedyToTake(
            macAddressRemedy, answering: decision, on: instance, identity: identity,
            holdingSavedState: true, accountFor: false, verb: .revertToSnapshot)
        if remedy == nil, case .refuse(let reason) = decision {
            throw admissionRefusal(reason, on: instance, verb: .revertToSnapshot)
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
        guard let remedy else {
            try await awaitRevert(
                instance, startRevert(instance, to: snapshot, identity: identity))
            return
        }
        try await awaitRevert(instance, startRevert(instance, to: snapshot, resuming: false))
        do {
            try takeMACAddressRemedy(remedy, on: instance, verb: .revertToSnapshot)
            try await startNow(instance, policy: .command(identity)).value()
        } catch {
            throw bringUpFailure(error, verb: .revertToSnapshot, on: instance)
        }
    }

    /// The refusal a revert asked to take a check-point raises when Take
    /// Snapshot would refuse, naming the check-point as what blocks it —
    /// raised before consent is asked, so a surface never confirms a revert
    /// whose check-point is then refused.
    private func checkpointRefusal(on instance: VMInstance) -> CommandError? {
        guard instance.snapshotCaptureMode == nil else { return nil }
        let reason: String
        if case .refuse(let refusal)? = capabilities.decision(
            .takeSnapshot, on: instance, posture: .offer),
            case .takesStoppedVM = refusal
        {
            reason = commandError(for: refusal, on: instance).message
        } else {
            reason = "\u{201C}\(instance.name)\u{201D} cannot take a snapshot in its current state."
        }
        return .operationFailed(
            verb: .revertToSnapshot,
            message: reason
                + " Revert without taking a snapshot first to go back anyway; everything "
                + "changed inside the guest since the snapshot will be lost.")
    }

    /// The refusal a revert raises, and the copy every surface renders it with.
    static func revertPrompt(_ snapshot: VMSnapshot, on instance: VMInstance) -> ConfirmationPrompt {
        // The safe path — check-point the current state, then revert — is
        // offered wherever Take Snapshot is admitted.
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
        let unlessCheckpoint = vm.snapshotCaptureMode != nil ? " unless you take a snapshot first" : ""
        let guestLoss = "Everything changed inside the guest since then will be lost\(unlessCheckpoint)."

        switch snapshot.kind {
        case .warm:
            // The VM's own suspend slot is the state it would otherwise resume
            // into, and the revert writes over it.
            let loss =
                vm.holdsSuspendedSession
                ? "The suspended session this VM would resume into is replaced by the snapshot's, "
                    + "and everything changed inside the guest since then will be lost\(unlessCheckpoint)."
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
    /// VM next finds the revert — and answers its outcome.
    ///
    /// The manifest's current marker is written inside the revert operation,
    /// once the snapshot's files are in the bundle.
    ///
    /// `identity` is what the caller can do about another active VM sharing
    /// the machine identity a revert that resumes would claim.
    ///
    /// `resuming` `false` lands a revert that would resume at rest instead.
    func startRevert(
        _ instance: VMInstance, to snapshot: VMSnapshot,
        identity: VMIdentityOverride = .unavailable, resuming: Bool = true
    ) throws -> VMOutcome {
        do {
            return try launchRevert(
                instance, to: snapshot, origin: .newWork, identity: identity,
                resuming: resuming, resolving: VMOutcome())
        } catch {
            throw failure(error, verb: .revertToSnapshot, on: instance)
        }
    }

    /// ``startRevert(_:to:identity:)`` resolving `outcome`, throwing what refused it as
    /// it was raised.
    @discardableResult
    private func launchRevert(
        _ instance: VMInstance, to snapshot: VMSnapshot, origin: VMRequestOrigin,
        identity: VMIdentityOverride = .unavailable, resuming: Bool = true,
        resolving outcome: VMOutcome
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
        let resumesAfter = resuming && Self.revertResumes(instance, to: snapshot)
        try lifecycle.startRevert(
            instance, to: snapshot, resumesAfter: resumesAfter, origin: origin,
            identity: identity, resolving: outcome,
            commitConfiguration: { [library] permit, plan in
                try library.commitRevertedConfiguration(plan, permit)
            },
            landed: { [weak self] permit in
                try self?.commitSnapshotManifest(permit, verb: .revertToSnapshot) {
                    $0.currentID = snapshot.id
                }
            })
        // The window the VM comes back up in is chosen before the teardown
        // the revert's task begins with.
        if resumesAfter { readyDisplay?(instance, .attended) }
        return outcome
    }

    /// Whether reverting `instance` to `snapshot` resumes the guest: a VM that
    /// is live goes back to being live once the files are in place, and a cold
    /// snapshot ends the session for good.
    private static func revertResumes(_ instance: VMInstance, to snapshot: VMSnapshot) -> Bool {
        instance.phase.isSettledLive && snapshot.kind == .warm
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

    /// The revert to its baseline an Ephemeral Mode VM owes a power-off, as a
    /// follow-up; `nil` for every other VM.
    ///
    /// Answered from ``VMActivity/onPoweredOff``, whose step drains it: a
    /// restoration, it takes the VM before any other follow-up queued there
    /// and before anything else can be decided against the VM. A failure
    /// nobody waits on is reported.
    func ephemeralBaselineRevert(for instance: VMInstance) -> VMFollowUp? {
        guard let baseline = instance.ephemeralBaselineSnapshot else { return nil }
        return VMFollowUp(scope: .vm, rank: .restoration) { [weak self, weak instance] outcome in
            guard let self, let instance else { throw CancellationError() }
            #log(
                Self.logger, .notice,
                "Reverting ephemeral VM '\(instance.name, privacy: .public)' to its baseline '\(baseline.name, privacy: .public)'"
            )
            try self.launchRevert(
                instance, to: baseline, origin: .powerOffRevert, resolving: outcome)
        }
        .reportingFailure { [weak self] error in
            guard let self else { return }
            self.report(self.failure(error, verb: .revertToSnapshot, on: instance), on: instance)
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

    func deleteSnapshot(_ selector: VMSelector, snapshot id: UUID, consent: Consent) async throws {
        let instance = try resolve(selector)
        let snapshot = try requireSnapshot(id, on: instance)
        try require(.deleteSnapshot, on: instance)
        _ = try requireDelete(snapshot, on: instance, consent: consent)
        // Unlisted first, then trashed: a manifest write that fails leaves the
        // snapshot listed with its files in place, and a trash that fails
        // leaves no entry pointing at files that are gone — only an unlisted
        // directory, which costs space and no data.
        var unlisted = false
        do {
            try await lifecycle.discardSnapshot(instance, snapshotID: id) { permit in
                // Decided again under the permit: Ephemeral Mode can come to
                // name this snapshot while a confirmation is up, and a consent
                // given for the plain delete does not cover turning it off.
                let delete = try self.requireDelete(snapshot, on: instance, consent: consent)
                try self.unlist(id, as: delete, permit)
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

    /// What deleting one snapshot writes besides the manifest.
    enum SnapshotDelete: Equatable {
        /// The snapshot alone.
        case plain
        /// The VM's Ephemeral Mode baseline: Ephemeral Mode turns off with it.
        case endingEphemeralMode
    }

    /// What deleting `snapshot` from `instance` is right now.
    static func delete(of snapshot: VMSnapshot, on instance: VMInstance) -> SnapshotDelete {
        instance.isEphemeralBaseline(snapshot) ? .endingEphemeralMode : .plain
    }

    /// The delete of `snapshot` from `instance` as it stands now, refused
    /// without the consent ``deleteSnapshotPrompt(_:on:)`` asks for.
    private func requireDelete(
        _ snapshot: VMSnapshot, on instance: VMInstance, consent: Consent
    ) throws -> SnapshotDelete {
        let prompt = Self.deleteSnapshotPrompt(snapshot, on: instance)
        guard consent.covers(prompt.kind) else {
            throw CommandError.confirmationRequired(prompt)
        }
        return Self.delete(of: snapshot, on: instance)
    }

    /// Takes snapshot `id` off the manifest of the VM `permit` writes —
    /// turning Ephemeral Mode off first for the delete of its baseline, so a
    /// write that fails part-way leaves the mode off with the snapshot still
    /// listed, never the mode on with its baseline gone.
    private func unlist(
        _ id: UUID, as delete: SnapshotDelete, _ permit: borrowing VMEditPermit
    ) throws {
        if delete == .endingEphemeralMode {
            try commitHostState(permit, verb: .deleteSnapshot) {
                $0.applyEphemeralMode(enabled: false, baseline: nil)
            }
            let name = permit.instance.name
            #log(
                Self.logger, .notice,
                "Turned Ephemeral Mode off for '\(name, privacy: .public)' to delete its baseline"
            )
        }
        try commitSnapshotManifest(permit, verb: .deleteSnapshot) { $0.remove(id: id) }
    }

    /// The confirmation deleting `snapshot` from `instance` asks for right
    /// now — the one a surface shows before the delete, and the refusal the
    /// delete raises without its kind in the consent.
    static func deleteSnapshotPrompt(
        _ snapshot: VMSnapshot, on instance: VMInstance
    ) -> ConfirmationPrompt {
        let name = "\u{201C}\(snapshot.name)\u{201D}"
        let vm = "\u{201C}\(instance.name)\u{201D}"
        return switch delete(of: snapshot, on: instance) {
        case .plain:
            ConfirmationPrompt(
                kind: .deleteSnapshot,
                title: "Delete \(name)?",
                message:
                    "Moves this snapshot's saved state and disk copies to the Trash. "
                    + "\(vm) keeps the state it has now.",
                confirmTitle: "Delete",
                dismissTitle: "Cancel")
        case .endingEphemeralMode:
            ConfirmationPrompt(
                kind: .deleteEphemeralBaseline,
                title: "Delete \(name)?",
                message:
                    "\(name) is the snapshot Ephemeral Mode returns \(vm) to. Deleting it turns "
                    + "Ephemeral Mode off for this virtual machine, so later power-offs keep "
                    + "their changes. Its saved state and disk copies move to the Trash.",
                confirmTitle: "Delete",
                dismissTitle: "Cancel")
        }
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
        try edit(.renameSnapshot, on: instance, verb: .renameSnapshot) { permit in
            try commitSnapshotManifest(permit, verb: .renameSnapshot) { $0.rename(id: id, to: trimmed) }
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
        try edit(.setSnapshotNotes, on: instance, verb: .setSnapshotNotes) { permit in
            try commitSnapshotManifest(permit, verb: .setSnapshotNotes) {
                $0.setNotes(id: id, to: trimmed)
            }
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

    /// Commits `change` to the manifest of the VM `permit` writes, applied to
    /// what the file holds; a change that moves nothing writes nothing.
    ///
    /// On failure the manifest stays as the bundle holds it, and the verb is
    /// refused.
    private func commitSnapshotManifest(
        _ permit: borrowing VMEditPermit, verb: VMVerb,
        _ change: (inout VMSnapshotManifest) -> Void
    ) throws {
        try committing("snapshot manifest", of: permit.instance, verb: verb) {
            try permit.bundle.commitSnapshotManifest(change)
        }
    }

    /// ``commitSnapshotManifest(_:verb:_:)`` for the host state.
    private func commitHostState(
        _ permit: borrowing VMEditPermit, verb: VMVerb, _ change: (inout VMHostState) -> Void
    ) throws {
        try committing("host state", of: permit.instance, verb: verb) {
            try permit.bundle.commitHostState(change)
        }
    }

    /// Runs `commit`, a write of one of `instance`'s state files, refusing
    /// `verb` with what the write failed with.
    private func committing(
        _ file: String, of instance: VMInstance, verb: VMVerb, _ commit: () throws -> Void
    ) throws {
        do {
            try commit()
        } catch let refused as VMAdmissionRefusal {
            throw admissionRefusal(refused.refusal, on: instance, verb: verb)
        } catch {
            #log(
                Self.logger, .error,
                "Failed to write the \(file, privacy: .public) for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw CommandError.failed(verb: verb, error: error)
        }
    }
}
