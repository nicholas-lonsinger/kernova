#if os(Linux)
import Foundation
import KernovaDBus
import KernovaPlatformLinux
import KernovaPortableTestSupport
import Testing

/// A private session bus: a `dbus-daemon` of its own, for the length of a ``with(_:)``.
final class PrivateBus {
    let address: String
    private let daemon: ChildProcess

    /// Starts a bus and runs `body` with it, then kills the daemon whether `body` returns or throws.
    static func with<T>(_ body: (PrivateBus) async throws -> T) async throws -> T {
        let bus = try await started()
        let outcome: Result<T, any Error>
        do {
            outcome = .success(try await body(bus))
        } catch {
            outcome = .failure(error)
        }
        await bus.killDaemon()
        return try outcome.get()
    }

    private init(address: String, daemon: ChildProcess) {
        self.address = address
        self.daemon = daemon
    }

    private static func started() async throws -> PrivateBus {
        // An abstract socket leaves nothing in the file system once the
        // daemon is gone.
        let daemon = try ChildProcess(
            URL(fileURLWithPath: "/usr/bin/env"),
            [
                "dbus-daemon", "--session", "--nofork", "--print-address=1",
                "--address=unix:abstract=/kernova/tests/\(UUID().uuidString)",
            ])
        // The daemon prints its address once it listens, and holds its
        // output open for as long as it runs.
        guard let address = try await daemon.firstLine() else {
            throw PrivateBusError.exitedEarly(String(decoding: try await daemon.exit().errors, as: UTF8.self))
        }
        return PrivateBus(address: address.trimmingCharacters(in: .whitespaces), daemon: daemon)
    }

    /// Kills the daemon and waits for it to end, closing every connection to it.
    func killDaemon() async {
        daemon.kill()
        do {
            _ = try await daemon.exit()
        } catch {
            Issue.record(error)
        }
    }

    /// A connection to this bus. Its end, at the latest when the daemon is killed, calls nothing.
    func connect(onMethodCall: (@Sendable (DBusReceivedMessage) -> DBusMessage?)? = nil) throws -> DBusBusConnection {
        try DBusBusConnection(address: address, onMethodCall: onMethodCall) { _ in }
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
