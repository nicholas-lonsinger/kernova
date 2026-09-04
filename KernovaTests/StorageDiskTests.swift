import Foundation
import Testing

@testable import Kernova

@Suite("StorageDisk Tests")
struct StorageDiskTests {
    @Test("mainDisk produces a stable UUID for the same bundle URL")
    func mainDiskUUIDIsStableAcrossCalls() {
        let bundleURL = URL(fileURLWithPath: "/tmp/kernova-test-stable.kernova")
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let first = StorageDisk.mainDisk(layout: layout)
        let second = StorageDisk.mainDisk(layout: layout)
        #expect(first.id == second.id)
    }

    @Test("mainDisk produces distinct UUIDs for distinct bundle URLs")
    func mainDiskUUIDsDifferAcrossBundles() {
        let aLayout = VMBundleLayout(
            bundleURL: URL(fileURLWithPath: "/tmp/kernova-test-a.kernova"))
        let bLayout = VMBundleLayout(
            bundleURL: URL(fileURLWithPath: "/tmp/kernova-test-b.kernova"))
        #expect(
            StorageDisk.mainDisk(layout: aLayout).id
                != StorageDisk.mainDisk(layout: bLayout).id)
    }

    @Test("isBundledGuestAgentInstaller matches the bundled DMG path only")
    func bundledGuestAgentInstallerMatchesThePathOnly() throws {
        let agentPath = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
            .path(percentEncoded: false)
        #expect(RemovableMediaItem(path: agentPath, readOnly: true).isBundledGuestAgentInstaller)
        #expect(
            !RemovableMediaItem(path: "/tmp/other.iso", readOnly: true)
                .isBundledGuestAgentInstaller)
    }

    @Test("mainDisk is an internal virtio disk at the bundle's Disk.asif")
    func mainDiskShape() {
        let layout = VMBundleLayout(bundleURL: URL(fileURLWithPath: "/tmp/kernova-test-shape.kernova"))
        let disk = StorageDisk.mainDisk(layout: layout)
        #expect(disk.path == layout.diskImageURL.lastPathComponent)
        #expect(disk.isInternal)
        #expect(disk.kind == .virtio)
        #expect(!disk.readOnly)
    }
}
