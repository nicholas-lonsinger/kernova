import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("DataFormatters Tests", .caseScoped)
struct DataFormattersTests {
    // MARK: - formatBytes

    @Test("formatBytes returns '0 bytes' for zero bytes")
    func formatBytesZero() {
        let result = DataFormatters.formatBytes(0)
        #expect(result == "0 bytes")
    }

    // MARK: - formatBytesFixedWidth

    @Test("formatBytesFixedWidth formats MB values with figure spaces")
    func formatBytesFixedWidthMB() {
        let result = DataFormatters.formatBytesFixedWidth(861_900_000)
        #expect(result.contains("MB"))
        #expect(!result.contains(" "))
        #expect(result.contains("\u{2007}"))
    }

    @Test("formatBytesFixedWidth formats TB values with 3 decimal places")
    func formatBytesFixedWidthTB() {
        let result = DataFormatters.formatBytesFixedWidth(2_000_000_000_000)
        #expect(result.contains("TB"))
        #expect(result.contains("2.000"))
    }

    // MARK: - formatETA

    @Test("formatETA formats a multi-hour estimate, padding a single-digit hour with a figure space")
    func formatETALargeTime() {
        // 10 GB remaining at 1 MB/s = 10000 seconds = 2h 46m 40s
        let result = DataFormatters.formatETA(remainingBytes: 10_000_000_000, bytesPerSecond: 1_000_000)
        #expect(result == "\u{2007}2:46:40")
    }

    // MARK: - formatDiskSize

    @Test("formatDiskSize separates number and unit with one plain space, unpadded")
    func formatDiskSizeGB() {
        #expect(DataFormatters.formatDiskSize(100) == "100 GB")
        #expect(DataFormatters.formatDiskSize(250) == "250 GB")
        #expect(DataFormatters.formatDiskSize(10) == "10 GB")
        #expect(DataFormatters.formatDiskSize(75) == "75 GB")
    }

    @Test("diskSizeParts splits the number from the unit, switching to TB at 1000 GB")
    func diskSizeParts() {
        for (sizeInGB, number, unit) in [
            (10, "10", "GB"), (999, "999", "GB"), (1000, "1.0", "TB"), (1500, "1.5", "TB"),
        ] {
            let parts = DataFormatters.diskSizeParts(sizeInGB)
            #expect(parts.number == number, "number for \(sizeInGB) GB")
            #expect(parts.unit == unit, "unit for \(sizeInGB) GB")
        }
    }
}
