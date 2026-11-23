import Testing

@testable import KernovaLogging

@Suite("The standard-error line a record prints as")
struct StandardErrorLogLineTests {
    private let destination = StandardErrorLogDestination(subsystem: "app.kernova.agent", category: "Clipboard")

    private func pub(_ text: String) -> LogSegment {
        LogSegment(text: text, isPrivate: false)
    }

    private func priv(_ text: String) -> LogSegment {
        LogSegment(text: text, isPrivate: true)
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
}
