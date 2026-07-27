import Foundation

/// Human-readable subtitle for a storage-disk row.
nonisolated func diskSubtitle(for disk: StorageDisk, bundleLayout: VMBundleLayout) -> String {
    diskSubtitle(path: disk.path, isInternal: disk.isInternal, bundleLayout: bundleLayout)
}

/// Human-readable subtitle for any attachment row — a storage disk or a
/// removable medium — backed by a file at `path`.
///
/// Both figures are read **live** from the file, so they reflect an external
/// resize rather than a stored snapshot; when neither is readable (an ejected
/// external volume), the fallback is the in-bundle placeholder or the path.
/// `nonisolated`, taking the `Sendable` `VMBundleLayout` rather than the
/// instance, so the file reads can run off the main thread.
nonisolated func diskSubtitle(path: String, isInternal: Bool, bundleLayout: VMBundleLayout) -> String {
    // One coalesced read for both figures (rather than two separate stats).
    diskSubtitle(
        sizes: bundleLayout.diskSizes(forRelativePath: path, isInternal: isInternal),
        path: path, isInternal: isInternal)
}

/// Formats already-read sizes into the subtitle string.
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
