import Testing
import Foundation
@testable import Kernova

@Suite("VMBundleLayout Tests")
struct VMBundleLayoutTests {
    private let bundleURL = URL(fileURLWithPath: "/tmp/TestVM.bundle", isDirectory: true)

    // MARK: - Path Computed Properties

    @Test("diskImageURL appends Disk.asif to bundle path")
    func diskImageURL() {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        #expect(layout.diskImageURL.lastPathComponent == "Disk.asif")
        #expect(layout.diskImageURL.deletingLastPathComponent() == bundleURL)
    }

    @Test("auxiliaryStorageURL appends AuxiliaryStorage to bundle path")
    func auxiliaryStorageURL() {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        #expect(layout.auxiliaryStorageURL.lastPathComponent == "AuxiliaryStorage")
        #expect(layout.auxiliaryStorageURL.deletingLastPathComponent() == bundleURL)
    }

    @Test("hardwareModelURL appends HardwareModel to bundle path")
    func hardwareModelURL() {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        #expect(layout.hardwareModelURL.lastPathComponent == "HardwareModel")
        #expect(layout.hardwareModelURL.deletingLastPathComponent() == bundleURL)
    }

    @Test("machineIdentifierURL appends MachineIdentifier to bundle path")
    func machineIdentifierURL() {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        #expect(layout.machineIdentifierURL.lastPathComponent == "MachineIdentifier")
        #expect(layout.machineIdentifierURL.deletingLastPathComponent() == bundleURL)
    }

    @Test("efiVariableStoreURL appends EFIVariableStore to bundle path")
    func efiVariableStoreURL() {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        #expect(layout.efiVariableStoreURL.lastPathComponent == "EFIVariableStore")
        #expect(layout.efiVariableStoreURL.deletingLastPathComponent() == bundleURL)
    }

    @Test("saveFileURL appends SaveFile.vzvmsave to bundle path")
    func saveFileURL() {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        #expect(layout.saveFileURL.lastPathComponent == "SaveFile.vzvmsave")
        #expect(layout.saveFileURL.deletingLastPathComponent() == bundleURL)
    }

    @Test("serialLogURL appends serial.log to bundle path")
    func serialLogURL() {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        #expect(layout.serialLogURL.lastPathComponent == "serial.log")
        #expect(layout.serialLogURL.deletingLastPathComponent() == bundleURL)
    }

    @Test("additionalDisksDirectoryURL appends AdditionalDisks to bundle path")
    func additionalDisksDirectoryURL() {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        #expect(layout.additionalDisksDirectoryURL.lastPathComponent == "AdditionalDisks")
        #expect(layout.additionalDisksDirectoryURL.deletingLastPathComponent() == bundleURL)
    }

    @Test("additionalDiskURL returns path with UUID and .asif extension")
    func additionalDiskURL() {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let diskID = UUID()
        let diskURL = layout.additionalDiskURL(id: diskID)
        #expect(diskURL.lastPathComponent == "\(diskID.uuidString).asif")
        #expect(
            diskURL.path(percentEncoded: false).hasPrefix(
                layout.additionalDisksDirectoryURL.path(percentEncoded: false)))
    }

    // MARK: - hasSaveFile

    @Test("hasSaveFile returns false when no save file exists")
    func hasSaveFileReturnsFalse() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let layout = VMBundleLayout(bundleURL: tempDir)
        #expect(layout.hasSaveFile == false)
    }

    @Test("hasSaveFile returns true when save file exists on disk")
    func hasSaveFileReturnsTrue() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let layout = VMBundleLayout(bundleURL: tempDir)
        FileManager.default.createFile(atPath: layout.saveFileURL.path(percentEncoded: false), contents: Data([0x00]))

        #expect(layout.hasSaveFile == true)
    }

    // MARK: - diskOnDiskBytes

    private func mainDiskOnDiskBytes(_ layout: VMBundleLayout) -> UInt64? {
        layout.diskOnDiskBytes(
            forRelativePath: layout.diskImageURL.lastPathComponent, isInternal: true)
    }

    @Test("diskOnDiskBytes returns nil when disk image does not exist")
    func diskOnDiskBytesReturnsNilForMissingFile() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let layout = VMBundleLayout(bundleURL: tempDir)
        #expect(mainDiskOnDiskBytes(layout) == nil)
    }

    @Test("diskOnDiskBytes returns non-nil for an existing file")
    func diskOnDiskBytesReturnsSize() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let layout = VMBundleLayout(bundleURL: tempDir)
        let testData = Data(repeating: 0xAB, count: 4096)
        try testData.write(to: layout.diskImageURL)

        let usage = mainDiskOnDiskBytes(layout)
        #expect(usage != nil)
        // totalFileAllocatedSizeKey returns block-aligned allocation, so >= data size
        #expect(usage! >= 4096)
    }

    @Test("diskOnDiskBytes returns physical allocation less than logical size for sparse files")
    func diskOnDiskBytesReturnsSparseSize() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let layout = VMBundleLayout(bundleURL: tempDir)
        let path = layout.diskImageURL.path(percentEncoded: false)

        // Create a sparse file via ftruncate: 10 MB logical size, 0 bytes physically allocated
        let logicalSize: UInt64 = 10 * 1024 * 1024
        FileManager.default.createFile(atPath: path, contents: nil)
        let fd = open(path, O_WRONLY)
        ftruncate(fd, off_t(logicalSize))
        close(fd)

        let usage = mainDiskOnDiskBytes(layout)
        #expect(usage != nil)
        // Physical allocation should be much less than the 10 MB logical size
        #expect(usage! < logicalSize)
    }

    // MARK: - diskCapacityBytes

    @Test("diskCapacityBytes reads the virtual capacity from a shdw header")
    func diskCapacityBytesReadsASIFHeader() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let layout = VMBundleLayout(bundleURL: tempDir)
        // Minimal `shdw` header: magic at 0, sector count (big-endian) at 0x30.
        var header = Data(count: 0x38)
        header.replaceSubrange(0..<4, with: Data("shdw".utf8))
        var sectorsBE = UInt64(97_656_250).bigEndian  // 50 GB / 512
        withUnsafeBytes(of: &sectorsBE) { header.replaceSubrange(0x30..<0x38, with: $0) }
        try header.write(to: layout.diskImageURL)

        let capacity = layout.diskCapacityBytes(
            forRelativePath: layout.diskImageURL.lastPathComponent, isInternal: true)
        #expect(capacity == 50_000_000_000)
    }

    @Test("diskCapacityBytes returns the logical file size for a non-ASIF file")
    func diskCapacityBytesLogicalSizeForNonASIF() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let layout = VMBundleLayout(bundleURL: tempDir)
        // A raw image (no `shdw` magic): apparent size *is* the capacity.
        try Data(repeating: 0xAB, count: 0x40).write(to: layout.diskImageURL)

        #expect(
            layout.diskCapacityBytes(
                forRelativePath: layout.diskImageURL.lastPathComponent, isInternal: true) == 0x40)
    }

    @Test("diskCapacityBytes resolves an external (absolute) path's logical size")
    func diskCapacityBytesExternalAbsolutePath() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).img")
        try Data(repeating: 0xCD, count: 2048).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let layout = VMBundleLayout(bundleURL: FileManager.default.temporaryDirectory)
        #expect(
            layout.diskCapacityBytes(
                forRelativePath: fileURL.path(percentEncoded: false), isInternal: false) == 2048)
    }

    @Test("diskCapacityBytes returns nil for a missing file")
    func diskCapacityBytesNilForMissingFile() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let layout = VMBundleLayout(bundleURL: tempDir)
        #expect(
            layout.diskCapacityBytes(
                forRelativePath: layout.diskImageURL.lastPathComponent, isInternal: true) == nil)
    }

    @Test("diskCapacityBytes returns nil for a malformed ASIF rather than its file size")
    func diskCapacityBytesNilForMalformedASIF() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let layout = VMBundleLayout(bundleURL: tempDir)
        // `shdw` magic but an out-of-bounds sector count (1 sector = 512 bytes,
        // below the 1 MB floor). A recognizable ASIF must report unknown — not
        // fall back to the apparent file size, which a sparse container doesn't
        // tie to capacity.
        var header = Data(count: 0x38)
        header.replaceSubrange(0..<4, with: Data("shdw".utf8))
        var sectorsBE = UInt64(1).bigEndian
        withUnsafeBytes(of: &sectorsBE) { header.replaceSubrange(0x30..<0x38, with: $0) }
        try header.write(to: layout.diskImageURL)

        #expect(
            layout.diskCapacityBytes(
                forRelativePath: layout.diskImageURL.lastPathComponent, isInternal: true) == nil)
    }
}
