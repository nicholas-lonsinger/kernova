import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@Suite("VMMemorySize", .caseScoped)
struct VMMemorySizeTests {
    // MARK: - JSON

    private func encoded(_ size: VMMemorySize) throws -> String {
        String(decoding: try JSONEncoder().encode([size]), as: UTF8.self)
    }

    private func decoded(_ json: String) throws -> VMMemorySize {
        try JSONDecoder().decode([VMMemorySize].self, from: Data(json.utf8))[0]
    }

    @Test("A whole size encodes as an integer and round-trips")
    func wholeSizeEncodesAsInteger() throws {
        #expect(try encoded(.gibibytes(8)) == "[8]")
        #expect(try decoded("[8]") == .gibibytes(8))
    }

    @Test("A fractional size encodes as a decimal and round-trips")
    func fractionalSizeEncodesAsDecimal() throws {
        let size = try decoded("[1.5]")
        #expect(size.mebibytes == 1536)
        #expect(try encoded(size) == "[1.5]")
    }

    @Test("A decimal naming no whole mebibyte decodes to the nearest one")
    func decodingRoundsToTheNearestMebibyte() throws {
        // 1.0004 GiB is 1024.41 MiB; 1.0006 GiB is 1024.61 MiB.
        #expect(try decoded("[1.0004]").mebibytes == 1024)
        #expect(try decoded("[1.0006]").mebibytes == 1025)
    }

    @Test("A negative size is refused")
    func negativeSizeIsRefused() {
        #expect(throws: DecodingError.self) { try decoded("[-1]") }
    }

    // MARK: - Text

    @Test("Text shows a whole size without decimals and any other with the fewest that round-trip")
    func textRoundTrips() {
        #expect(VMMemorySize.gibibytes(8).gibibytesText == "8")
        #expect(VMMemorySize(mebibytes: 1536).gibibytesText == "1.5")
        #expect(VMMemorySize(mebibytes: 1537).gibibytesText == "1.501")
        for mebibytes: UInt32 in [1, 4, 511, 1025, 1537, 4095, 65_535, 1_048_577] {
            let size = VMMemorySize(mebibytes: mebibytes)
            #expect(VMMemorySize(gibibytesText: size.gibibytesText) == size)
        }
    }

    @Test("Text that names no size is refused")
    func unparseableTextIsRefused() {
        #expect(VMMemorySize(gibibytesText: "lots") == nil)
        #expect(VMMemorySize(gibibytesText: "inf") == nil)
        #expect(VMMemorySize(gibibytesText: "nan") == nil)
        #expect(VMMemorySize(gibibytesText: "-2") == nil)
    }

    // MARK: - Stepping

    @Test("A stepper arrow moves to the next whole gibibyte in its direction")
    func steppingSnapsToWholeGibibytes() {
        let oneAndAHalf = VMMemorySize(mebibytes: 1536)
        #expect(oneAndAHalf.nextWholeGibibyte(upward: true) == .gibibytes(2))
        #expect(oneAndAHalf.nextWholeGibibyte(upward: false) == .gibibytes(1))
        #expect(VMMemorySize.gibibytes(4).nextWholeGibibyte(upward: true) == .gibibytes(5))
        #expect(VMMemorySize.gibibytes(4).nextWholeGibibyte(upward: false) == .gibibytes(3))
        #expect(VMMemorySize(mebibytes: 4).nextWholeGibibyte(upward: false) == VMMemorySize(mebibytes: 0))
    }
}
