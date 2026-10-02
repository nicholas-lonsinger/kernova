import Foundation

/// Centralizes all file path constants within a VM bundle directory.
///
/// VM bundles are directories under `~/Library/Application Support/Kernova/VMs/`
/// holding a `config.json` plus these data files.
///
/// Every file a VM needs is under its bundle root, so the VM moves, copies and
/// imports as one Finder item. User-picked external attachments are the
/// exception, and carry security-scoped bookmarks instead.
struct VMBundleLayout: Sendable {
    let bundleURL: URL

    // MARK: - State files

    /// The four files ``VMBundle`` reads and writes, relative to the bundle root.
    static let configRelativePath = "config.json"
    static let hostStateRelativePath = "host-state.json"
    static let snapshotManifestRelativePath = "Snapshots/manifest.json"
    static let usbPairingsRelativePath = "usb-accessories.json"

    /// The directory holding one snapshot, relative to the bundle root.
    static func snapshotRelativePath(id: UUID) -> String {
        "Snapshots/\(id.uuidString)"
    }

    /// A snapshot's own `config.json`, relative to the bundle root.
    static func snapshotConfigRelativePath(id: UUID) -> String {
        "\(snapshotRelativePath(id: id))/\(configRelativePath)"
    }

    /// The serialized `VMConfiguration`.
    var configURL: URL {
        bundleURL.appendingPathComponent(Self.configRelativePath)
    }

    /// The serialized ``VMHostState``, absent until something first writes it.
    var hostStateURL: URL {
        bundleURL.appendingPathComponent(Self.hostStateRelativePath)
    }

    var diskImageURL: URL {
        bundleURL.appendingPathComponent("Disk.asif")
    }

    // MARK: - Platform files

    /// The platform files, relative to the bundle root.
    static let auxiliaryStorageRelativePath = "AuxiliaryStorage"
    static let hardwareModelRelativePath = "HardwareModel"
    static let machineIdentifierRelativePath = "MachineIdentifier"
    static let efiVariableStoreRelativePath = "EFIVariableStore"

    var auxiliaryStorageURL: URL {
        bundleURL.appendingPathComponent(Self.auxiliaryStorageRelativePath)
    }

    var hardwareModelURL: URL {
        bundleURL.appendingPathComponent(Self.hardwareModelRelativePath)
    }

    var machineIdentifierURL: URL {
        bundleURL.appendingPathComponent(Self.machineIdentifierRelativePath)
    }

    var efiVariableStoreURL: URL {
        bundleURL.appendingPathComponent(Self.efiVariableStoreRelativePath)
    }

    static let saveFileRelativePath = "SaveFile.vzvmsave"

    var saveFileURL: URL {
        bundleURL.appendingPathComponent(Self.saveFileRelativePath)
    }

    var serialLogURL: URL {
        bundleURL.appendingPathComponent("serial.log")
    }

    /// The rotated previous generation of `serialLogURL` (see `SerialLogWriter`).
    var serialLogRotatedURL: URL {
        bundleURL.appendingPathComponent("serial.log.1")
    }

    /// The USB accessories this VM takes back automatically
    /// (``USBAccessoryPairingSet``).
    var usbPairingsURL: URL {
        bundleURL.appendingPathComponent(Self.usbPairingsRelativePath)
    }

    /// The directory holding the in-bundle disks other than the main disk,
    /// relative to the bundle root.
    static let additionalDisksRelativePath = "AdditionalDisks"

    var additionalDisksDirectoryURL: URL {
        bundleURL.appendingPathComponent(Self.additionalDisksRelativePath)
    }

    /// The in-bundle disk `id` names, relative to the bundle root — the path
    /// its ``StorageDisk`` entry carries, so the entry travels with the bundle
    /// on clone or move.
    static func additionalDiskRelativePath(id: UUID) -> String {
        "\(additionalDisksRelativePath)/\(id.uuidString).asif"
    }

    func additionalDiskURL(id: UUID) -> URL {
        bundleURL.appendingPathComponent(Self.additionalDiskRelativePath(id: id))
    }

    var hasSaveFile: Bool {
        FileManager.default.fileExists(atPath: saveFileURL.path(percentEncoded: false))
    }

    // MARK: - Snapshot store

    var snapshotsDirectoryURL: URL {
        bundleURL.appendingPathComponent("Snapshots", isDirectory: true)
    }

    var snapshotManifestURL: URL {
        bundleURL.appendingPathComponent(Self.snapshotManifestRelativePath)
    }

    /// Where a revert clones the snapshot's files before swapping them into the
    /// bundle.
    ///
    /// Inside `Snapshots/` so the clones land on the bundle's own volume and
    /// APFS keeps them copy-on-write, and dot-prefixed so hidden-skipping
    /// enumerations pass over it.
    var restoreStagingURL: URL {
        snapshotsDirectoryURL.appendingPathComponent(".RestoreStaging", isDirectory: true)
    }

    /// The directory holding one snapshot's saved state and disk copies.
    func snapshotDirectoryURL(id: UUID) -> URL {
        snapshotsDirectoryURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// A layout rooted at one snapshot's directory, so the captured copies
    /// resolve through the same names as the bundle's own files.
    func snapshotLayout(id: UUID) -> VMBundleLayout {
        VMBundleLayout(bundleURL: snapshotDirectoryURL(id: id))
    }

    /// Whether the bundle's suspend slot is the copy a revert to `id` installed,
    /// rather than one the guest's own suspend wrote.
    ///
    /// A revert clones the snapshot's saved state through `copyItem`, which
    /// carries the modification date across, and `replaceItemAt` lands the clone
    /// with that date intact; a suspend writes a fresh file and stamps it with
    /// the time it was written. Size and modification date together identify the
    /// clone, at the cost of two `stat` calls and no reading of either file.
    func saveFileIsCopyOfSnapshot(id: UUID) -> Bool {
        let manager = FileManager.default
        guard
            let mine = try? manager.attributesOfItem(
                atPath: saveFileURL.path(percentEncoded: false)),
            let captured = try? manager.attributesOfItem(
                atPath: snapshotLayout(id: id).saveFileURL.path(percentEncoded: false)),
            let mySize = mine[.size] as? NSNumber,
            let capturedSize = captured[.size] as? NSNumber,
            let myDate = mine[.modificationDate] as? Date,
            let capturedDate = captured[.modificationDate] as? Date
        else { return false }
        return mySize == capturedSize && myDate == capturedDate
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

    /// Runs `body` on the disk image's URL, inside the image's bookmark scope
    /// when it has one — outside a running session nothing else holds that
    /// scope, and the sandbox denies opening an out-of-container file without
    /// it.
    ///
    /// Advisory: the readouts this feeds are never worth mounting a volume or
    /// showing system UI for.
    func withDiskImage<T>(_ image: DiskImageReference, _ body: (URL) -> T) -> T {
        SecurityScopedBookmark.withResolvedURL(
            bookmark: image.bookmark,
            fallback: diskURL(forRelativePath: image.path, isInternal: image.isInternal),
            options: SecurityScopedBookmark.advisoryResolution, body)
    }

    /// Reads a disk image's on-disk footprint and virtual capacity in one pass,
    /// inside its bookmark scope.
    func diskSizes(of image: DiskImageReference) -> DiskSizes {
        withDiskImage(image, Self.diskSizes(at:))
    }

    /// Reads the on-disk footprint and virtual capacity of the file at `url`.
    ///
    /// `totalFileAllocatedSizeKey` is the true sparse footprint, not the grown
    /// apparent size. Capacity comes from the opened file alone: a sparse
    /// **ASIF** image records it in its header — a 100 GB disk holding 27 GB has
    /// a ~27 GB apparent size — and any other format's apparent size *is* its
    /// capacity. A file that cannot be opened has no capacity reading at all.
    static func diskSizes(at url: URL) -> DiskSizes {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return DiskSizes(
            onDiskBytes: values?.totalFileAllocatedSize.map(UInt64.init),
            capacityBytes: capacity(at: url))
    }

    /// The virtual capacity of the file at `url`, or `nil` when it cannot be
    /// opened or is an ASIF whose recorded capacity fails the sanity bounds.
    // ASIF's on-disk layout is undocumented; its `shdw` container records the
    // virtual size at byte offset 0x30 as a big-endian `UInt64` count of 512-byte
    // sectors (verified exact on 50 and 100 GB disks: 97_656_250 and 195_312_500
    // sectors).
    private static func capacity(at url: URL) -> UInt64? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard
            let header = try? handle.read(upToCount: 0x38), header.count >= 0x38,
            header.prefix(4) == Data("shdw".utf8)
        else {
            // Raw `.img` / `.iso` / `.dmg`: the apparent size of the file this
            // handle opened is the capacity.
            return try? handle.seekToEnd()
        }
        let sectors = header[0x30..<0x38].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        // Checked multiply: a hostile header could otherwise wrap a huge sector
        // count back into the sanity window and report a fabricated capacity.
        let (bytes, overflowed) = sectors.multipliedReportingOverflow(by: 512)
        // Sanity bounds: 1 MB … 1 PB. Out of bounds is unknown, never the
        // apparent size, which for an ASIF tracks the grown footprint.
        guard !overflowed, (1_000_000...1_000_000_000_000_000).contains(bytes) else {
            return nil
        }
        return bytes
    }
}

/// A disk image file a VM references: where it is, and the bookmark that
/// grants access to it when it lives outside the bundle.
struct DiskImageReference: Sendable, Equatable {
    /// Bundle-relative when `isInternal`, absolute otherwise.
    var path: String
    var isInternal: Bool
    var bookmark: Data?
}

extension StorageDisk {
    var imageReference: DiskImageReference {
        DiskImageReference(path: path, isInternal: isInternal, bookmark: bookmark)
    }
}

extension RemovableMediaItem {
    var imageReference: DiskImageReference {
        DiskImageReference(path: path, isInternal: false, bookmark: bookmark)
    }
}
