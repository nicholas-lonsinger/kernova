import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif
import KernovaSynchronization

/// A child process a test runs, whose every wait ends at a backstop and kills
/// it there.
///
/// Its standard output and error are each read on a thread of their own as it
/// writes them, so neither pipe fills and stalls it.
public final class ChildProcess: Sendable {
    /// How a child ended: its exit status and everything it wrote.
    public struct Exit: Sendable {
        /// Its exit status, or the signal that ended it.
        public let status: Int32
        /// Everything it wrote to standard output.
        public let output: Data
        /// Everything it wrote to standard error.
        public let errors: Data
    }

    private struct State: Sendable {
        var output = Data()
        var errors = Data()
        var outputEnded = false
        var errorsEnded = false
        var status: Int32?
        /// Why reading one of its pipes stopped short of the end.
        var readFailure: String?

        /// Whether it has exited and both of its pipes have ended.
        var ended: Bool { status != nil && outputEnded && errorsEnded }
    }

    /// The executable's name and its first argument, as its waits' failures
    /// give them.
    private let name: String
    private let processIdentifier: Int32
    private let state: Locked<State>
    private let changed: AsyncGate

    /// Starts `executable` with `arguments`, in `environment` when given and
    /// the test process's otherwise, writing `input` to its standard input
    /// and closing it — or giving it none when `input` is `nil`.
    public init(
        _ executable: URL, _ arguments: [String] = [], environment: [String: String]? = nil, input: Data? = nil
    ) throws {
        name = ([executable.lastPathComponent] + arguments.prefix(1)).joined(separator: " ")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let standardInput = input.map { _ in Pipe() }
        process.standardInput = standardInput ?? FileHandle.nullDevice
        let state = Locked(State())
        let changed = AsyncGate()
        process.terminationHandler = { process in
            let status = process.terminationStatus
            state.withLock { $0.status = status }
            changed.notify()
        }
        try process.run()
        processIdentifier = process.processIdentifier
        self.state = state
        self.changed = changed
        Self.drain(output.fileHandleForReading, state, changed) { state, chunk in
            if let chunk { state.output += chunk } else { state.outputEnded = true }
        }
        Self.drain(errors.fileHandleForReading, state, changed) { state, chunk in
            if let chunk { state.errors += chunk } else { state.errorsEnded = true }
        }
        if let standardInput, let input {
            try standardInput.fileHandleForWriting.write(contentsOf: input)
            try standardInput.fileHandleForWriting.close()
        }
    }

    /// How it ended, once it has exited and closed its standard output and
    /// error; kills it and throws `Backstop.failure(_:)` when it has not by
    /// the deadline, `timeout` seconds from now.
    ///
    /// A wait expecting the child to end takes the `testWaitBackstop` default;
    /// a shorter `timeout` is for a deadline the test asserts.
    public func exit(
        timeout: TimeInterval = testWaitBackstop, fileID: String = #fileID, line: Int = #line
    ) async throws -> Exit {
        do {
            try await changed.wait(named: "the exit of \(name)", timeout: timeout, fileID: fileID, line: line) {
                ended
            }
        } catch {
            kill()
            throw error
        }
        return try exited()
    }

    // periphery:ignore - used by the Linux-only test targets, which the dead-code scan does not build
    /// The first line it writes to standard output, without its line break,
    /// once written — or `nil` when its output ends first; kills it and throws
    /// `Backstop.failure(_:)` when neither has happened by the deadline.
    public func firstLine(fileID: String = #fileID, line: Int = #line) async throws -> String? {
        do {
            try await changed.wait(named: "the first line of \(name)", fileID: fileID, line: line) {
                state.withLock { $0.output.contains(UInt8(ascii: "\n")) || $0.outputEnded }
            }
        } catch {
            kill()
            throw error
        }
        return state.withLock { state in
            state.output.firstIndex(of: UInt8(ascii: "\n")).map {
                String(decoding: state.output[state.output.startIndex..<$0], as: UTF8.self)
            }
        }
    }

    /// Ends it now, unless it has already exited.
    public func kill() {
        guard state.withLock({ $0.status == nil }) else { return }
        #if canImport(WinSDK)
        guard let handle = OpenProcess(DWORD(PROCESS_TERMINATE), false, DWORD(processIdentifier)) else { return }
        TerminateProcess(handle, 1)
        CloseHandle(handle)
        #else
        // A process spawned from a Dispatch worker thread inherits the signals
        // that thread blocks, SIGTERM among them, so SIGKILL is what ends it.
        _ = Self.signal(processIdentifier, SIGKILL)
        #endif
    }

    private var ended: Bool { state.withLock(\.ended) }

    /// How it ended, once ``State/ended``; throws when reading a pipe failed.
    private func exited() throws -> Exit {
        try state.withLock { state in
            if let readFailure = state.readFailure {
                throw TestFailure("reading what \(name) wrote failed: \(readFailure)")
            }
            return Exit(status: state.status ?? -1, output: state.output, errors: state.errors)
        }
    }

    /// Reads `handle` to its end on a thread of its own, handing `take` each
    /// chunk and then `nil`.
    private static func drain(
        _ handle: FileHandle, _ state: Locked<State>, _ changed: AsyncGate,
        _ take: @escaping @Sendable (inout State, Data?) -> Void
    ) {
        Thread {
            while true {
                let chunk: Data?
                do {
                    chunk = try nextChunk(handle)
                } catch {
                    state.withLock { $0.readFailure = "\(error)" }
                    chunk = nil
                }
                state.withLock { take(&$0, chunk) }
                changed.notify()
                if chunk == nil { return }
            }
        }.start()
    }

    /// What `handle` holds once it holds anything, or `nil` at its end.
    ///
    /// `FileHandle.read(upToCount:)` returns only once it has read the count
    /// or reached the end, so a line a child writes before it goes on
    /// running would wait for it to exit.
    private static func nextChunk(_ handle: FileHandle) throws -> Data? {
        #if canImport(WinSDK)
        let data = handle.availableData
        return data.isEmpty ? nil : data
        #else
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                #if canImport(Darwin)
                Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
                #elseif canImport(Glibc)
                Glibc.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
                #else
                Musl.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
                #endif
            }
            if count > 0 { return Data(buffer[0..<count]) }
            if count == 0 { return nil }
            guard errno == EINTR else { throw TestFailure("read(2) failed with errno \(errno)") }
        }
        #endif
    }

    #if !canImport(WinSDK)
    private static func signal(_ process: Int32, _ signal: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.kill(process, signal)
        #elseif canImport(Glibc)
        Glibc.kill(process, signal)
        #else
        Musl.kill(process, signal)
        #endif
    }
    #endif
}
