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

    @Test("formatBytesFixedWidth formats GB values")
    func formatBytesFixedWidthGB() {
        let result = DataFormatters.formatBytesFixedWidth(4_200_000_000)
        #expect(result.contains("GB"))
    }

    @Test("formatBytesFixedWidth formats TB values")
    func formatBytesFixedWidthTB() {
        let result = DataFormatters.formatBytesFixedWidth(2_000_000_000_000)
        #expect(result.contains("TB"))
    }

    @Test("formatBytesFixedWidth uses figure spaces instead of regular spaces")
    func formatBytesFixedWidthFigureSpaces() {
        let result = DataFormatters.formatBytesFixedWidth(861_900_000)
        // Should use figure space U+2007, not regular space U+0020
        #expect(!result.contains(" "))
        #expect(result.contains("\u{2007}"))
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

    // MARK: - formatDuration

    @Test("formatDuration formats seconds only")
    func formatDurationSecondsOnly() {
        let result = DataFormatters.formatDuration(45)
        #expect(result.contains("45"))
        #expect(result.contains("s"))
    }

    @Test("formatDuration formats minutes and seconds")
    func formatDurationMinutesSeconds() {
        let result = DataFormatters.formatDuration(125) // 2m 5s
        #expect(result.contains("m"))
        #expect(result.contains("s"))
    }

    @Test("formatDuration formats hours, minutes, and seconds")
    func formatDurationHoursMinutesSeconds() {
        let result = DataFormatters.formatDuration(3661) // 1h 1m 1s
        #expect(result.contains("h"))
        #expect(result.contains("m"))
        #expect(result.contains("s"))
    }
}
