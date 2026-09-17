import KernovaLogging
import KernovaTestSupport
import Testing

/// Proves the `LogWire.segment` overload set resolves the way the `#log`
/// expansion relies on: an unannotated interpolation must land on the wire with
/// the privacy `os.Logger` would have given it locally.
@Suite("LogWire default privacy", .admissionGated)
struct LogWireTests {
    private struct Point {
        let x: Int
    }

    @Test("Integers, floating-point values and Booleans default to public")
    func numericAndBooleanDefaultToPublic() {
        #expect(LogWire.segment(7) == LogSegment(text: "7", isPrivate: false))
        #expect(LogWire.segment(UInt8(3)) == LogSegment(text: "3", isPrivate: false))
        #expect(LogWire.segment(2.5) == LogSegment(text: "2.5", isPrivate: false))
        #expect(LogWire.segment(Float(1.5)) == LogSegment(text: "1.5", isPrivate: false))
        #expect(LogWire.segment(true) == LogSegment(text: "true", isPrivate: false))
    }

    @Test("Strings and other values default to private")
    func stringsAndObjectsDefaultToPrivate() {
        #expect(LogWire.segment("alice") == LogSegment(text: "alice", isPrivate: true))
        #expect(LogWire.segment(Point(x: 1)) == LogSegment(text: "Point(x: 1)", isPrivate: true))
    }

    @Test("An explicit privacy overrides the default in both directions")
    func explicitPrivacyWins() {
        #expect(LogWire.segment("alice", isPrivate: false) == LogSegment(text: "alice", isPrivate: false))
        #expect(LogWire.segment(7, isPrivate: true) == LogSegment(text: "7", isPrivate: true))
    }
}
