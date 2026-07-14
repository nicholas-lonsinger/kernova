import Testing
import Foundation
@testable import Kernova

@Suite("DataFormatters Tests")
struct DataFormattersTests {
    // MARK: - formatBytes

    @Test("formatBytes returns 'Zero KB' for zero bytes")
    func formatBytesZero() {
        let result = DataFormatters.formatBytes(0)
        #expect(result == "Zero KB")
    }

    @Test("formatBytes formats kilobytes")
    func formatBytesKB() {
        let result = DataFormatters.formatBytes(1_500)
        #expect(result.contains("KB"))
    }

    @Test("formatBytes formats megabytes")
    func formatBytesMB() {
        let result = DataFormatters.formatBytes(5_000_000)
        #expect(result.contains("MB"))
    }

    @Test("formatBytes formats gigabytes")
    func formatBytesGB() {
        let result = DataFormatters.formatBytes(4_200_000_000)
        #expect(result.contains("GB"))
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

    @Test("formatBytesFixedWidth formats MB values")
    func formatBytesFixedWidthMB() {
        let result = DataFormatters.formatBytesFixedWidth(861_900_000)
        #expect(result.contains("MB"))
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

    @Test("formatBytesFixedWidth uses figure spaces instead of regular spaces")
    func formatBytesFixedWidthFigureSpaces() {
        let result = DataFormatters.formatBytesFixedWidth(861_900_000)
        // Should use figure space U+2007, not regular space U+0020
        #expect(!result.contains(" "))
        #expect(result.contains("\u{2007}"))
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
    }

    @Test("formatSpeed formats GB/s for very high speeds")
    func formatSpeedGB() {
        let result = DataFormatters.formatSpeed(2_500_000_000)
        #expect(result.contains("GB/s"))
        #expect(result.contains("2.5"))
    }

    @Test("formatSpeed uses figure spaces instead of regular spaces")
    func formatSpeedFigureSpaces() {
        let result = DataFormatters.formatSpeed(42_500_000)
        #expect(!result.contains(" "))
        #expect(result.contains("\u{2007}"))
    }

    // MARK: - formatETA

    @Test("formatETA returns nil for zero speed")
    func formatETAZeroSpeed() {
        let result = DataFormatters.formatETA(remainingBytes: 1_000_000, bytesPerSecond: 0)
        #expect(result == nil)
    }

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

    @Test("formatETA pads with figure spaces, never plain spaces")
    func formatETAFigureSpaces() {
        // 5000 seconds = 1h 23m 20s — a single-digit hour that must be figure-space padded.
        let result = DataFormatters.formatETA(remainingBytes: 10_000_000, bytesPerSecond: 2_000)
        #expect(result == "\u{2007}1:23:20")
        #expect(result?.contains(" ") == false)
        #expect(result?.contains("\u{2007}") == true)
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

    @Test("formatSpeed handles zero input")
    func formatSpeedZero() {
        let result = DataFormatters.formatSpeed(0)
        #expect(result.contains("KB/s"))
        #expect(result.contains("0.0"))
    }

    // MARK: - formatDiskSize

    @Test("formatDiskSize formats GB values with figure-space padding")
    func formatDiskSizeGB() {
        #expect(DataFormatters.formatDiskSize(100) == "100\u{2007}GB")
        #expect(DataFormatters.formatDiskSize(250) == "250\u{2007}GB")
        #expect(DataFormatters.formatDiskSize(10) == "\u{2007}10\u{2007}GB")
        #expect(DataFormatters.formatDiskSize(75) == "\u{2007}75\u{2007}GB")
    }

    @Test("formatDiskSize formats whole TB values with one decimal")
    func formatDiskSizeWholeTB() {
        #expect(DataFormatters.formatDiskSize(1000) == "1.0\u{2007}TB")
        #expect(DataFormatters.formatDiskSize(2000) == "2.0\u{2007}TB")
        #expect(DataFormatters.formatDiskSize(10000) == "10.0\u{2007}TB")
    }

    @Test("formatDiskSize formats fractional TB with one decimal")
    func formatDiskSizeFractionalTB() {
        #expect(DataFormatters.formatDiskSize(1500) == "1.5\u{2007}TB")
        #expect(DataFormatters.formatDiskSize(2500) == "2.5\u{2007}TB")
        #expect(DataFormatters.formatDiskSize(7500) == "7.5\u{2007}TB")
    }

    // MARK: - formatCPUCount

    @Test("formatCPUCount returns singular for 1 core")
    func formatCPUCountSingular() {
        #expect(DataFormatters.formatCPUCount(1) == "1 core")
    }

    @Test("formatCPUCount returns plural for multiple cores")
    func formatCPUCountPlural() {
        #expect(DataFormatters.formatCPUCount(4) == "4 cores")
    }
}
