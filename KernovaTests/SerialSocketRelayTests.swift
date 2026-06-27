import Darwin
import Foundation
import Testing

@testable import Kernova

/// Exercises `SerialSocketRelay` against real AF_UNIX sockets: the relay binds a
/// listener under the temp dir, a test "client" socket connects to it, and a
/// `Pipe` stands in for the guest serial input.
@MainActor
@Suite("SerialSocketRelay")
struct SerialSocketRelayTests {
    // RATIONALE: Every `waitUntil` in this suite stays a poll rather than
    // `waitForChange`/`AsyncGate` (see CLAUDE.md "Async waits in tests"). The only
    // two signals are a kernel socket/pipe becoming readable (`readChunk`) and
    // `relay.hasClientForTesting`, which `SerialSocketRelay` (`@unchecked Sendable`,
    // not `@Observable`) flips on its private background GCD queue under `NSLock`.
    // Neither is an `@Observable` property nor a test-owned recorder, so making them
    // event-driven would require adding a seam to production code, out of scope here.

    // MARK: - Helpers

    private func tempSocketPath() -> String {
        let short = UUID().uuidString.prefix(8).lowercased()
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("knv-t-\(short).sock")
    }

    /// Connects a non-blocking AF_UNIX client to `path` and returns its fd.
    private func connectClient(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestFailure("client socket() failed: errno \(errno)") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { dst in
                for i in 0..<bytes.count { dst[i] = CChar(bitPattern: bytes[i]) }
                dst[bytes.count] = 0
            }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            close(fd)
            throw TestFailure("client connect() failed: errno \(errno)")
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        return fd
    }

    /// Single non-blocking read.
    ///
    /// `nil` = EAGAIN (no data yet), empty `Data` = EOF, non-empty = bytes read.
    private func readChunk(_ fd: Int32) -> Data? {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if n > 0 { return Data(buf[0..<n]) }
        if n == 0 { return Data() }
        return nil
    }

    // MARK: - Output (guest → client)

    @Test("guest output reaches a connected client")
    func outputReachesClient() async throws {
        let pipe = Pipe()
        let path = tempSocketPath()
        let relay = SerialSocketRelay(
            path: path, guestInputWriteHandle: pipe.fileHandleForWriting, label: "test")
        relay.start()
        defer { relay.stop() }
        #expect(relay.socketPath == path)

        let client = try connectClient(to: path)
        defer { close(client) }
        try await waitUntil { relay.hasClientForTesting }

        relay.forwardOutput(Data("hello".utf8))

        var received = Data()
        try await waitUntil {
            if let chunk = readChunk(client), !chunk.isEmpty { received.append(chunk) }
            return received == Data("hello".utf8)
        }
        #expect(received == Data("hello".utf8))
    }

    @Test("forwardOutput with no client connected is a safe no-op")
    func forwardOutputNoClient() async throws {
        let pipe = Pipe()
        let relay = SerialSocketRelay(
            path: tempSocketPath(), guestInputWriteHandle: pipe.fileHandleForWriting, label: "test")
        relay.start()
        defer { relay.stop() }
        relay.forwardOutput(Data("ignored".utf8))  // must not crash or block
        #expect(relay.hasClientForTesting == false)
    }

    // MARK: - Input (client → guest)

    @Test("client input reaches the guest input pipe")
    func clientInputReachesGuest() async throws {
        let pipe = Pipe()
        // Non-blocking read end so the test can poll without stalling MainActor.
        let readFd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(readFd, F_GETFL, 0)
        _ = fcntl(readFd, F_SETFL, flags | O_NONBLOCK)

        let path = tempSocketPath()
        let relay = SerialSocketRelay(
            path: path, guestInputWriteHandle: pipe.fileHandleForWriting, label: "test")
        relay.start()
        defer { relay.stop() }

        let client = try connectClient(to: path)
        defer { close(client) }
        try await waitUntil { relay.hasClientForTesting }

        let payload = Data("typed".utf8)
        _ = payload.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }

        var received = Data()
        try await waitUntil {
            if let chunk = readChunk(readFd), !chunk.isEmpty { received.append(chunk) }
            return received == payload
        }
        #expect(received == payload)
    }

    // MARK: - Client policy

    @Test("a second client supersedes the first")
    func secondClientSupersedesFirst() async throws {
        let pipe = Pipe()
        let path = tempSocketPath()
        let relay = SerialSocketRelay(
            path: path, guestInputWriteHandle: pipe.fileHandleForWriting, label: "test")
        relay.start()
        defer { relay.stop() }

        let clientA = try connectClient(to: path)
        defer { close(clientA) }
        try await waitUntil { relay.hasClientForTesting }

        let clientB = try connectClient(to: path)
        defer { close(clientB) }

        // A is closed by the relay on supersede → its read side observes EOF.
        try await waitUntil { readChunk(clientA) == Data() }

        relay.forwardOutput(Data("forB".utf8))
        var received = Data()
        try await waitUntil {
            if let chunk = readChunk(clientB), !chunk.isEmpty { received.append(chunk) }
            return received == Data("forB".utf8)
        }
        #expect(received == Data("forB".utf8))
    }

    @Test("listener survives a client disconnect and accepts a reconnect")
    func reconnectAfterDisconnect() async throws {
        let pipe = Pipe()
        let path = tempSocketPath()
        let relay = SerialSocketRelay(
            path: path, guestInputWriteHandle: pipe.fileHandleForWriting, label: "test")
        relay.start()
        defer { relay.stop() }

        let first = try connectClient(to: path)
        try await waitUntil { relay.hasClientForTesting }
        close(first)
        try await waitUntil { relay.hasClientForTesting == false }

        let second = try connectClient(to: path)
        defer { close(second) }
        try await waitUntil { relay.hasClientForTesting }

        relay.forwardOutput(Data("again".utf8))
        var received = Data()
        try await waitUntil {
            if let chunk = readChunk(second), !chunk.isEmpty { received.append(chunk) }
            return received == Data("again".utf8)
        }
        #expect(received == Data("again".utf8))
    }

    // MARK: - Lifecycle / path

    @Test("stop unlinks the socket file")
    func stopUnlinksSocketFile() {
        let pipe = Pipe()
        let path = tempSocketPath()
        let relay = SerialSocketRelay(
            path: path, guestInputWriteHandle: pipe.fileHandleForWriting, label: "test")
        relay.start()
        #expect(FileManager.default.fileExists(atPath: path))
        relay.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(relay.socketPath == nil)
    }

    @Test("an over-long path disables the relay without crashing")
    func lengthGuardDisablesRelay() {
        let pipe = Pipe()
        let longPath =
            (NSTemporaryDirectory() as NSString).appendingPathComponent(
                String(repeating: "x", count: 200) + ".sock")
        let relay = SerialSocketRelay(
            path: longPath, guestInputWriteHandle: pipe.fileHandleForWriting, label: "test")
        relay.start()
        #expect(relay.socketPath == nil)
        #expect(!FileManager.default.fileExists(atPath: longPath))
        relay.stop()
    }

    @Test("start and stop are idempotent")
    func startStopIdempotent() {
        let pipe = Pipe()
        let path = tempSocketPath()
        let relay = SerialSocketRelay(
            path: path, guestInputWriteHandle: pipe.fileHandleForWriting, label: "test")
        relay.start()
        relay.start()  // second start is a no-op
        #expect(relay.socketPath == path)
        relay.stop()
        relay.stop()  // second stop is a no-op
        #expect(relay.socketPath == nil)
    }

    @Test("VMInstance.serialSocketPath(for:) is short enough to bind")
    func generatedPathFitsSunPath() {
        let path = VMInstance.serialSocketPath(for: UUID())
        // sockaddr_un.sun_path caps at 104 bytes including the NUL terminator.
        #expect(path.utf8.count + 1 <= 104)
    }
}
