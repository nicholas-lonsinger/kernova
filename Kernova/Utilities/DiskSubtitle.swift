import Foundation

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
/// Callers paint the result via `populateDiskSubtitle(_:id:path:isInternal:bundleLayout:isMissing:)`.
///
/// Foundation-only (this file is shared with the `KernovaQuickLook` extension,
/// which uses the same phrasing for the preview's Storage row).
nonisolated func diskSubtitle(path: String, isInternal: Bool, bundleLayout: VMBundleLayout) -> String {
    // One coalesced read for both figures (rather than two separate stats).
    diskSubtitle(
        sizes: bundleLayout.diskSizes(forRelativePath: path, isInternal: isInternal),
        path: path, isInternal: isInternal)
}

/// Formats already-read sizes into the subtitle string.
///
/// The read/format split lets a caller that also needs the raw figures — the
/// Quick Look preview derives its usage bar from them — stat the file once
/// instead of twice.
nonisolated func diskSubtitle(sizes: VMBundleLayout.DiskSizes, path: String, isInternal: Bool) -> String {
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
