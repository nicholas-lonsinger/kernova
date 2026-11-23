import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("VMBundleLayout Tests", .caseScoped)
struct VMBundleLayoutTests {
    private let bundleURL = URL(fileURLWithPath: "/tmp/TestVM.bundle", isDirectory: true)

    // MARK: - Path Computed Properties

    @Test("a snapshot's layout names its captured copies the way the bundle names its own")
    func snapshotLayoutMirrorsTheBundle() {
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let id = UUID()
        let snapshot = layout.snapshotLayout(id: id)

        #expect(snapshot.bundleURL == layout.snapshotDirectoryURL(id: id))
        #expect(snapshot.bundleURL.lastPathComponent == id.uuidString)
        #expect(snapshot.diskImageURL.lastPathComponent == "Disk.asif")
        #expect(snapshot.saveFileURL.lastPathComponent == "SaveFile.vzvmsave")
        // Distinct from the bundle's own suspend slot, which a revert overwrites
        // but never consumes.
        #expect(snapshot.saveFileURL != layout.saveFileURL)
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
}
