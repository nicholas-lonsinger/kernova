import KernovaTestSupport
import Testing

@testable import KernovaLogging

@Suite("The unified-log record a LogMessage emits as", .caseScoped)
struct LocalLogRecordTests {
    private func pub(_ text: String) -> LogSegment {
        LogSegment(text: text, isPrivate: false)
    }

    private func priv(_ text: String) -> LogSegment {
        LogSegment(text: text, isPrivate: true)
    }

    @Test("A message with no private segment emits as one public run")
    func localRecordAllPublic() {
        #expect(LocalLogRecord(segments: []) == .noPrivate(""))
        #expect(LocalLogRecord(segments: [pub("saw "), pub("3"), pub(" items")]) == .noPrivate("saw 3 items"))
    }

    @Test("Adjacent segments of one privacy merge into one run, and empty segments drop out")
    func localRecordMergesRuns() {
        #expect(
            LocalLogRecord(segments: [pub("copied "), priv("/a/"), priv("b.txt"), pub(""), pub(" to "), priv("vm")])
                == .twoPrivate("copied ", "/a/b.txt", " to ", "vm", ""))
        #expect(LocalLogRecord(segments: [priv("x"), priv(""), priv("y")]) == .onePrivate("", "xy", ""))
    }

    @Test("Up to three private runs each get their own argument")
    func localRecordThreePrivateRuns() {
        #expect(
            LocalLogRecord(segments: [pub("a"), priv("1"), pub("b"), priv("2"), pub("c"), priv("3"), pub("d")])
                == .threePrivate("a", "1", "b", "2", "c", "3", "d"))
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
