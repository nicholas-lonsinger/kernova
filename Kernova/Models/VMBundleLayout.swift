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
        FileManager.default.fileExists(atPath: saveFileURL.path)
    }

    /// Actual bytes consumed on disk by the sparse disk image, or `nil` if the file doesn't exist.
    var diskUsageBytes: UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: diskImageURL.path),
              let size = attrs[.size] as? UInt64 else {
            return nil
        }
        return size
    }
}
