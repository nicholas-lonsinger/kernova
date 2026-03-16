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
        FileManager.default.createFile(atPath: layout.saveFileURL.path, contents: Data([0x00]))

        #expect(layout.hasSaveFile == true)
    }

    // MARK: - diskUsageBytes

    @Test("diskUsageBytes returns nil when disk image does not exist")
    func diskUsageBytesReturnsNilForMissingFile() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let layout = VMBundleLayout(bundleURL: tempDir)
        #expect(layout.diskUsageBytes == nil)
    }

    @Test("diskUsageBytes returns correct size for an existing file")
    func diskUsageBytesReturnsSize() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let layout = VMBundleLayout(bundleURL: tempDir)
        let testData = Data(repeating: 0xAB, count: 4096)
        try testData.write(to: layout.diskImageURL)

        let usage = layout.diskUsageBytes
        #expect(usage == 4096)
    }
}
