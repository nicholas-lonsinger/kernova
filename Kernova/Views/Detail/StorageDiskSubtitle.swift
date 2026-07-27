import AppKit

/// SF Symbol name for a storage disk row's leading icon.
func diskIconSystemName(for disk: StorageDisk) -> String {
    if disk.kind == .usbMassStorage {
        return "opticaldisc"
    }
    return disk.isInternal ? "cylinder.split.1x2" : "externaldrive"
}

/// Paints `text` into the subtitle field, fading it in when the content changes.
///
/// The in-bundle size figures arrive after an off-main read, so snapping them
/// into the row reads as an abrupt pop; a repaint with the *same* string skips
/// the animation so the row doesn't shimmer.
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
/// The field is tagged with the item `id` (via `identifier`) so a row recycled
/// for a different item ignores a late result, while a re-populate of the *same*
/// item updates in place. A missing external file short-circuits to the red
/// "Missing — path" state without measuring, and re-binding a field cancels its
/// prior in-flight read so reads don't accumulate under churn.
@MainActor
func populateDiskSubtitle(
    _ field: NSTextField, id: UUID, path: String, isInternal: Bool,
    bundleLayout: VMBundleLayout, isMissing: Bool, animated: Bool = true
) {
    let fieldKey = ObjectIdentifier(field)
    diskSubtitleReads.removeValue(forKey: fieldKey)?.task.cancel()

    guard !isMissing else {
        // Clearing the token also makes any in-flight read from a prior binding
        // ignore its late result.
        field.identifier = nil
        applyAttachmentSubtitle(to: field, path: path, isMissing: true)
        return
    }

    let token = NSUserInterfaceItemIdentifier(id.uuidString)
    let isNewBinding = field.identifier != token
    field.identifier = token
    if isNewBinding {
        // Seed the best value known synchronously so a recycled cell never
        // flashes a stale size: an external file shows its path; an in-bundle
        // file clears to empty, invisible for the sub-ms read that follows.
        applyAttachmentSubtitle(to: field, path: isInternal ? "" : path, isMissing: false)
    }

    diskSubtitleReadGeneration += 1
    let generation = diskSubtitleReadGeneration
    let task = Task { [weak field] in
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
