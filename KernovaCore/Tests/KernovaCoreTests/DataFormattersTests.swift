import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("DataFormatters Tests", .caseScoped)
struct DataFormattersTests {
    // MARK: - formatBytes

    @Test("formatBytes returns '0 bytes' for zero bytes")
    func formatBytesZero() {
        let result = DataFormatters.formatBytes(0)
        #expect(result == "0 bytes")
    }

    @Test("formatBytes formats kilobytes")
    func formatBytesKB() {
        let result = DataFormatters.formatBytes(1_500)
        #expect(result.contains("KB"))
    }

    @Test("formatBytes formats terabytes")
    func formatBytesTB() {
        let result = DataFormatters.formatBytes(2_000_000_000_000)
        #expect(result.contains("TB"))
    }

    // MARK: - formatBytesFixedWidth

    @Test("formatBytesFixedWidth formats KB values")
    func formatBytesFixedWidthKB() {
        let result = DataFormatters.formatBytesFixedWidth(500_000)
        #expect(result.contains("KB"))
    }

    @Test("formatBytesFixedWidth formats MB values with figure spaces")
    func formatBytesFixedWidthMB() {
        let result = DataFormatters.formatBytesFixedWidth(861_900_000)
        #expect(result.contains("MB"))
        #expect(!result.contains(" "))
        #expect(result.contains("\u{2007}"))
    }

    @Test("formatBytesFixedWidth formats GB values with 3 decimal places")
    func formatBytesFixedWidthGB() {
        let result = DataFormatters.formatBytesFixedWidth(4_200_000_000)
        #expect(result.contains("GB"))
        // Verify 3 decimal places (e.g., "4.200")
        #expect(result.contains("4.200"))
    }

    @Test("formatBytesFixedWidth formats TB values with 3 decimal places")
    func formatBytesFixedWidthTB() {
        let result = DataFormatters.formatBytesFixedWidth(2_000_000_000_000)
        #expect(result.contains("TB"))
        #expect(result.contains("2.000"))
    }

    @Test("formatBytesFixedWidth shows 3 decimal places for sub-unit precision")
    func formatBytesFixedWidthPrecision() {
        // 10.642 GB = 10_642_000_000 bytes
        let result = DataFormatters.formatBytesFixedWidth(10_642_000_000)
        #expect(result.contains("10.642"))
        #expect(result.contains("GB"))
    }

    // MARK: - formatSpeed

    @Test("formatSpeed formats KB/s for low speeds")
    func formatSpeedKB() {
        let result = DataFormatters.formatSpeed(500_000)
        #expect(result.contains("KB/s"))
        #expect(result.contains("500.0"))
    }

    @Test("formatSpeed formats MB/s for typical download speeds")
    func formatSpeedMB() {
        let result = DataFormatters.formatSpeed(42_500_000)
        #expect(result.contains("MB/s"))
        #expect(result.contains("42.5"))
        #expect(!result.contains(" "))
        #expect(result.contains("\u{2007}"))
    }

    @Test("formatSpeed formats GB/s for very high speeds")
    func formatSpeedGB() {
        let result = DataFormatters.formatSpeed(2_500_000_000)
        #expect(result.contains("GB/s"))
        #expect(result.contains("2.5"))
    }

    // MARK: - formatETA

    @Test("formatETA returns nil for negligible speed")
    func formatETANegligibleSpeed() {
        let result = DataFormatters.formatETA(remainingBytes: 1_000_000, bytesPerSecond: 500)
        #expect(result == nil)
    }

    @Test("formatETA formats a sub-minute estimate as a padded H:MM:SS clock")
    func formatETAValid() {
        // 100 MB remaining at 10 MB/s = 10 seconds
        let result = DataFormatters.formatETA(remainingBytes: 100_000_000, bytesPerSecond: 10_000_000)
        #expect(result == "\u{2007}0:00:10")
    }

    @Test("formatETA formats a multi-hour estimate, padding a single-digit hour with a figure space")
    func formatETALargeTime() {
        // 10 GB remaining at 1 MB/s = 10000 seconds = 2h 46m 40s
        let result = DataFormatters.formatETA(remainingBytes: 10_000_000_000, bytesPerSecond: 1_000_000)
        #expect(result == "\u{2007}2:46:40")
    }

    @Test("formatETA keeps a two-digit hour field unpadded")
    func formatETATwoDigitHour() {
        // 36 GB remaining at 1 MB/s = 36000 seconds = exactly 10:00:00
        let result = DataFormatters.formatETA(remainingBytes: 36_000_000_000, bytesPerSecond: 1_000_000)
        #expect(result == "10:00:00")
    }

    @Test("formatETA holds a constant glyph template across unit boundaries")
    func formatETAConstantTemplate() {
        // Every estimate renders as [figure-space|digit][digit]:[digit][digit]:[digit][digit].
        let template = "^[\u{2007}0-9][0-9]:[0-9]{2}:[0-9]{2}$"
        for seconds in [9, 10, 59, 60, 90, 3599, 3600, 35_999, 36_000, 359_000] {
            // remaining = seconds × speed, so the estimate is exactly `seconds`.
            let result = DataFormatters.formatETA(
                remainingBytes: Int64(seconds) * 1_000_000, bytesPerSecond: 1_000_000)
            #expect(result != nil)
            #expect(
                result?.range(of: template, options: .regularExpression) != nil,
                "ETA \(result ?? "nil") for \(seconds)s should match the fixed clock template")
        }
    }

    @Test("etaUnknownPlaceholder is a same-shape figure-dash clock")
    func etaUnknownPlaceholder() {
        #expect(DataFormatters.etaUnknownPlaceholder == "\u{2007}\u{2012}:\u{2012}\u{2012}:\u{2012}\u{2012}")
    }

    @Test("formatETA returns nil when estimate exceeds upper bound")
    func formatETAExceedsUpperBound() {
        // 360_001 seconds at 1 KB/s
        let result = DataFormatters.formatETA(remainingBytes: 360_001_000, bytesPerSecond: 1_000)
        #expect(result == nil)
    }

    @Test("formatETA returns nil for negative remaining bytes")
    func formatETANegativeRemaining() {
        let result = DataFormatters.formatETA(remainingBytes: -1000, bytesPerSecond: 10_000_000)
        #expect(result == nil)
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
