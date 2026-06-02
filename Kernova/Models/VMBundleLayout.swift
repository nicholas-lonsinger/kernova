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

    /// Virtual capacity (bytes) of a disk image, or `nil` when it can't be read.
    ///
    /// Sparse **ASIF** images record their capacity in the header — the apparent
    /// file size tracks the *grown* footprint, not the capacity (a 100 GB disk
    /// holding 27 GB has a ~27 GB apparent size) — so it's parsed out. Any other
    /// format (a raw `.img`, an `.iso`, a `.dmg`) is *not* a sparse container, so
    /// its apparent file size **is** its virtual capacity and is read directly.
    /// Resolves bundle-relative `path`s against `bundleURL` and absolute paths
    /// as-is, serving both in-bundle and external disks. `VMBundleLayout` is
    /// `Sendable`, so callers can hop this onto a detached task.
    func diskCapacityBytes(forRelativePath path: String, isInternal: Bool) -> UInt64? {
        let url =
            isInternal ? bundleURL.appendingPathComponent(path) : URL(fileURLWithPath: path)
        switch asifCapacity(at: url) {
        case .capacity(let bytes):
            return bytes
        case .malformedASIF:
            // A recognizable-but-unparseable ASIF: do *not* guess from the
            // apparent size (it tracks the grown footprint, not capacity) —
            // report unknown so the row degrades to on-disk-only.
            return nil
        case .notASIF:
            // Raw `.img` / `.iso` / `.dmg`: apparent size *is* the capacity.
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
                return nil
            }
            return UInt64(size)
        }
    }

    /// Outcome of inspecting a file's ASIF header for its virtual capacity.
    private enum ASIFCapacity {
        /// A valid ASIF whose header yielded a sane capacity.
        case capacity(UInt64)
        /// An ASIF (magic matched) whose capacity failed the sanity bounds —
        /// likely a format change. Distinguished from ``notASIF`` so the caller
        /// knows *not* to fall back to the apparent file size, which an ASIF's
        /// sparse layout doesn't tie to capacity.
        case malformedASIF
        /// Not an ASIF (no `shdw` magic, or the file couldn't be opened) — the
        /// caller may treat the apparent file size as the capacity.
        case notASIF
    }

    /// Reads the virtual capacity recorded in an ASIF image's header.
    ///
    // RATIONALE: ASIF's on-disk layout is undocumented, but its `shdw`
    // container records the virtual size at byte offset 0x30 as a big-endian
    // `UInt64` count of 512-byte sectors (verified exact across 50/100 GB
    // disks: 97_656_250 and 195_312_500 sectors). The magic is validated and
    // the result is bounds-checked and used *only* for the allocated-capacity
    // display, so a future format change degrades to on-disk-only rather than
    // misbehaving.
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
        let bytes = sectors &* 512
        // Sanity bounds: 1 MB … 1 PB.
        guard (1_000_000...1_000_000_000_000_000).contains(bytes) else { return .malformedASIF }
        return .capacity(bytes)
    }
}
