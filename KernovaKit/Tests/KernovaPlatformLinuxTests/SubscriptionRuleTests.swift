#if os(Linux)
import KernovaDBus
import KernovaPlatformLinux
import KernovaPortableTestSupport
import Testing

@Suite("Subscriptions register and remove their rules with the bus", .offTaskWaitsReported)
struct SubscriptionRuleTests {
    /// The next message written, as its member and its first string argument.
    static func next(_ transport: RecordingTransport) async throws -> String {
        let message = try await transport.written.next()
        let argument = (try? message.decodeBody().first?.string()) ?? ""
        let reply = message.header.flags.contains(.noReplyExpected) ? " (no reply)" : ""
        return "\(message.header.member ?? "") \(argument)\(reply)"
    }

    @Test("cancel() writes RemoveMatch for its rule, and for the owner rule once its name's last subscriber is gone")
    func removeMatch() async throws {
        let transport = RecordingTransport()
        var connection: DBusBusConnection? = try DBusBusConnection(transport: transport, uid: 0) { _ in }
        #expect(try await Self.next(transport) == "Hello ")
        let rule = BusConnectionTests.tickRule
        let ownerRule = DBusMatchRule(
            sender: DBusBus.name, path: DBusBus.path, interface: DBusBus.interface, member: "NameOwnerChanged",
            arg0: BusConnectionTests.serviceName)

        let first = try #require(connection).subscribe(rule) { _ in }
        #expect(try await Self.next(transport) == "AddMatch \(ownerRule.text)")
        #expect(try await Self.next(transport) == "GetNameOwner \(BusConnectionTests.serviceName)")
        #expect(try await Self.next(transport) == "AddMatch \(rule.text)")
        let second = try #require(connection).subscribe(rule) { _ in }
        #expect(try await Self.next(transport) == "AddMatch \(rule.text)")

        first.cancel()
        #expect(try await Self.next(transport) == "RemoveMatch \(rule.text) (no reply)")
        first.cancel()
        second.cancel()
        #expect(try await Self.next(transport) == "RemoveMatch \(rule.text) (no reply)")
        #expect(try await Self.next(transport) == "RemoveMatch \(ownerRule.text) (no reply)")
        // Its last reference gone, the connection ends, writing nothing more.
        connection = nil
        #expect(transport.written.isEmpty)
    }
}
#endif
