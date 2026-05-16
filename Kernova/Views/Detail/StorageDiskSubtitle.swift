import Foundation

/// Human-readable subtitle for a storage disk row.
///
/// Returns disk usage stats for the in-bundle main disk, "In-bundle disk image"
/// for other internal disks, and the absolute file path for external disks.
/// Shared by `VMSettingsView` and `StorageDiskReorderSheet` so both surfaces
/// render identical row subtitles.
@MainActor
func diskSubtitle(for disk: StorageDisk, in instance: VMInstance) -> String {
    if disk.isInternal && disk.path == instance.bundleLayout.diskImageURL.lastPathComponent {
        if let usage = instance.cachedDiskUsageBytes {
            return
                "\(DataFormatters.formatBytes(usage)) (on disk) / \(DataFormatters.formatDiskSize(instance.configuration.diskSizeInGB)) (allocated)"
        }
        return "\(DataFormatters.formatDiskSize(instance.configuration.diskSizeInGB)) allocated"
    }
    if disk.isInternal {
        return "In-bundle disk image"
    }
    return disk.path
}
