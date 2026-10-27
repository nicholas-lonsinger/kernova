#if !canImport(os)
import Testing

@testable import KernovaLogging

@Suite("The standard-error line a record prints as")
struct StandardErrorLogLineTests {
    private let destination = LocalLogDestination(subsystem: "app.kernova.agent", category: "Clipboard")

    private func pub(_ text: String) -> LogSegment {
        LogSegment(text: text, isPrivate: false)
    }

    private func priv(_ text: String) -> LogSegment {
        LogSegment(text: text, isPrivate: true)
    }

    @Test("A line opens with its level's syslog priority, then the subsystem and category")
    func priorityAndLabel() {
        let expected: [(KernovaLogLevel, String)] = [
            (.debug, "<7>"), (.info, "<6>"), (.notice, "<5>"), (.warning, "<4>"), (.error, "<3>"), (.fault, "<2>"),
        ]
        for (level, prefix) in expected {
            #expect(
                destination.line([pub("saw 3 items")], at: level)
                    == "\(prefix)[app.kernova.agent:Clipboard] saw 3 items\n")
        }
    }

    @Test("Each run of private segments prints as one <private>, and empty segments drop out")
    func privateRunsAreRedacted() {
        let segments = [pub("copied "), priv("/a/"), priv("b.txt"), pub(""), pub(" to "), priv("vm")]
        #expect(
            destination.line(segments, at: .notice)
                == "<5>[app.kernova.agent:Clipboard] copied <private> to <private>\n")
        #expect(
            destination.line([priv("x"), pub(""), priv("y")], at: .notice)
                == "<5>[app.kernova.agent:Clipboard] <private>\n")
        #expect(destination.line([], at: .notice) == "<5>[app.kernova.agent:Clipboard] \n")
    }

    @Test("A line break inside the record prints escaped, so the record stays one line")
    func lineBreaksAreEscaped() {
        #expect(
            destination.line([pub("one\ntwo\r\nthree\0four")], at: .error)
                == #"<3>[app.kernova.agent:Clipboard] one\ntwo\r\nthree\0four"# + "\n")
    }

    @Test("Every level from info up is recorded, and debug is not")
    func threshold() {
        #expect(!destination.records(.debug))
        for level: KernovaLogLevel in [.info, .notice, .warning, .error, .fault] {
            #expect(destination.records(level))
        }
    }
}
#endif
