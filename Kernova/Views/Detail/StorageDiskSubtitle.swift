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
/// In-bundle disks show their real on-disk footprint and (when readable)
/// virtual capacity, e.g. `"2.1 GB (on disk) / 100 GB (allocated)"`; external
/// disks show their absolute file path. Both figures are read **live** from the
/// file — a stat + 56-byte header read — so they reflect the disk's actual
/// current state (including an external resize) rather than a stored snapshot.
/// Every in-bundle disk, the main disk included, is measured exactly the same
/// way.
///
/// `nonisolated` and takes the `Sendable` `VMBundleLayout` (not the instance) so
/// it can run on a detached task — the file reads happen off the main thread.
/// Callers paint the result via ``populateDiskSubtitle(_:for:bundleLayout:isMissing:)``.
nonisolated func diskSubtitle(for disk: StorageDisk, bundleLayout: VMBundleLayout) -> String {
    guard disk.isInternal else { return disk.path }

    let onDiskText = bundleLayout.diskOnDiskBytes(forRelativePath: disk.path, isInternal: true)
        .map { DataFormatters.formatBytes($0) }
    let allocatedText = bundleLayout.asifCapacityBytes(forRelativePath: disk.path, isInternal: true)
        .map { DataFormatters.formatBytes($0) }

    switch (onDiskText, allocatedText) {
    case let (.some(onDisk), .some(allocated)):
        return "\(onDisk) (on disk) / \(allocated) (allocated)"
    case let (.some(onDisk), .none):
        return "\(onDisk) on disk"
    case let (.none, .some(allocated)):
        return "\(allocated) allocated"
    case (.none, .none):
        return "In-bundle disk image"
    }
}

/// Grace period before a still-pending in-bundle size read shows its placeholder.
///
/// The common read is sub-millisecond, so the placeholder is deferred past this
/// window to avoid flickering it on the fast path; it only appears if a read is
/// genuinely slow.
private let diskSubtitlePlaceholderGrace: Duration = .milliseconds(100)

/// Fills `field` with a disk's subtitle, reading in-bundle sizes **off the main
/// thread**.
///
/// External disks resolve synchronously to their path. In-bundle disks need a
/// file read for their on-disk/allocated figures, so this reads on a detached
/// task and paints the result when it lands. The field is tagged with the disk
/// id (via `identifier`) so a row reused for a different disk — the Boot Order
/// table recycles cells — ignores a late result, and so a re-populate of the
/// *same* disk (a settings-list refresh) updates in place.
///
/// The "In-bundle disk image" placeholder is **deferred**: when the field is
/// bound to a new disk it's first cleared (invisible for the sub-ms read, and it
/// stops a recycled cell showing the previous disk's size), and the placeholder
/// is shown only if the read is still pending after
/// ``diskSubtitlePlaceholderGrace`` — so the fast path never flickers it.
@MainActor
func populateDiskSubtitle(
    _ field: NSTextField, for disk: StorageDisk, bundleLayout: VMBundleLayout, isMissing: Bool
) {
    guard disk.isInternal else {
        field.identifier = nil
        applyAttachmentSubtitle(to: field, path: disk.path, isMissing: isMissing)
        return
    }

    let token = NSUserInterfaceItemIdentifier(disk.id.uuidString)
    let isNewBinding = field.identifier != token
    field.identifier = token
    if isNewBinding {
        // Clear any prior disk's value so a recycled cell can't show the wrong
        // size; an empty subtitle is invisible for the read that follows.
        applyAttachmentSubtitle(to: field, path: "", isMissing: false)
    }

    Task { [weak field] in
        let read = Task.detached { diskSubtitle(for: disk, bundleLayout: bundleLayout) }
        // Defer the placeholder behind a grace period, cancelled the instant the
        // read lands — only a genuinely slow read ever surfaces it.
        let placeholder: Task<Void, Never>? =
            isNewBinding
            ? Task { [weak field] in
                do {
                    try await Task.sleep(for: diskSubtitlePlaceholderGrace)
                } catch {
                    return  // cancelled: the read finished within the grace window
                }
                guard let field, field.identifier == token, field.stringValue.isEmpty else {
                    return
                }
                applyAttachmentSubtitle(to: field, path: "In-bundle disk image", isMissing: false)
            }
            : nil

        let text = await read.value
        placeholder?.cancel()
        guard let field, field.identifier == token else { return }
        applyAttachmentSubtitle(to: field, path: text, isMissing: false)
    }
}
