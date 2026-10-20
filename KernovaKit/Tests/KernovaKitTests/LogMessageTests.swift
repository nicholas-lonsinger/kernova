import Foundation
import KernovaTestSupport
import OSLog
import Testing

@testable import KernovaLogging

@Suite("LogMessage segments and the local record they emit as", .caseScoped)
struct LogMessageTests {
    private struct Point {
        let x: Int
    }

    private func segments(_ message: LogMessage) -> [LogSegment] {
        message.segments
    }

    private func pub(_ text: String) -> LogSegment {
        LogSegment(text: text, isPrivate: false)
    }

    private func priv(_ text: String) -> LogSegment {
        LogSegment(text: text, isPrivate: true)
    }

    // MARK: - Default privacy

    @Test("Integers, floating-point values and Booleans default to public")
    func numericAndBooleanDefaultToPublic() {
        let count = 7
        let byte = UInt8(3)
        let ratio = 2.5
        let scale = Float(1.5)
        let flag = true
        #expect(segments("\(count)") == [pub("7")])
        #expect(segments("\(byte)") == [pub("3")])
        #expect(segments("\(ratio)") == [pub("2.5")])
        #expect(segments("\(scale)") == [pub("1.5")])
        #expect(segments("\(flag)") == [pub("true")])
    }

    @Test("Strings and other values default to private")
    func stringsAndObjectsDefaultToPrivate() {
        let name = "alice"
        let substring = name.prefix(3)
        let point = Point(x: 1)
        #expect(segments("\(name)") == [priv("alice")])
        #expect(segments("\(substring)") == [priv("ali")])
        #expect(segments("\(point)") == [priv("Point(x: 1)")])
    }

    @Test("An explicit privacy overrides the default in both directions")
    func explicitPrivacyWins() {
        let name = "alice"
        let point = Point(x: 1)
        let count = 7
        let flag = false
        #expect(segments("\(name, privacy: .public)") == [pub("alice")])
        #expect(segments("\(point, privacy: .public)") == [pub("Point(x: 1)")])
        #expect(segments("\(count, privacy: .private)") == [priv("7")])
        #expect(segments("\(flag, privacy: .private)") == [priv("false")])
    }

    // MARK: - Literal text

    @Test("Literal text between interpolations is one public segment, and an empty run adds none")
    func literalRuns() {
        let a = 1
        let b = "x"
        #expect(
            segments("a \(a, privacy: .public) b \(b, privacy: .private)")
                == [pub("a "), pub("1"), pub(" b "), priv("x")])
        #expect(segments("\(a)\(b)") == [pub("1"), priv("x")])
        #expect(segments("") == [])
        #expect(segments("started") == [pub("started")])
    }

    @Test("Escapes decode to the characters they spell")
    func escapes() {
        let n = 1
        #expect(segments("tab\there \"q\" \u{2014}\n\(n)") == [pub("tab\there \"q\" —\n"), pub("1")])
    }

    @Test("A raw literal keeps its backslashes and quotes, and interpolates with its delimiter")
    func rawLiteral() {
        let name = "bob"
        #expect(
            segments(#"say "hi"\n\#(name, privacy: .public)"#)
                == [pub(#"say "hi"\n"#), pub("bob")])
    }

    @Test("A multi-line literal strips its indentation and honors line continuation")
    func multiLineLiteral() {
        let a = 1
        let message: LogMessage = """
            first \(a, privacy: .public), \
            second
            third
            """
        #expect(message.segments == [pub("first "), pub("1"), pub(", second\nthird")])
    }

    @Test("init(segments:) carries its segments unchanged")
    func initFromSegments() {
        let given = [pub("[a/b] "), priv("secret"), pub("")]
        #expect(LogMessage(segments: given).segments == given)
    }

    // MARK: - Local record

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
