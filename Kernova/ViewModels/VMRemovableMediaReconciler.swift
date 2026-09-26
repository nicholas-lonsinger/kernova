import Foundation
import KernovaLogging

/// Drives a running VM's XHCI removable-media list to whatever its
/// configuration asks for, inside the operation that holds the VM — a
/// `.reconcilingMedia` it launches for an edit, or the operation whose own
/// write changed the list — and settles the configuration on the live list
/// when VZ refuses.
///
/// Headless: the configuration write and the alert both leave through hooks,
/// so every configuration write stays ``VMLibrary``'s.
@MainActor
final class VMRemovableMediaReconciler {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMRemovableMediaReconciler")

    private let lifecycle: VMLifecycleCoordinator

    /// Points the configuration's removable-media list at the one a refused
    /// reconcile left live, as a write of the operation the reconcile runs in
    /// — ``VMLibrary/settleRemovableMedia(_:toLive:)``.
    var onSettle: ((borrowing VMEditPermit, [RemovableMediaItem]?) -> Void)?

    /// Receives every failure the reconcile needs a user to see.
    var onFailure: ((any Error) -> Void)?

    init(lifecycle: VMLifecycleCoordinator) {
        self.lifecycle = lifecycle
    }

    /// Starts the reconcile a committed `removableMedia` change asks of a
    /// settled live VM, in the same step as the commit.
    ///
    /// No-ops when the list is unchanged, when the VM has no session to attach
    /// to — a VM at rest picks the list up at its next start — and when a
    /// reconcile already holds the VM, which drives it to this list before it
    /// ends.
    func apply(for instance: VMInstance, old: VMConfiguration, new: VMConfiguration) {
        guard VMConfiguration.removableMediaChanged(old: old, new: new),
            instance.phase.isSettledLive
        else { return }
        do {
            try instance.activity.launch(.reconcilingMedia) { [weak self] context in
                await self?.reconcile(context)
                return .rest(.asStarted, ())
            }
        } catch {
            #log(
                Self.logger, .fault,
                "A removable-media reconcile of '\(instance.name, privacy: .public)' was refused on a settled live VM: \(error.localizedDescription, privacy: .public)"
            )
            assertionFailure("A settled live VM refused its removable-media reconcile")
        }
    }

    /// Drives the live list of the session `context`'s operation holds to the
    /// configuration of the VM it holds until the two match, then answers a
    /// refused pass; does nothing once that operation holds no live session.
    ///
    /// Edits committed while a pass runs are admitted by the operation and
    /// picked up by the next iteration, so rapid edits converge to the final
    /// user-selected state. A refused pass is answered only once the loop ends,
    /// and only when it was the last pass: an edit that landed behind it is
    /// what the configuration holds and what the next pass drove the VM to, so
    /// settling the configuration on the live list before then would overwrite
    /// that edit with a list the VM was about to leave.
    func reconcile(_ context: borrowing VMOperationContext) async {
        let instance = context.instance
        var applied: [RemovableMediaItem]?
        var refused: RefusedPass?
        while let sessionID = context.sessionID {
            let target = instance.configuration.removableMedia ?? []
            guard target != applied else { break }
            applied = target
            refused = await applyLiveRemovableMediaChange(
                for: instance, target: target, actingFor: sessionID)
        }
        if let refused {
            failReconcile(refused, context.permit)
        }
    }

    /// A pass VZ refused some of.
    private struct RefusedPass {
        /// The session the pass acted for.
        let sessionID: UUID
        /// Each entry the settled list can name, by id — see
        /// ``applyLiveRemovableMediaChange(for:target:actingFor:)``.
        let lookup: [UUID: RemovableMediaItem]
        let failure: RemovableMediaReconcileFailure
    }

    /// Reconciles the live removable media list with `target`, diffing per id against
    /// `instance.liveRemovableMedia`.
    ///
    /// Detaches run before attaches, so swapping the medium in a slot cannot collide
    /// with itself on a duplicate UUID — and a slot whose detach failed is not
    /// attached again, since its medium is still there.
    ///
    /// Every other item is attempted whatever happened to the ones before it.
    /// Any unexpected error is answered in a ``RefusedPass``, from which the
    /// configuration is settled on `instance.liveRemovableMedia` — so the UI
    /// snaps to what is actually attached rather than describing a state VZ
    /// refused. `deviceNotFound` (which also covers a guest-side eject) and
    /// `noVirtualMachine` are handled as confirmed-gone / silent bail.
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

        var failures: [RemovableMediaReconcileFailure.Item] = []
        // Apply detaches first so duplicate-UUID conflicts can't fire when
        // a swap reuses an id with a different attachment.
        var stillAttachedIDs: Set<UUID> = []
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
                failures.append(.init(name: device.displayName, operation: .eject, error: error))
                stillAttachedIDs.insert(device.id)
            }
        }

        for item in toAttach where !stillAttachedIDs.contains(item.id) {
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
                failures.append(.init(name: item.label, operation: .attach, error: error))
            }
        }
        guard !failures.isEmpty else { return nil }
        return RefusedPass(
            sessionID: sessionID, lookup: rollbackLookup,
            failure: RemovableMediaReconcileFailure(items: failures))
    }

    /// Settles the configuration on the live list, under `permit`, and
    /// surfaces the error — unless the session `refused` acted for has gone,
    /// whose user force-stopped the VM the error is about.
    private func failReconcile(_ refused: RefusedPass, _ permit: borrowing VMEditPermit) {
        let instance = permit.instance
        guard instance.liveSessionID == refused.sessionID else {
            #log(
                Self.logger, .notice,
                "Dropping removable-media reconcile failure for '\(instance.name, privacy: .public)': session \(refused.sessionID, privacy: .public) is no longer live"
            )
            return
        }
        let live = instance.liveRemovableMedia.compactMap { refused.lookup[$0.id] }
        onSettle?(permit, live.isEmpty ? nil : live)
        onFailure?(refused.failure)
    }
}

/// Every item a reconcile pass could not attach or eject, each named with what
/// went wrong.
struct RemovableMediaReconcileFailure: LocalizedError {
    struct Item {
        enum Operation { case attach, eject }

        let name: String
        let operation: Operation
        let error: any Error
    }

    let items: [Item]

    var errorDescription: String? {
        items.map { item in
            let verb = item.operation == .attach ? "attach" : "eject"
            return "Couldn\u{2019}t \(verb) \u{201C}\(item.name)\u{201D}. \(item.error.localizedDescription)"
        }.joined(separator: "\n")
    }
}
