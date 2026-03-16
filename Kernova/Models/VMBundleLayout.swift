import Foundation

/// Centralizes all file path constants within a VM bundle directory.
///
/// VM bundles are directories stored in `~/Library/Application Support/Kernova/VMs/`
/// that contain a `config.json` plus these data files. Using this struct eliminates
/// duplicated string literals across `VMInstance`, `ConfigurationBuilder`, and `VMLibraryViewModel`.
struct VMBundleLayout: Sendable {
    let bundleURL: URL

    var diskImageURL: URL {
        bundleURL.appendingPathComponent("Disk.asif")
    }

    var auxiliaryStorageURL: URL {
        bundleURL.appendingPathComponent("AuxiliaryStorage")
    }

    var hardwareModelURL: URL {
        bundleURL.appendingPathComponent("HardwareModel")
    }

    var machineIdentifierURL: URL {
        bundleURL.appendingPathComponent("MachineIdentifier")
    }

    var efiVariableStoreURL: URL {
        bundleURL.appendingPathComponent("EFIVariableStore")
    }

    var saveFileURL: URL {
        bundleURL.appendingPathComponent("SaveFile.vzvmsave")
    }

    var serialLogURL: URL {
        bundleURL.appendingPathComponent("serial.log")
    }

    var hasSaveFile: Bool {
        FileManager.default.fileExists(atPath: saveFileURL.path(percentEncoded: false))
    }

    /// Actual bytes consumed on disk by the sparse disk image, or `nil` if the file doesn't exist.
    ///
    /// Uses `totalFileAllocatedSizeKey` (`st_blocks * 512`) rather than logical file size,
    /// so sparse ASIF images report their true on-disk footprint instead of the virtual capacity.
    var diskUsageBytes: UInt64? {
        guard let size = (try? diskImageURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
            .totalFileAllocatedSize else {
            return nil
        }
        return UInt64(size)
    }
}
