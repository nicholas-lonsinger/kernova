import Foundation
import KernovaLogging

/// Drives a running VM's XHCI removable-media list to whatever its
/// configuration asks for, coalescing rapid edits into one pass per instance
/// and settling the configuration on the live list when VZ refuses.
///
/// Headless: the configuration write and the alert both leave through hooks,
/// so every configuration write stays ``VMLibrary``'s.
@MainActor
final class VMRemovableMediaReconciler {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMRemovableMediaReconciler")

    private let lifecycle: VMLifecycleCoordinator

    /// Points the configuration's removable-media list at the one a refused
    /// reconcile left live — ``VMLibrary/settleRemovableMedia(of:toLive:)``.
    var onSettle: ((VMInstance, [RemovableMediaItem]?) -> Void)?

    /// Receives every failure the reconcile needs a user to see.
    var onFailure: ((any Error) -> Void)?

    /// VMs with an in-flight removable-media reconciliation Task.
    ///
    /// With `pendingRemovableMediaTarget`, coalesces rapid edits into one Task per
    /// instance: the `await`s inside `applyLiveRemovableMediaChange` leave the actor
    /// reentrant, so a second Task would read the same tracking and issue duplicate
    /// detach/attach operations.
    private var reconcilingRemovableMediaInstances: Set<UUID> = []

    /// Latest desired removable media list per instance, drained by
    /// `runRemovableMediaReconciliation` until empty.
    private var pendingRemovableMediaTarget: [UUID: PendingRemovableMediaChange] = [:]

    /// A removable-media target waiting to be applied, bound to the session it
    /// was queued for.
    ///
    /// The binding is what a queued entry needs and a per-pass capture cannot
    /// give it: an entry outlives the session that queued it whenever the drain
    /// is behind — a stop or force stop, an edit made while stopped (which
    /// returns before replacing the entry, having no session to act on), and a
    /// restart all leave it queued — and draining it under the successor's
    /// token would drive the new session's controller to a list its user never
    /// asked for.
    private struct PendingRemovableMediaChange {
        let sessionID: UUID
        let target: [RemovableMediaItem]
    }

    init(lifecycle: VMLifecycleCoordinator) {
        self.lifecycle = lifecycle
    }

    /// Refuses a configuration edit that changes `removableMedia` while the VM
    /// has a session no pass can drive: a persisted list the live device set
    /// does not match would be pinned into the in-flight save or snapshot and
    /// never re-driven.
    ///
    /// - Returns: `true` when the caller must abort.
    func refuseUnattachableEdit(
        on instance: VMInstance, movingFrom old: VMConfiguration, to new: VMConfiguration
    ) -> Bool {
        guard VMConfiguration.removableMediaChanged(old: old, new: new),
            instance.liveSessionID != nil, instance.attachableSessionID == nil
        else { return false }
        #log(
            Self.logger, .notice,
            "Refusing removable-media edit for '\(instance.name, privacy: .public)': session is live but not attachable in \(instance.status.rawValue, privacy: .public)"
        )
        return true
    }

    /// Queues the runtime XHCI list-diff a `removableMedia` change asks for.
    ///
    /// No-ops when the list is unchanged, or when the VM has no session to
    /// attach to.
    func apply(for instance: VMInstance, old: VMConfiguration, new: VMConfiguration) {
        let mediaChanged = VMConfiguration.removableMediaChanged(old: old, new: new)
        // Only dispatch when there is a session to attach to. A stopped VM
        // persists the new media list and picks it up on next start; a VM whose
        // session is live but unattachable never reaches here,
        // `updateConfiguration` having refused the edit.
        guard mediaChanged, let sessionID = instance.attachableSessionID else { return }

        let id = instance.instanceID
        pendingRemovableMediaTarget[id] = PendingRemovableMediaChange(
            sessionID: sessionID, target: new.removableMedia ?? [])
        // Marked before the Task hop, on every enqueue: a lifecycle operation
        // issued in the same turn must already see the debt, and an edit for a
        // successor session queued behind a running pass owes it on that
        // successor's context, which the running pass drains and clears.
        instance.markRemovableMediaReconcileOwed(for: sessionID)
        guard !reconcilingRemovableMediaInstances.contains(id) else { return }
        reconcilingRemovableMediaInstances.insert(id)
        Task { [weak self] in
            await self?.runRemovableMediaReconciliation(for: instance, id: id)
        }
    }

    /// Drains `pendingRemovableMediaTarget` for a single instance until empty.
    ///
    /// Writes that arrive during a pass are picked up by the next iteration, so rapid
    /// edits always converge to the final user-selected state.
    ///
    /// Each pass carries the token its entry was queued with all the way down,
    /// so a stop — or a stop and a restart — mid-pass abandons the pass rather
    /// than driving whatever is live by then.
    ///
    /// An entry whose session is no longer the attachable one is dropped, not
    /// left queued: `VMLifecycleCoordinator` waits out the debt `apply` marks
    /// before running any serialized operation, so a live session cannot be
    /// moved out of attachability while a pass is owed — only torn down, which
    /// makes the entry stale. The debt is cleared on whichever session is live
    /// once the queue is empty — attachable or not, so the flag never outlives
    /// the queue on a context that survives the pass; a session torn down
    /// mid-pass dropped its own flag with its context.
    ///
    /// A refused pass is answered only once the queue is empty, and only when
    /// it was the last pass: an edit queued behind it is what the
    /// configuration holds and what the next pass drives the VM to, so
    /// settling the configuration on the live list before then would overwrite
    /// that edit with a list the VM is about to leave.
    private func runRemovableMediaReconciliation(for instance: VMInstance, id: UUID) async {
        defer {
            reconcilingRemovableMediaInstances.remove(id)
            if let live = instance.liveSessionID {
                instance.clearRemovableMediaReconcileOwed(for: live)
            }
        }
        var refused: RefusedPass?
        while let pending = pendingRemovableMediaTarget[id] {
            pendingRemovableMediaTarget.removeValue(forKey: id)
            guard let sessionID = instance.attachableSessionID, pending.sessionID == sessionID else {
                #log(
                    Self.logger, .notice,
                    "Dropping queued removable-media target for '\(instance.name, privacy: .public)': session \(pending.sessionID, privacy: .public) is no longer live"
                )
                continue
            }
            refused = await applyLiveRemovableMediaChange(
                for: instance, target: pending.target, actingFor: sessionID)
        }
        if let refused {
            failReconcile(for: instance, refused)
        }
    }

    /// A pass VZ refused part-way.
    private struct RefusedPass {
        /// The session the pass acted for.
        let sessionID: UUID
        /// Each entry the settled list can name, by id — see
        /// ``applyLiveRemovableMediaChange(for:target:actingFor:)``.
        let lookup: [UUID: RemovableMediaItem]
        let error: any Error
    }

    /// Reconciles the live removable media list with `target`, diffing per id against
    /// `instance.liveRemovableMedia`.
    ///
    /// Detaches run before attaches, so swapping the medium in a slot cannot collide
    /// with itself on a duplicate UUID.
    ///
    /// An unexpected detach or attach error stops the pass and is answered as a
    /// ``RefusedPass``, from which the configuration is settled on
    /// `instance.liveRemovableMedia` — so the UI snaps to what is actually
    /// attached rather than describing a state VZ refused. `deviceNotFound`
    /// (which also covers a guest-side eject) and `noVirtualMachine` are handled
    /// as confirmed-gone / silent bail.
    ///
    /// Every framework call and bookkeeping write here acts for `sessionID` and
    /// drops once that session is no longer live.
    private func applyLiveRemovableMediaChange(
        for instance: VMInstance,
        target: [RemovableMediaItem],
        actingFor sessionID: UUID
    ) async -> RefusedPass? {
        let tracked = instance.liveRemovableMedia
        // Tolerate duplicate ids: a hand-edited or corrupted config.json could ship
        // two `removableMedia` entries with the same UUID, and a uniquing-free
        // Dictionary init would trap and take the host app down.
        let targetByID = Dictionary(target.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let trackedByID = Dictionary(tracked.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Rollback lookup: tracked entries win over target entries on id collisions,
        // so a row that failed mid-swap restores its original path/readOnly. A
        // rebuilt entry keeps its persisted bookmark only when the config row still
        // matches the live path — a mid-swap rollback can't recover the old path's
        // bookmark, so it rolls back bookmark-less and the missing-file UX takes over.
        let configuredByID = Dictionary(
            (instance.configuration.removableMedia ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        var rollbackLookup: [UUID: RemovableMediaItem] = [:]
        for info in tracked {
            let configured = configuredByID[info.id]
            // Start from the persisted entry so its label and note survive the
            // rollback; only the fields the live state actually answers for
            // (path, readOnly, and the bookmark's validity) are overridden.
            var copy =
                configured
                ?? RemovableMediaItem(id: info.id, path: info.path, readOnly: info.readOnly, bookmark: nil)
            copy.path = info.path
            copy.readOnly = info.readOnly
            copy.bookmark = configured?.path == info.path ? configured?.bookmark : nil
            rollbackLookup[info.id] = copy
        }
        for item in target where rollbackLookup[item.id] == nil {
            rollbackLookup[item.id] = item
        }

        var toDetach: [RemovableMediaDeviceInfo] = []
        var toAttach: [RemovableMediaItem] = []
        for trackedItem in tracked {
            guard let desired = targetByID[trackedItem.id] else {
                toDetach.append(trackedItem)
                continue
            }
            if desired.path != trackedItem.path || desired.readOnly != trackedItem.readOnly {
                toDetach.append(trackedItem)
                toAttach.append(desired)
            }
        }
        // Iterate the deduped dictionary, not `target`, so a config with
        // duplicate ids can't queue two attaches for the same UUID.
        for targetItem in targetByID.values where trackedByID[targetItem.id] == nil {
            toAttach.append(targetItem)
        }

        // Apply detaches first so duplicate-UUID conflicts can't fire when
        // a swap reuses an id with a different attachment.
        for device in toDetach {
            do {
                try await lifecycle.detachRemovableMedia(device, from: instance, for: sessionID)
            } catch RemovableMediaDeviceError.noVirtualMachine {
                #log(
                    Self.logger, .notice,
                    "VM '\(instance.name, privacy: .public)' torn down during media detach; abandoning reconcile"
                )
                return nil
            } catch RemovableMediaDeviceError.deviceNotFound {
                // The coordinator's `forgetAttachedMedia` is skipped when the
                // framework call throws, so clear stale tracking explicitly here.
                #log(
                    Self.logger, .notice,
                    "Removable media '\(device.displayName, privacy: .public)' was already gone on '\(instance.name, privacy: .public)' (deviceNotFound); clearing tracking"
                )
                instance.forgetAttachedMedia(deviceID: device.id, for: sessionID)
            } catch {
                #log(
                    Self.logger, .error,
                    "Removable media detach failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                return RefusedPass(sessionID: sessionID, lookup: rollbackLookup, error: error)
            }
        }

        for item in toAttach {
            do {
                // The scope must stay live while the service resolves the path and
                // opens the attachment; on success it is registered with the instance
                // (released at detach or teardown), and released by deinit if it throws.
                let scope = item.bookmark.flatMap { ScopedAccess(bookmark: $0) }
                _ = try await lifecycle.attachRemovableMedia(
                    diskImagePath: item.path,
                    readOnly: item.readOnly,
                    desiredUUID: item.id,
                    resolvedURL: scope?.url,
                    to: instance,
                    for: sessionID
                )
                if let scope {
                    instance.retainMediaScope(scope, deviceID: item.id, for: sessionID)
                }
                #log(
                    Self.logger, .notice,
                    "Attached removable media '\(item.label, privacy: .public)' on '\(instance.name, privacy: .public)' (readOnly: \(item.readOnly, privacy: .public))"
                )
            } catch RemovableMediaDeviceError.noVirtualMachine {
                #log(
                    Self.logger, .notice,
                    "VM '\(instance.name, privacy: .public)' torn down during media attach; abandoning reconcile"
                )
                return nil
            } catch {
                #log(
                    Self.logger, .error,
                    "Removable media attach failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                return RefusedPass(sessionID: sessionID, lookup: rollbackLookup, error: error)
            }
        }
        return nil
    }

    /// Settles the configuration on the live list and surfaces the error —
    /// unless the session `refused` acted for has been overtaken, whose
    /// successor's live media the list would describe and whose user
    /// force-stopped the VM the error is about.
    private func failReconcile(for instance: VMInstance, _ refused: RefusedPass) {
        guard instance.liveSessionID == refused.sessionID else {
            #log(
                Self.logger, .notice,
                "Dropping removable-media reconcile failure for '\(instance.name, privacy: .public)': session \(refused.sessionID, privacy: .public) is no longer live"
            )
            return
        }
        let live = instance.liveRemovableMedia.compactMap { refused.lookup[$0.id] }
        onSettle?(instance, live.isEmpty ? nil : live)
        onFailure?(refused.error)
    }
}
