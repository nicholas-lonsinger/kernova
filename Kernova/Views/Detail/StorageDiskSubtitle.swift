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

/// Human-readable subtitle for a storage-disk row.
///
/// The `StorageDisk` convenience overload of
/// ``diskSubtitle(path:isInternal:bundleLayout:)``.
nonisolated func diskSubtitle(for disk: StorageDisk, bundleLayout: VMBundleLayout) -> String {
    diskSubtitle(path: disk.path, isInternal: disk.isInternal, bundleLayout: bundleLayout)
}

/// Human-readable subtitle for any attachment row — a storage disk or a
/// removable medium — backed by a file at `path`.
///
/// Every backing file — in-bundle or external, ASIF or a raw `.img`/`.iso`/`.dmg`
/// — shows its real on-disk footprint and (when readable) virtual capacity, e.g.
/// `"2.1 GB (on disk) / 100 GB (allocated)"`. Both figures are read **live**
/// from the file — a stat plus, for ASIF, a 56-byte header read — so they
/// reflect the file's actual current state (including an external resize) rather
/// than a stored snapshot. When neither figure is readable (an ejected or
/// vanished external volume), it falls back to the file's identity: the
/// in-bundle placeholder, or the external file's path.
///
/// `nonisolated` and takes the `Sendable` `VMBundleLayout` (not the instance) so
/// it can run on a detached task — the file reads happen off the main thread.
/// Callers paint the result via ``populateDiskSubtitle(_:id:path:isInternal:bundleLayout:isMissing:)``.
nonisolated func diskSubtitle(path: String, isInternal: Bool, bundleLayout: VMBundleLayout) -> String {
    // One coalesced read for both figures (rather than two separate stats).
    let sizes = bundleLayout.diskSizes(forRelativePath: path, isInternal: isInternal)
    let onDiskText = sizes.onDiskBytes.map { DataFormatters.formatBytes($0) }
    let allocatedText = sizes.capacityBytes.map { DataFormatters.formatBytes($0) }

    switch (onDiskText, allocatedText) {
    case let (.some(onDisk), .some(allocated)):
        return "\(onDisk) (on disk) / \(allocated) (allocated)"
    case let (.some(onDisk), .none):
        return "\(onDisk) on disk"
    case let (.none, .some(allocated)):
        return "\(allocated) allocated"
    case (.none, .none):
        return isInternal ? "In-bundle disk image" : path
    }
}

/// Grace period before a still-pending in-bundle size read shows its placeholder.
///
/// The common read is sub-millisecond, so the placeholder is deferred past this
/// window to avoid flickering it on the fast path; it only appears if a read is
/// genuinely slow.
private let diskSubtitlePlaceholderGrace: Duration = .milliseconds(100)

/// Duration of the subtitle's fade-in when an async size read — or its deferred
/// placeholder — lands, easing the value in instead of snapping it.
private let diskSubtitleFadeDuration: TimeInterval = 0.2

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
    NSAnimationContext.runAnimationGroup { context in
        context.duration = diskSubtitleFadeDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        field.animator().alphaValue = 1
    }
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
/// clears to empty and, only if the read is still pending after
/// ``diskSubtitlePlaceholderGrace``, shows the deferred "In-bundle disk image"
/// placeholder — so the fast path never flickers it.
///
/// The async value (and the placeholder, if shown) eases in via
/// ``setDiskSubtitle(_:text:animated:)`` so it doesn't pop (unless `animated` is
/// `false`); a no-op repaint with an unchanged size doesn't animate. Re-binding a
/// field cancels its prior in-flight read so reads don't accumulate under churn.
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
        let read = Task.detached {
            diskSubtitle(path: path, isInternal: isInternal, bundleLayout: bundleLayout)
        }
        // Defer the placeholder behind a grace period, cancelled the instant the
        // read lands — only a genuinely slow read ever surfaces it. External
        // files already hold their path, so they need no placeholder.
        let placeholder: Task<Void, Never>? =
            (isNewBinding && isInternal)
            ? Task { [weak field] in
                do {
                    try await Task.sleep(for: diskSubtitlePlaceholderGrace)
                } catch {
                    return  // cancelled: the read finished within the grace window
                }
                guard let field, field.identifier == token, field.stringValue.isEmpty else {
                    return
                }
                setDiskSubtitle(field, text: "In-bundle disk image", animated: animated)
            }
            : nil

        let text = await read.value
        placeholder?.cancel()
        // Clear our own entry only — a newer bind may have replaced it.
        if diskSubtitleReads[fieldKey]?.generation == generation {
            diskSubtitleReads.removeValue(forKey: fieldKey)
        }
        guard !Task.isCancelled, let field, field.identifier == token else { return }
        setDiskSubtitle(field, text: text, animated: animated)
    }
    diskSubtitleReads[fieldKey] = (generation, task)
}
