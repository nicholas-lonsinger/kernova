import Foundation
import Testing

@testable import Kernova

@Suite("StorageDiskSubtitle Tests")
@MainActor
struct StorageDiskSubtitleTests {
    private func makeInstanceWithBundle() throws -> VMInstance {
        let config = VMConfiguration(name: "VM", guestOS: .linux, bootMode: .efi)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return VMInstance(configuration: config, bundleURL: url)
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

    @Test("In-bundle ASIF disk shows on-disk and allocated read live from the file")
    func asifDiskShowsOnDiskAndAllocated() throws {
        let instance = try makeInstanceWithBundle()
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        let disk = StorageDisk(
            path: "AdditionalDisks/x.asif", label: "Scratch", isInternal: true, kind: .virtio)
        try writeDiskFile(
            at: instance.bundleURL.appendingPathComponent(disk.path),
            totalBytes: 16384, capacitySectors: 97_656_250)  // 50 GB

        let subtitle = diskSubtitle(for: disk, bundleLayout: instance.bundleLayout)

        #expect(subtitle.contains("on disk"))
        #expect(subtitle.contains("allocated"))
        #expect(subtitle.contains("50"))
    }

    @Test("In-bundle non-ASIF disk shows on-disk only")
    func nonASIFDiskShowsOnDiskOnly() throws {
        let instance = try makeInstanceWithBundle()
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        let disk = StorageDisk(
            path: "AdditionalDisks/raw.img", label: "Raw", isInternal: true, kind: .virtio)
        try writeDiskFile(
            at: instance.bundleURL.appendingPathComponent(disk.path),
            totalBytes: 16384, capacitySectors: nil)

        let subtitle = diskSubtitle(for: disk, bundleLayout: instance.bundleLayout)

        #expect(subtitle.hasSuffix("on disk"))
        #expect(!subtitle.contains("allocated"))
    }

    @Test("In-bundle disk with no file shows the generic label")
    func missingFileShowsGenericLabel() throws {
        let instance = try makeInstanceWithBundle()
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        let disk = StorageDisk(
            path: "AdditionalDisks/missing.asif", label: "Gone", isInternal: true, kind: .virtio)

        #expect(diskSubtitle(for: disk, bundleLayout: instance.bundleLayout) == "In-bundle disk image")
    }

    @Test("External disk shows its path")
    func externalDiskShowsPath() throws {
        let instance = try makeInstanceWithBundle()
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        let disk = StorageDisk(path: "/tmp/data.asif", label: "Data", isInternal: false)

        #expect(diskSubtitle(for: disk, bundleLayout: instance.bundleLayout) == "/tmp/data.asif")
    }

    @Test("Main disk is measured exactly the same way as additional disks")
    func mainDiskUsesSameLiveMeasurement() throws {
        let instance = try makeInstanceWithBundle()
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        let main = VMLibraryViewModel.defaultStorageDisks(for: instance)[0]
        try writeDiskFile(
            at: instance.bundleURL.appendingPathComponent(main.path),
            totalBytes: 16384, capacitySectors: 195_312_500)  // 100 GB

        let subtitle = diskSubtitle(for: main, bundleLayout: instance.bundleLayout)

        #expect(subtitle.contains("on disk"))
        #expect(subtitle.contains("allocated"))
        #expect(subtitle.contains("100"))
    }
}
