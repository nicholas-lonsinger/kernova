import KernovaDBus
import Testing

@Suite("Bus addresses")
struct AddressingTests {
    @Test("Addresses parse into transports and unescaped values, in order")
    func parsesAddresses() throws {
        let addresses = try DBusAddress.parse(
            "unix:path=/run/user/1000/bus,guid=0123;unix:abstract=/tmp/dbus-x;tcp:host=127.0.0.1,port=4242")
        #expect(addresses.map(\.transport) == ["unix", "unix", "tcp"])
        #expect(addresses[0].parameters == ["path": "/run/user/1000/bus", "guid": "0123"])
        #expect(addresses[0].unixSocket == .path("/run/user/1000/bus"))
        #expect(addresses[1].unixSocket == .abstract("/tmp/dbus-x"))
        #expect(addresses[2].unixSocket == nil)
        #expect(try DBusAddress.parse("unix:dir=/tmp")[0].unixSocket == nil)
        #expect(try DBusAddress.parse("unix:path=/a%20b%2c%3b")[0].unixSocket == .path("/a b,;"))
        #expect(try DBusAddress.parse("unix:path=%2Fx")[0].unixSocket == .path("/x"))
        #expect(try DBusAddress.parse("").isEmpty)
    }
}
