import Foundation

/// Centralizes all file path constants within a VM bundle directory.
///
/// VM bundles are directories under `~/Library/Application Support/Kernova/VMs/`
/// holding a `config.json` plus these data files.
struct VMBundleLayout: Sendable {
    let bundleURL: URL

    /// The serialized `VMConfiguration` (read via `VMConfiguration.load(fromBundle:)`).
    var configURL: URL {
        bundleURL.appendingPathComponent("config.json")
    }

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

    /// The rotated previous generation of `serialLogURL` (see `SerialLogWriter`).
    var serialLogRotatedURL: URL {
        bundleURL.appendingPathComponent("serial.log.1")
    }

    var additionalDisksDirectoryURL: URL {
        bundleURL.appendingPathComponent("AdditionalDisks")
    }

    func additionalDiskURL(id: UUID) -> URL {
        additionalDisksDirectoryURL.appendingPathComponent("\(id.uuidString).asif")
    }

    var hasSaveFile: Bool {
        FileManager.default.fileExists(atPath: saveFileURL.path(percentEncoded: false))
    }

    /// Absolute URL backing a disk: bundle-relative `path`s resolve against
    /// `bundleURL`, absolute paths are used as-is.
    func diskURL(forRelativePath path: String, isInternal: Bool) -> URL {
        isInternal ? bundleURL.appendingPathComponent(path) : URL(fileURLWithPath: path)
    }

    /// On-disk footprint and virtual capacity of a disk image.
    struct DiskSizes: Sendable {
        /// Actual bytes consumed on disk (`st_blocks * 512`), or `nil` if the
        /// file doesn't resolve.
        var onDiskBytes: UInt64?
        /// Virtual capacity in bytes, or `nil` when it can't be read.
        var capacityBytes: UInt64?
    }

    /// Reads a disk image's on-disk footprint and virtual capacity in one pass.
    ///
    /// One `resourceValues` yields `totalFileAllocatedSizeKey` (the true sparse
    /// footprint, not the grown apparent size) and `fileSizeKey` (the apparent
    /// size, which *is* the capacity for a non-sparse format). Sparse **ASIF**
    /// images instead record their capacity in the header — a 100 GB disk
    /// holding 27 GB has a ~27 GB apparent size — so it is parsed out.
    func diskSizes(forRelativePath path: String, isInternal: Bool) -> DiskSizes {
        let url = diskURL(forRelativePath: path, isInternal: isInternal)
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        let onDisk = values?.totalFileAllocatedSize.map(UInt64.init)
        let capacity: UInt64?
        switch asifCapacity(at: url) {
        case .capacity(let bytes):
            capacity = bytes
        case .malformedASIF:
            // Do *not* guess from the apparent size: for an ASIF it tracks the
            // grown footprint, not capacity.
            capacity = nil
        case .notASIF:
            // Raw `.img` / `.iso` / `.dmg`: apparent size *is* the capacity.
            capacity = values?.fileSize.map(UInt64.init)
        }
        return DiskSizes(onDiskBytes: onDisk, capacityBytes: capacity)
    }

    /// Outcome of inspecting a file's ASIF header for its virtual capacity.
    private enum ASIFCapacity {
        case capacity(UInt64)
        /// Magic matched but the capacity failed the sanity bounds.
        case malformedASIF
        /// No `shdw` magic, or the file couldn't be opened.
        case notASIF
    }

    /// Reads the virtual capacity recorded in an ASIF image's header.
    ///
    // RATIONALE: ASIF's on-disk layout is undocumented, but its `shdw`
    // container records the virtual size at byte offset 0x30 as a big-endian
    // `UInt64` count of 512-byte sectors (verified exact across 50/100 GB
    // disks: 97_656_250 and 195_312_500 sectors). The
    // magic is validated and the result bounds-checked, so a future format
    // change degrades to on-disk-only rather than misbehaving.
    private func asifCapacity(at url: URL) -> ASIFCapacity {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .notASIF }
        defer { try? handle.close() }
        guard
            let header = try? handle.read(upToCount: 0x38), header.count >= 0x38,
            header.prefix(4) == Data("shdw".utf8)
        else {
            return .notASIF
        }
        let sectors = header[0x30..<0x38].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        // Checked multiply: a hostile header could otherwise wrap a huge sector
        // count back into the sanity window and report a fabricated capacity.
        let (bytes, overflowed) = sectors.multipliedReportingOverflow(by: 512)
        // Sanity bounds: 1 MB … 1 PB.
        guard !overflowed, (1_000_000...1_000_000_000_000_000).contains(bytes) else {
            return .malformedASIF
        }
        return .capacity(bytes)
    }
}
