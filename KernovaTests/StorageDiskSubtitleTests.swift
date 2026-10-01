import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("StorageDiskSubtitle Tests", .caseScoped)
@MainActor
struct StorageDiskSubtitleTests {
    private func makeInstanceWithBundle() throws -> VMInstance {
        let instance = VMInstanceFixture.make(name: "VM")
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
        return instance
    }

    /// Writes a file with `totalBytes` of content; when `capacitySectors` is
    /// set, stamps a minimal ASIF `shdw` header (magic + big-endian sector
    /// count at offset 0x30) so the live reader resolves a virtual capacity.
    private func writeDiskFile(at url: URL, totalBytes: Int, capacitySectors: UInt64?) throws {
        var data = Data(count: max(totalBytes, capacitySectors == nil ? 0 : 0x38))
        if let sectors = capacitySectors {
            data.replaceSubrange(0..<4, with: Data("shdw".utf8))
            var sectorsBE = sectors.bigEndian
            withUnsafeBytes(of: &sectorsBE) { data.replaceSubrange(0x30..<0x38, with: $0) }
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @Test("In-bundle ASIF disk shows used and allocated read live from the file")
    func asifDiskShowsUsedAndAllocated() throws {
        let instance = try makeInstanceWithBundle()
        let disk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Scratch", isInternal: true, kind: .virtio)
        try writeDiskFile(
            at: instance.bundleURL.appendingPathComponent(disk.path),
            totalBytes: 16384, capacitySectors: 97_656_250)  // 50 GB

        let subtitle = diskSubtitle(for: disk, bundleLayout: instance.bundleLayout)

        #expect(subtitle.contains("(used) / "))
        #expect(subtitle.contains("allocated"))
        #expect(subtitle.contains("50"))
    }

    @Test("In-bundle non-ASIF disk shows used and the logical size as allocated")
    func nonASIFDiskShowsLogicalSizeAsAllocated() throws {
        let instance = try makeInstanceWithBundle()
        let disk = StorageDisk(
            path: "AdditionalDisks/raw.img", label: "Raw", isInternal: true, kind: .virtio)
        // A raw image isn't a sparse container, so its apparent size *is* its
        // capacity — the subtitle shows both figures, not on-disk only.
        try writeDiskFile(
            at: instance.bundleURL.appendingPathComponent(disk.path),
            totalBytes: 16384, capacitySectors: nil)

        let subtitle = diskSubtitle(for: disk, bundleLayout: instance.bundleLayout)

        #expect(subtitle.contains("(used) / "))
        #expect(subtitle.contains("allocated"))
    }

    @Test("In-bundle disk with no file shows the generic label")
    func missingFileShowsGenericLabel() throws {
        let instance = try makeInstanceWithBundle()
        let disk = StorageDisk(
            path: "AdditionalDisks/missing.asif", label: "Gone", isInternal: true, kind: .virtio)

        #expect(diskSubtitle(for: disk, bundleLayout: instance.bundleLayout) == "In-bundle disk image")
    }

    @Test("External disk with an unreadable file falls back to its path")
    func externalDiskFallsBackToPathWhenUnreadable() throws {
        let instance = try makeInstanceWithBundle()
        // No file at this path, so neither figure is readable — the row degrades
        // to the path rather than showing nothing.
        let disk = StorageDisk(path: "/tmp/data.asif", label: "Data", isInternal: false)

        #expect(diskSubtitle(for: disk, bundleLayout: instance.bundleLayout) == "/tmp/data.asif")
    }

    @Test("External raw disk shows used and allocated read live from the file")
    func externalRawDiskShowsUsedAndAllocated() throws {
        let instance = try makeInstanceWithBundle()
        // A real external file (absolute path, raw — no ASIF header): its
        // apparent size is the capacity, so the row shows both figures, exactly
        // like an in-bundle disk.
        let fileURL = TestScratchDirectory(prefix: "StorageDiskSubtitleTests").url
            .appendingPathComponent("\(UUID().uuidString).img")
        try writeDiskFile(at: fileURL, totalBytes: 16384, capacitySectors: nil)
        let disk = StorageDisk(
            path: fileURL.path(percentEncoded: false), label: "Data", isInternal: false)

        let subtitle = diskSubtitle(for: disk, bundleLayout: instance.bundleLayout)

        #expect(subtitle.contains("(used) / "))
        #expect(subtitle.contains("allocated"))
    }

    @Test("Main disk is measured exactly the same way as additional disks")
    func mainDiskUsesSameLiveMeasurement() throws {
        let instance = try makeInstanceWithBundle()
        let main = instance.effectiveStorageDisks[0]
        try writeDiskFile(
            at: instance.bundleURL.appendingPathComponent(main.path),
            totalBytes: 16384, capacitySectors: 195_312_500)  // 100 GB

        let subtitle = diskSubtitle(for: main, bundleLayout: instance.bundleLayout)

        #expect(subtitle.contains("(used) / "))
        #expect(subtitle.contains("allocated"))
        #expect(subtitle.contains("100"))
    }

    @Test("A disk's subtitle says what it uses and what it can hold")
    func subtitleNamesUsedAndAllocated() {
        let used = DataFormatters.formatBytes(3_000_000_000)
        let allocated = DataFormatters.formatBytes(64_000_000_000)
        #expect(
            diskSubtitle(
                sizes: VMBundleLayout.DiskSizes(onDiskBytes: 3_000_000_000, capacityBytes: 64_000_000_000),
                path: "Disk.asif", isInternal: true)
                == "\(used) (used) / \(allocated) (allocated)")
        #expect(
            diskSubtitle(
                sizes: VMBundleLayout.DiskSizes(onDiskBytes: 3_000_000_000, capacityBytes: nil),
                path: "Disk.asif", isInternal: true)
                == "\(used) used")
    }
}
