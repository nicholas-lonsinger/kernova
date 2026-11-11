import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("StorageDisk Tests", .caseScoped)
struct StorageDiskTests {
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
