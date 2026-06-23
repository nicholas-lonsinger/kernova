import AppKit

/// SF Symbol name for a storage disk row's leading icon.
///
/// Shared so the settings list and the reorder sheet stay in lockstep if the
/// icon mapping ever changes. The three glyphs are chosen to read distinctly at
/// list size: `cylinder.split.1x2` (the stacked-disk/volume glyph) for an
/// in-bundle disk, `externaldrive` for a linked external file, and `opticaldisc`
/// for USB mass-storage installer media (`.iso`/`.dmg`). `internaldrive` and
/// `externaldrive` were too alike at a glance, so the in-bundle case uses the
/// distinct disk-cylinder — outline, matching the other two glyphs' weight.
func diskIconSystemName(for disk: StorageDisk) -> String {
    if disk.kind == .usbMassStorage {
        return "opticaldisc"
    }
    return disk.isInternal ? "cylinder.split.1x2" : "externaldrive"
}

// The pure `diskSubtitle(…)` formatting functions live in
// `Kernova/Utilities/DiskSubtitle.swift` (Foundation-only, shared with the
// KernovaQuickLook extension); this file keeps the AppKit painters.

/// Paints `text` into the subtitle field, fading it in when the content changes.
///
/// The in-bundle size figures arrive after an off-main read, so snapping them
/// into the row reads as an abrupt pop; a quick alpha fade softens it. A repaint
/// with the *same* string — the common case when a steady-state refresh re-reads
/// an unchanged size — skips the animation so the row doesn't shimmer. When
/// `animated` is `false` the value is painted directly with no fade — used by the
/// Boot Order sheet, whose drag-drop `reloadData()` rebinds cells and would
/// otherwise re-fade every crossed row on each reorder.
@MainActor
private func setDiskSubtitle(_ field: NSTextField, text: String, animated: Bool) {
    guard field.stringValue != text else { return }
    guard animated else {
        field.alphaValue = 1
        applyAttachmentSubtitle(to: field, path: text, isMissing: false)
        return
    }
    field.alphaValue = 0
    applyAttachmentSubtitle(to: field, path: text, isMissing: false)
    animateFade(field, to: 1)
}

/// In-flight subtitle reads keyed by the painted field.
///
/// Re-binding a field (a settings-list refresh, a recycled Boot Order cell)
/// cancels its prior read + deferred placeholder instead of letting them
/// accumulate. The `generation` tags each read so a finishing task only clears
/// its *own* entry, never one a newer bind installed.
@MainActor
private var diskSubtitleReads: [ObjectIdentifier: (generation: Int, task: Task<Void, Never>)] = [:]

@MainActor
private var diskSubtitleReadGeneration = 0

/// Fills `field` with the subtitle for a `StorageDisk`.
///
/// The `StorageDisk` convenience overload of
/// ``populateDiskSubtitle(_:id:path:isInternal:bundleLayout:isMissing:animated:)``.
@MainActor
func populateDiskSubtitle(
    _ field: NSTextField, for disk: StorageDisk, bundleLayout: VMBundleLayout, isMissing: Bool,
    animated: Bool = true
) {
    populateDiskSubtitle(
        field, id: disk.id, path: disk.path, isInternal: disk.isInternal,
        bundleLayout: bundleLayout, isMissing: isMissing, animated: animated)
}

/// Fills `field` with the subtitle for a `RemovableMediaItem` (always external).
///
/// The `RemovableMediaItem` convenience overload of
/// ``populateDiskSubtitle(_:id:path:isInternal:bundleLayout:isMissing:animated:)``,
/// so removable call sites don't hand-spell `isInternal: false`.
@MainActor
func populateDiskSubtitle(
    _ field: NSTextField, for item: RemovableMediaItem, bundleLayout: VMBundleLayout,
    isMissing: Bool, animated: Bool = true
) {
    populateDiskSubtitle(
        field, id: item.id, path: item.path, isInternal: false,
        bundleLayout: bundleLayout, isMissing: isMissing, animated: animated)
}

/// Fills `field` with an attachment's subtitle, reading its sizes **off the main
/// thread**.
///
/// Every attachment — storage disk or removable medium, in-bundle or external —
/// needs a file read for its on-disk/allocated figures, so this reads on a
/// detached task and paints the result when it lands. The field is tagged with
/// the item `id` (via `identifier`) so a row reused for a different item — the
/// Boot Order table recycles cells — ignores a late result, and so a re-populate
/// of the *same* item (a settings-list refresh) updates in place.
///
/// A **missing** external file short-circuits to the red "Missing — path"
/// state: there's nothing to measure, and the broken path is the useful thing
/// to show.
///
/// The holding value while the read is pending depends on the file: an external
/// file seeds its **path** (instantly known, and also the graceful fallback if
/// the volume is slow or unreadable), so it never flickers; an in-bundle file
/// clears to empty, invisible for the sub-millisecond local read that follows.
/// An in-bundle read is always local and tiny — a stat plus a 56-byte header —
/// so it needs no slow-path placeholder; if it ever can't be read it lands on the
/// synchronous "In-bundle disk image" fallback in
/// ``diskSubtitle(path:isInternal:bundleLayout:)``. The robust off-main read is
/// retained for *external* files, whose backing volume may be slow or asleep.
///
/// The async value eases in via ``setDiskSubtitle(_:text:animated:)`` so it
/// doesn't pop (unless `animated` is `false`); a no-op repaint with an unchanged
/// size doesn't animate. Re-binding a field cancels its prior in-flight read so
/// reads don't accumulate under churn.
@MainActor
func populateDiskSubtitle(
    _ field: NSTextField, id: UUID, path: String, isInternal: Bool,
    bundleLayout: VMBundleLayout, isMissing: Bool, animated: Bool = true
) {
    // Cancel any read still in flight for this field before re-binding it.
    let fieldKey = ObjectIdentifier(field)
    diskSubtitleReads.removeValue(forKey: fieldKey)?.task.cancel()

    guard !isMissing else {
        // A vanished external file has nothing to measure — show the red
        // "Missing — path" state and stop. Clearing the token also makes any
        // in-flight read from a prior binding ignore its late result.
        field.identifier = nil
        applyAttachmentSubtitle(to: field, path: path, isMissing: true)
        return
    }

    let token = NSUserInterfaceItemIdentifier(id.uuidString)
    let isNewBinding = field.identifier != token
    field.identifier = token
    if isNewBinding {
        // Seed the best value known synchronously so a recycled cell never
        // flashes a stale size: an external file shows its path (also the
        // fallback if the volume is slow/unreadable); an in-bundle file clears
        // to empty, invisible for the sub-ms read that follows.
        applyAttachmentSubtitle(to: field, path: isInternal ? "" : path, isMissing: false)
    }

    diskSubtitleReadGeneration += 1
    let generation = diskSubtitleReadGeneration
    let task = Task { [weak field] in
        // The read is off-main for *both* kinds, but the latency it guards is an
        // external file's slow/asleep volume — an in-bundle file is local and
        // tiny, so the seeded-empty state is invisible until the value lands.
        let text = await Task.detached {
            diskSubtitle(path: path, isInternal: isInternal, bundleLayout: bundleLayout)
        }.value
        // Clear our own entry only — a newer bind may have replaced it.
        if diskSubtitleReads[fieldKey]?.generation == generation {
            diskSubtitleReads.removeValue(forKey: fieldKey)
        }
        guard !Task.isCancelled, let field, field.identifier == token else { return }
        setDiskSubtitle(field, text: text, animated: animated)
    }
    diskSubtitleReads[fieldKey] = (generation, task)
}
