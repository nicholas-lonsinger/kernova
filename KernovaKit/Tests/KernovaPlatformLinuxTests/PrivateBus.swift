#if os(Linux)
import Foundation
import KernovaDBus
import KernovaPlatformLinux
import KernovaPortableTestSupport
import Testing

/// A private session bus: a `dbus-daemon` of its own, stopped on deinit.
final class PrivateBus {
    let address: String
    private let daemon: ChildProcess

    init() throws {
        // An abstract socket leaves nothing in the file system once the
        // daemon is gone.
        daemon = try ChildProcess(
            URL(fileURLWithPath: "/usr/bin/env"),
            [
                "dbus-daemon", "--session", "--nofork", "--print-address=1",
                "--address=unix:abstract=/kernova/tests/\(UUID().uuidString)",
            ])
        // The daemon prints its address once it listens, and holds its
        // output open for as long as it runs.
        guard let address = try daemon.firstLine() else {
            throw PrivateBusError.exitedEarly(String(decoding: try daemon.exit().errors, as: UTF8.self))
        }
        self.address = address.trimmingCharacters(in: .whitespaces)
    }

    /// Kills the daemon now, closing every connection to it.
    func killDaemon() {
        Self.stop(daemon)
    }

    deinit {
        Self.stop(daemon)
    }

    private static func stop(_ daemon: ChildProcess) {
        daemon.kill()
        do {
            _ = try daemon.exit()
        } catch {
            Issue.record(error)
        }
    }

    /// A connection to this bus.
    func connect(onMethodCall: (@Sendable (DBusReceivedMessage) -> DBusMessage?)? = nil) throws -> DBusBusConnection {
        try DBusBusConnection(address: address, onMethodCall: onMethodCall)
    }
}

enum PrivateBusError: Error {
    case exitedEarly(String)
    case notPrimaryOwner
}

/// Asks the bus for `name` on `connection`, failing unless it becomes the
/// primary owner.
func requestName(_ name: String, on connection: DBusBusConnection) throws {
    let reply = try connection.call(
        .methodCall(
            destination: DBusBus.name, path: DBusBus.path, interface: DBusBus.interface, member: "RequestName",
            body: [.string(name), .uint32(0)]))
    // DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER.
    guard try reply.decodeBody(expecting: "u") == [.uint32(1)] else { throw PrivateBusError.notPrimaryOwner }
}

/// A round trip to the bus: everything `connection` sent before it has been
/// dispatched once it returns.
func sync(_ connection: DBusBusConnection) throws {
    _ = try connection.call(
        .methodCall(destination: DBusBus.name, path: DBusBus.path, interface: DBusBus.interface, member: "GetId"))
}
#endif
