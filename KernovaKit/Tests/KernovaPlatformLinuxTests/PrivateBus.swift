#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import Foundation
import KernovaDBus
import KernovaPlatformLinux

/// A private session bus: a `dbus-daemon` of its own, stopped on deinit.
final class PrivateBus {
    let address: String
    private let process: Process

    init() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // An abstract socket leaves nothing in the file system once the
        // daemon is gone.
        process.arguments = [
            "dbus-daemon", "--session", "--nofork", "--print-address=1",
            "--address=unix:abstract=/kernova/tests/\(UUID().uuidString)",
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        // This process's copies of the write ends, closed so a daemon that
        // exits without printing reads as end of file.
        try output.fileHandleForWriting.close()
        try errors.fileHandleForWriting.close()
        // read(2) returns as soon as the daemon prints its address; the daemon
        // holds the pipe open for as long as it runs.
        var printed: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 512)
        while !printed.contains(UInt8(ascii: "\n")) {
            let count = chunk.withUnsafeMutableBytes {
                read(output.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count)
            }
            guard count > 0 else {
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                throw PrivateBusError.exitedEarly(message)
            }
            printed += chunk[0..<count]
        }
        address = String(decoding: printed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        self.process = process
    }

    /// Kills the daemon now, closing every connection to it.
    func killDaemon() {
        Self.stop(process)
    }

    deinit {
        // A process spawned from a Dispatch worker thread inherits the signals
        // that thread blocks, SIGTERM among them, so SIGKILL is what ends it.
        Self.stop(process)
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }

    /// A connection to this bus.
    func connect(onMethodCall: (@Sendable (DBusReceivedMessage) -> DBusMessage?)? = nil) throws -> DBusBusConnection {
        try DBusBusConnection(address: address, onMethodCall: onMethodCall)
    }
}

enum PrivateBusError: Error {
    case exitedEarly(String)
    case notPrimaryOwner
    case backstopElapsed
}

/// Values a handler on another thread delivers, read in order.
final class Inbox<Value: Sendable>: @unchecked Sendable {
    /// How long `next()` waits before failing the test. Nothing a passing test
    /// waits for takes more than milliseconds; this only bounds a failure.
    static var backstop: TimeInterval { 30 }

    private let condition = NSCondition()
    /// Read and written only while `condition` is locked.
    private var values: [Value] = []

    func put(_ value: Value) {
        condition.lock()
        values.append(value)
        condition.broadcast()
        condition.unlock()
    }

    /// Whether every value delivered so far has been read.
    var isEmpty: Bool {
        condition.lock()
        defer { condition.unlock() }
        return values.isEmpty
    }

    /// The oldest value not yet read, waiting for one to arrive.
    func next() throws -> Value {
        let deadline = Date(timeIntervalSinceNow: Self.backstop)
        condition.lock()
        defer { condition.unlock() }
        while values.isEmpty {
            guard condition.wait(until: deadline) || !values.isEmpty else { throw PrivateBusError.backstopElapsed }
        }
        return values.removeFirst()
    }
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
