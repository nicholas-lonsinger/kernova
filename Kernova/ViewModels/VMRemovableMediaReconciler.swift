import Foundation
import os

/// Drives a running VM's XHCI removable-media list to whatever its
/// configuration asks for, coalescing rapid edits into one pass per instance
/// and rolling the configuration back when VZ refuses.
///
/// Headless: the configuration write and the alert both leave through hooks, so
/// the persistence funnel stays ``VMLibrary``'s alone.
@MainActor
final class VMRemovableMediaReconciler {
    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "VMRemovableMediaReconciler")

    private let lifecycle: VMLifecycleCoordinator

    /// Persists a rolled-back `instance.configuration` through the library's
    /// save funnel.
    var onSaveConfiguration: ((VMInstance) -> Void)?

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

    /// Queues the runtime XHCI list-diff a `removableMedia` change asks for.
    ///
    /// No-ops when the list is unchanged, or when the VM has no session to
    /// attach to.
    func apply(for instance: VMInstance, old: VMConfiguration, new: VMConfiguration) {
        let mediaChanged = VMConfiguration.removableMediaChanged(old: old, new: new)
        // Only dispatch when there is a session to attach to — every other VM,
        // a cold-paused one included, persists the new media list and picks it
        // up on next start.
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
    /// once the queue is empty; a session torn down mid-pass dropped its own
    /// flag with its context.
    private func runRemovableMediaReconciliation(for instance: VMInstance, id: UUID) async {
        defer {
            reconcilingRemovableMediaInstances.remove(id)
            if let live = instance.attachableSessionID {
                instance.clearRemovableMediaReconcileOwed(for: live)
            }
        }
        while let pending = pendingRemovableMediaTarget[id] {
            pendingRemovableMediaTarget.removeValue(forKey: id)
            guard let sessionID = instance.attachableSessionID, pending.sessionID == sessionID else {
                Self.logger.notice(
                    "Dropping queued removable-media target for '\(instance.name, privacy: .public)': session \(pending.sessionID, privacy: .public) is no longer live"
                )
                continue
            }
            await applyLiveRemovableMediaChange(
                for: instance, target: pending.target, actingFor: sessionID)
        }
    }

    /// Reconciles the live removable media list with `target`, diffing per id against
    /// `instance.liveRemovableMedia`.
    ///
    /// Detaches run before attaches, so swapping the medium in a slot cannot collide
    /// with itself on a duplicate UUID.
    ///
    /// On unexpected detach or attach errors the persisted config is rolled back to
    /// match `instance.liveRemovableMedia`, so the UI snaps to what is actually
    /// attached rather than describing a state VZ refused. `deviceNotFound` (which
    /// also covers a guest-side eject) and `noVirtualMachine` are handled as
    /// confirmed-gone / silent bail.
    ///
    /// Every framework call, bookkeeping write and failure handler here acts for
    /// `sessionID` and drops once that session is no longer live.
    private func applyLiveRemovableMediaChange(
        for instance: VMInstance,
        target: [RemovableMediaItem],
        actingFor sessionID: UUID
    ) async {
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

        var toDetach: [USBDeviceInfo] = []
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
                try await lifecycle.detachUSBDevice(device, from: instance, for: sessionID)
            } catch USBDeviceError.noVirtualMachine {
                Self.logger.notice(
                    "VM '\(instance.name, privacy: .public)' torn down during media detach; abandoning reconcile"
                )
                return
            } catch USBDeviceError.deviceNotFound {
                // The coordinator's `forgetAttachedMedia` is skipped when the
                // framework call throws, so clear stale tracking explicitly here.
                Self.logger.notice(
                    "Removable media '\(device.displayName, privacy: .public)' was already gone on '\(instance.name, privacy: .public)' (deviceNotFound); clearing tracking"
                )
                instance.forgetAttachedMedia(deviceID: device.id, for: sessionID)
            } catch {
                Self.logger.error(
                    "Removable media detach failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                failReconcile(for: instance, actingFor: sessionID, lookup: rollbackLookup, error: error)
                return
            }
        }

        for item in toAttach {
            do {
                // The scope must stay live while the service resolves the path and
                // opens the attachment; on success it is registered with the instance
                // (released at detach or teardown), and released by deinit if it throws.
                let scope = item.bookmark.flatMap { ScopedAccess(bookmark: $0) }
                _ = try await lifecycle.attachUSBDevice(
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
                Self.logger.notice(
                    "Attached removable media '\(item.label, privacy: .public)' on '\(instance.name, privacy: .public)' (readOnly: \(item.readOnly, privacy: .public))"
                )
            } catch USBDeviceError.noVirtualMachine {
                Self.logger.notice(
                    "VM '\(instance.name, privacy: .public)' torn down during media attach; abandoning reconcile"
                )
                return
            } catch {
                Self.logger.error(
                    "Removable media attach failed for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
                failReconcile(for: instance, actingFor: sessionID, lookup: rollbackLookup, error: error)
                return
            }
        }
    }

    /// Rolls the config back to the live state and surfaces `error` — unless the
    /// pass acting for `sessionID` has been overtaken, whose successor's live
    /// media the rollback would describe and whose user force-stopped the VM the
    /// error is about.
    private func failReconcile(
        for instance: VMInstance,
        actingFor sessionID: UUID,
        lookup: [UUID: RemovableMediaItem],
        error: any Error
    ) {
        guard instance.liveSessionID == sessionID else {
            Self.logger.notice(
                "Dropping removable-media reconcile failure for '\(instance.name, privacy: .public)': session \(sessionID, privacy: .public) is no longer live"
            )
            return
        }
        reconcileConfigToLiveState(for: instance, lookup: lookup)
        onFailure?(error)
    }

    /// Rolls `instance.configuration.removableMedia` back to whatever is
    /// actually attached in `liveRemovableMedia`.
    ///
    /// The write bypasses `updateConfiguration` to avoid re-entering the reconcile
    /// pipeline — the rolled-back state is the destination, not a retry.
    private func reconcileConfigToLiveState(
        for instance: VMInstance,
        lookup: [UUID: RemovableMediaItem]
    ) {
        let rolled = instance.liveRemovableMedia.compactMap { lookup[$0.id] }
        var newConfig = instance.configuration
        newConfig.removableMedia = rolled.isEmpty ? nil : rolled
        guard newConfig != instance.configuration else { return }
        instance.configuration = newConfig
        onSaveConfiguration?(instance)
        Self.logger.notice(
            "Rolled removable media config for '\(instance.name, privacy: .public)' back to live state after reconcile error"
        )
    }
}
