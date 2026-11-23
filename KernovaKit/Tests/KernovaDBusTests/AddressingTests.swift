import KernovaDBus
import Testing

@Suite("Names, addresses and match rules")
struct AddressingTests {
    static let names: [(DBusNameKind, String, Bool)] = [
        (.interface, "org.freedesktop.login1.Manager", true),
        (.interface, "org._7_zip.Plugin", true),
        (.interface, "org", false),
        (.interface, "org.7zip", false),
        (.interface, "org..x", false),
        (.interface, ".org.x", false),
        (.interface, "org.x.", false),
        (.interface, "org.my-app", false),
        (.interface, "org." + String(repeating: "a", count: 251), true),
        (.interface, "org." + String(repeating: "a", count: 252), false),
        (.error, "org.freedesktop.DBus.Error.Failed", true),
        (.error, "Failed", false),
        (.member, "PowerOff", true),
        (.member, "_x9", true),
        (.member, "9x", false),
        (.member, "a.b", false),
        (.member, "", false),
        (.bus, "org.freedesktop.login1", true),
        (.bus, "org.my-app.x", true),
        (.bus, ":1.42", true),
        (.bus, ":1.7-a", true),
        (.bus, "org.7x", false),
        (.bus, "org", false),
        (.bus, ":1", false),
        (.bus, ".org.x", false),
        (.bus, "org.x y", false),
    ]

    @Test("Names follow their kind's rules", arguments: names)
    func nameRules(kind: DBusNameKind, name: String, isValid: Bool) {
        #expect(kind.isValid(name) == isValid)
    }

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

    @Test("A match rule matches on every key it names, the sender by its current owner")
    func ruleMatching() throws {
        let signal = try #require(
            try DBusReceivedMessage.decode(fromBus(sampleMessages[3], serial: 3, sender: ":1.5")))
        let rule = DBusMatchRule(
            sender: "org.freedesktop.login1", path: "/org/freedesktop/login1/session/_32",
            interface: "org.freedesktop.DBus.Properties", member: "PropertiesChanged",
            arg0: "org.freedesktop.login1.Session")
        #expect(rule.matches(signal, senderOwner: ":1.5"))
        #expect(!rule.matches(signal, senderOwner: ":1.6"))
        #expect(!rule.matches(signal, senderOwner: nil))

        var otherArgument = rule
        otherArgument.arg0 = "org.freedesktop.login1.User"
        #expect(!otherArgument.matches(signal, senderOwner: ":1.5"))
        var otherPath = rule
        otherPath.path = "/org/freedesktop/login1/session/_33"
        #expect(!otherPath.matches(signal, senderOwner: ":1.5"))
        var otherKind = rule
        otherKind.kind = .methodCall
        #expect(!otherKind.matches(signal, senderOwner: ":1.5"))
        var otherInterface = rule
        otherInterface.interface = "org.freedesktop.login1.Session"
        #expect(!otherInterface.matches(signal, senderOwner: ":1.5"))
        var otherMember = rule
        otherMember.member = "Lock"
        #expect(!otherMember.matches(signal, senderOwner: ":1.5"))
        #expect(DBusMatchRule().matches(signal, senderOwner: nil))

        // arg0 needs a string first argument.
        let reply = try #require(try DBusReceivedMessage.decode(fromBus(sampleMessages[1], serial: 4)))
        #expect(!DBusMatchRule(kind: nil, arg0: "x").matches(reply, senderOwner: nil))
    }
}
