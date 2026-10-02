import Foundation

/// Human-readable subtitle for any attachment row — a storage disk or a
/// removable medium — backed by `image`.
///
/// Both figures are read **live** from the file, so they reflect an external
/// resize rather than a stored snapshot; when neither is readable (an ejected
/// external volume), the fallback is the in-bundle placeholder or the path.
/// `nonisolated`, taking the `Sendable` `VMBundleLayout` rather than the
/// instance, so the file reads can run off the main thread.
nonisolated func diskSubtitle(of image: DiskImageReference, bundleLayout: VMBundleLayout) -> String {
    diskSubtitle(
        sizes: bundleLayout.diskSizes(of: image), path: image.path, isInternal: image.isInternal)
}

/// Formats already-read sizes into the subtitle string.
nonisolated func diskSubtitle(sizes: VMBundleLayout.DiskSizes, path: String, isInternal: Bool) -> String {
    let usedText = sizes.onDiskBytes.map { DataFormatters.formatBytes($0) }
    let allocatedText = sizes.capacityBytes.map { DataFormatters.formatBytes($0) }

    switch (usedText, allocatedText) {
    case let (.some(used), .some(allocated)):
        return "\(used) (used) / \(allocated) (allocated)"
    case let (.some(used), .none):
        return "\(used) used"
    case let (.none, .some(allocated)):
        return "\(allocated) allocated"
    case (.none, .none):
        return isInternal ? "In-bundle disk image" : path
    }
}
