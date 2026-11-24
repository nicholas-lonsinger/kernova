#if os(Linux)
import KernovaDBus
import KernovaPlatformLinux
import KernovaPortableTestSupport
import Testing

@Suite("A connection the bus ends tells its owner", .offTaskWaitsReported)
struct ConnectionEndTests {
    @Test("A message that does not decode ends the connection, calling the end handler with why")
    func undecodableMessage() async throws {
        let transport = RecordingTransport()
        let ends = BlockingInbox<DBusDisconnection>()
        let connection = try DBusBusConnection(transport: transport, uid: 0) { ends.put($0) }
        // A fixed header whose byte order is neither of the two the specification allows, `l` and `B`.
        transport.send([UInt8(ascii: "X")] + Array(repeating: 0, count: 15))
        #expect(try await ends.next() == .connection(.protocolViolation(.invalidByteOrder(UInt8(ascii: "X")))))
        withExtendedLifetime(connection) {}
    }
}
#endif
