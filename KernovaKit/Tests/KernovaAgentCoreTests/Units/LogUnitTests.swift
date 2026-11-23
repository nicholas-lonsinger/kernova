#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@testable import KernovaAgentCore
import SwiftProtobuf
import Testing

extension CoreUnits {
    @Suite("LogRing and the log record bounds")
    struct LogRingUnitTests {
        // MARK: Record bounds

        @Test("Segment text is cut to 16,384 UTF-8 bytes in total on a scalar boundary, setting truncated")
        func textBound() {
            let record = LogRecordValue(
                timestampMilliseconds: 0, level: .info, subsystem: "s", category: "c",
                segments: [
                    LogSegmentValue(text: String(repeating: "a", count: 16_000)),
                    LogSegmentValue(text: "b" + String(repeating: "€", count: 200), isPrivate: true),
                ])
            let total = record.segments.reduce(0) { $0 + $1.text.utf8.count }
            #expect(total == 16_000 + 1 + 3 * 127)
            #expect(record.segments.last?.isPrivate == true)
            #expect(record.truncated)
        }
    }
}
