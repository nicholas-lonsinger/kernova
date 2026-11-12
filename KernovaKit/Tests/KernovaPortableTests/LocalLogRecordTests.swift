#if canImport(os)
import Testing

@testable import KernovaLogging

@Suite("The unified-log record a LogMessage emits as")
struct LocalLogRecordTests {
    private func pub(_ text: String) -> LogSegment {
        LogSegment(text: text, isPrivate: false)
    }

    private func priv(_ text: String) -> LogSegment {
        LogSegment(text: text, isPrivate: true)
    }

    @Test("The fourth and later private runs fold, with the text between, into the third")
    func localRecordFoldsBeyondThree() {
        #expect(
            LocalLogRecord(segments: [
                priv("1"), pub("a"), priv("2"), pub("b"), priv("3"), pub("c"), priv("4"), pub("d"), priv("5"),
                pub("e"),
            ]) == .threePrivate("", "1", "a", "2", "b", "3c4d5", "e"))
    }
}
#endif
