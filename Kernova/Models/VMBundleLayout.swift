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

    var additionalDisksDirectoryURL: URL {
        bundleURL.appendingPathComponent("AdditionalDisks")
    }

    /// Returns the URL for an in-bundle additional disk image.
    func additionalDiskURL(id: UUID) -> URL {
        additionalDisksDirectoryURL.appendingPathComponent("\(id.uuidString).asif")
    }

    var hasSaveFile: Bool {
        FileManager.default.fileExists(atPath: saveFileURL.path(percentEncoded: false))
    }

    /// Actual bytes consumed on disk by a disk image, or `nil` if the file
    /// doesn't resolve.
    ///
    /// Resolves bundle-relative `path`s against `bundleURL` and absolute paths
    /// as-is, so it serves both in-bundle and external disks. Uses
    /// `totalFileAllocatedSizeKey` (`st_blocks * 512`) rather than logical file
    /// size, so sparse ASIF images report their true on-disk footprint.
    /// `VMBundleLayout` is `Sendable`, so callers can hop this onto a detached
    /// task to keep the stat off the main thread.
    func diskOnDiskBytes(forRelativePath path: String, isInternal: Bool) -> UInt64? {
        let url =
            isInternal ? bundleURL.appendingPathComponent(path) : URL(fileURLWithPath: path)
        guard
            let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize
        else {
            return nil
        }
        return UInt64(size)
    }

    /// Virtual capacity (bytes) of an ASIF disk image, read from its header, or
    /// `nil` when the file isn't a recognizable ASIF.
    ///
    // RATIONALE: ASIF's on-disk layout is undocumented, but its `shdw`
    // container records the virtual size at byte offset 0x30 as a big-endian
    // `UInt64` count of 512-byte sectors (verified exact across 50/100 GB
    // disks: 97_656_250 and 195_312_500 sectors). The magic is validated and
    // the result is bounds-checked and used *only* for the allocated-capacity
    // display, so a future format change degrades to on-disk-only rather than
    // misbehaving.
    func asifCapacityBytes(forRelativePath path: String, isInternal: Bool) -> UInt64? {
        let url =
            isInternal ? bundleURL.appendingPathComponent(path) : URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard
            let header = try? handle.read(upToCount: 0x38), header.count >= 0x38,
            header.prefix(4) == Data("shdw".utf8)
        else {
            return nil
        }
        let sectors = header[0x30..<0x38].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let bytes = sectors &* 512
        // Sanity bounds: 1 MB … 1 PB.
        guard (1_000_000...1_000_000_000_000_000).contains(bytes) else { return nil }
        return bytes
    }
}
