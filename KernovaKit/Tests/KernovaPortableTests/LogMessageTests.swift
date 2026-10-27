import KernovaLogging
import Testing

@Suite("LogMessage segments")
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
}
