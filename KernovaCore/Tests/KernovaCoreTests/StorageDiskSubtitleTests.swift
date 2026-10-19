import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("StorageDiskSubtitle Tests", .caseScoped)
struct StorageDiskSubtitleTests {
    private typealias DiskSizes = VMBundleLayout.DiskSizes

    private static let internalImage = DiskImageReference(path: "Disk.asif", isInternal: true)
    private static let externalImage = DiskImageReference(path: "/tmp/data.asif", isInternal: false)

    private static let used = DataFormatters.formatBytes(3_000_000_000)
    private static let allocated = DataFormatters.formatBytes(64_000_000_000)

    @Test("A disk's subtitle says what it uses and what it can hold, as far as each reads")
    func subtitleNamesUsedAndAllocated() {
        #expect(
            DiskSizes.subtitle(
                of: Self.internalImage,
                measured: DiskSizes(onDiskBytes: 3_000_000_000, capacityBytes: 64_000_000_000))
                == "\(Self.used) (used) / \(Self.allocated) (allocated)")
        #expect(
            DiskSizes.subtitle(of: Self.internalImage, measured: DiskSizes(onDiskBytes: 3_000_000_000))
                == "\(Self.used) used")
        #expect(
            DiskSizes.subtitle(of: Self.externalImage, measured: DiskSizes(capacityBytes: 64_000_000_000))
                == "\(Self.allocated) allocated")
    }

    @Test("Unmeasured or unreadable, an in-bundle disk shows the generic label and an external one its path")
    func subtitleFallsBackWithoutAFigure() {
        for measured in [nil, DiskSizes()] {
            #expect(DiskSizes.subtitle(of: Self.internalImage, measured: measured) == "In-bundle disk image")
            #expect(DiskSizes.subtitle(of: Self.externalImage, measured: measured) == "/tmp/data.asif")
        }
    }

    @Test("Get Info's figures format as the subtitle's do, and an unreadable one reads Unknown")
    func figuresShareTheSubtitlesFormatting() {
        let sizes = DiskSizes(onDiskBytes: 3_000_000_000, capacityBytes: 64_000_000_000)
        #expect(sizes.usedText == Self.used)
        #expect(sizes.allocatedText == Self.allocated)
        #expect(DiskSizes().usedText == "Unknown")
        #expect(DiskSizes().allocatedText == "Unknown")
    }
}
