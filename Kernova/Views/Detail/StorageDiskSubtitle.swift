import AppKit

/// SF Symbol name for a storage disk row's leading icon.
///
/// Shared so the settings list and the reorder sheet stay in lockstep
/// if the icon mapping ever changes.
func diskIconSystemName(for disk: StorageDisk) -> String {
    if disk.kind == .usbMassStorage {
        return "opticaldisc"
    }
    return disk.isInternal ? "internaldrive" : "externaldrive"
}

/// Human-readable subtitle for a storage disk row.
///
/// Every disk — in-bundle or external, ASIF or a raw `.img`/`.iso`/`.dmg` —
/// shows its real on-disk footprint and (when readable) virtual capacity, e.g.
/// `"2.1 GB (on disk) / 100 GB (allocated)"`. Both figures are read **live**
/// from the file — a stat plus, for ASIF, a 56-byte header read — so they
/// reflect the disk's actual current state (including an external resize)
/// rather than a stored snapshot. When neither figure is readable (an ejected
/// or vanished external volume), it falls back to the disk's identity: the
/// in-bundle placeholder, or the external file's path.
///
/// `nonisolated` and takes the `Sendable` `VMBundleLayout` (not the instance) so
/// it can run on a detached task — the file reads happen off the main thread.
/// Callers paint the result via ``populateDiskSubtitle(_:for:bundleLayout:isMissing:)``.
nonisolated func diskSubtitle(for disk: StorageDisk, bundleLayout: VMBundleLayout) -> String {
    let onDiskText = bundleLayout.diskOnDiskBytes(
        forRelativePath: disk.path, isInternal: disk.isInternal
    )
    .map { DataFormatters.formatBytes($0) }
    let allocatedText = bundleLayout.diskCapacityBytes(
        forRelativePath: disk.path, isInternal: disk.isInternal
    )
    .map { DataFormatters.formatBytes($0) }

    switch (onDiskText, allocatedText) {
    case let (.some(onDisk), .some(allocated)):
        return "\(onDisk) (on disk) / \(allocated) (allocated)"
    case let (.some(onDisk), .none):
        return "\(onDisk) on disk"
    case let (.none, .some(allocated)):
        return "\(allocated) allocated"
    case (.none, .none):
        return disk.isInternal ? "In-bundle disk image" : disk.path
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
/// an unchanged size — skips the animation so the row doesn't shimmer.
@MainActor
private func fadeInDiskSubtitle(_ field: NSTextField, text: String) {
    guard field.stringValue != text else { return }
    field.alphaValue = 0
    applyAttachmentSubtitle(to: field, path: text, isMissing: false)
    NSAnimationContext.runAnimationGroup { context in
        context.duration = diskSubtitleFadeDuration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        field.animator().alphaValue = 1
    }
}

/// Fills `field` with a disk's subtitle, reading its sizes **off the main
/// thread**.
///
/// Every disk — in-bundle or external — needs a file read for its
/// on-disk/allocated figures, so this reads on a detached task and paints the
/// result when it lands. The field is tagged with the disk id (via
/// `identifier`) so a row reused for a different disk — the Boot Order table
/// recycles cells — ignores a late result, and so a re-populate of the *same*
/// disk (a settings-list refresh) updates in place.
///
/// A **missing** external file short-circuits to the red "Missing — path"
/// state: there's nothing to measure, and the broken path is the useful thing
/// to show.
///
/// The holding value while the read is pending depends on the disk: an external
/// disk seeds its **path** (instantly known, and also the graceful fallback if
/// the volume is slow or unreadable), so it never flickers; an in-bundle disk
/// clears to empty and, only if the read is still pending after
/// ``diskSubtitlePlaceholderGrace``, shows the deferred "In-bundle disk image"
/// placeholder — so the fast path never flickers it.
///
/// The async value (and the placeholder, if shown) eases in via
/// ``fadeInDiskSubtitle(_:text:)`` so it doesn't pop; a no-op repaint with an
/// unchanged size doesn't animate.
@MainActor
func populateDiskSubtitle(
    _ field: NSTextField, for disk: StorageDisk, bundleLayout: VMBundleLayout, isMissing: Bool
) {
    guard !isMissing else {
        // A vanished external file has nothing to measure — show the red
        // "Missing — path" state and stop. Clearing the token also makes any
        // in-flight read from a prior binding ignore its late result.
        field.identifier = nil
        applyAttachmentSubtitle(to: field, path: disk.path, isMissing: true)
        return
    }

    let token = NSUserInterfaceItemIdentifier(disk.id.uuidString)
    let isNewBinding = field.identifier != token
    field.identifier = token
    if isNewBinding {
        // Seed the best value known synchronously so a recycled cell never
        // flashes a stale size: an external disk shows its path (also the
        // fallback if the volume is slow/unreadable); an in-bundle disk clears
        // to empty, invisible for the sub-ms read that follows.
        applyAttachmentSubtitle(to: field, path: disk.isInternal ? "" : disk.path, isMissing: false)
    }

    Task { [weak field] in
        let read = Task.detached { diskSubtitle(for: disk, bundleLayout: bundleLayout) }
        // Defer the placeholder behind a grace period, cancelled the instant the
        // read lands — only a genuinely slow read ever surfaces it. External
        // disks already hold their path, so they need no placeholder.
        let placeholder: Task<Void, Never>? =
            (isNewBinding && disk.isInternal)
            ? Task { [weak field] in
                do {
                    try await Task.sleep(for: diskSubtitlePlaceholderGrace)
                } catch {
                    return  // cancelled: the read finished within the grace window
                }
                guard let field, field.identifier == token, field.stringValue.isEmpty else {
                    return
                }
                fadeInDiskSubtitle(field, text: "In-bundle disk image")
            }
            : nil

        let text = await read.value
        placeholder?.cancel()
        guard let field, field.identifier == token else { return }
        fadeInDiskSubtitle(field, text: text)
    }
}
