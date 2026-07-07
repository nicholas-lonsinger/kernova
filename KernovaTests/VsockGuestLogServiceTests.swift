import Testing
import Foundation
import Darwin
import KernovaKit
@testable import Kernova

@Suite("VsockGuestLogService")
@MainActor
struct VsockGuestLogServiceTests {
    // MARK: - Helpers

    private func makePair() throws -> (sender: VsockChannel, receiver: VsockChannel) {
        let (a, b) = try makeRawSocketPair()
        return (VsockChannel(fileDescriptor: a), VsockChannel(fileDescriptor: b))
    }

    // Event-driven: awaits the emitter's gate (fired on each `emit`) until at
    // least `count` records have arrived. The `timeout` is a backstop for a
    // genuinely stuck stream, not the success deadline — so a slow CI runner
    // no longer trips it.
    private func waitForRecords(
        _ emitter: RecordingEmitter,
        count: Int,
        timeout: Duration = .seconds(10)
    ) async throws {
        try await emitter.recorded.wait(timeout: timeout) {
            emitter.snapshot().count >= count
        }
    }

    private func makeLogFrame(
        level: Kernova_V1_LogRecord.Level,
        subsystem: String = "app.kernova.macosagent",
        category: String = "Test",
        message: String = "hello",
        timestampMs: Int64 = 1_700_000_000_000
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.logRecord = Kernova_V1_LogRecord.with {
            $0.timestampMs = timestampMs
            $0.level = level
            $0.subsystem = subsystem
            $0.category = category
            $0.message = message
        }
        return frame
    }

    // MARK: - Tests

    @Test("Forwards LogRecord frames to the emitter")
    func forwardsLogRecord() async throws {
        let emitter = RecordingEmitter()
        let (sender, receiver) = try makePair()
        sender.start()
        receiver.start()
        defer { sender.close() }

        let service = VsockGuestLogService(channel: receiver, label: "test", emitter: emitter)
        service.start()
        defer { service.stop() }

        try sender.send(makeLogFrame(level: .notice, message: "hello world"))
        try await waitForRecords(emitter, count: 1)

        let records = emitter.snapshot()
        #expect(records.count == 1)
        #expect(records.first?.message == "hello world")
        #expect(records.first?.level == .notice)
    }

    @Test("Forwards multiple LogRecord frames in order")
    func forwardsMultipleRecords() async throws {
        let emitter = RecordingEmitter()
        let (sender, receiver) = try makePair()
        sender.start()
        receiver.start()
        defer { sender.close() }

        let service = VsockGuestLogService(channel: receiver, label: "test", emitter: emitter)
        service.start()
        defer { service.stop() }

        for i in 1...4 {
            try sender.send(makeLogFrame(level: .info, message: "msg \(i)"))
        }
        try await waitForRecords(emitter, count: 4)

        let messages = emitter.snapshot().map(\.message)
        #expect(messages == ["msg 1", "msg 2", "msg 3", "msg 4"])
    }

    @Test("Hello and Error frames are not emitted as guest log records")
    func nonLogRecordFramesAreFiltered() async throws {
        let emitter = RecordingEmitter()
        let (sender, receiver) = try makePair()
        sender.start()
        receiver.start()
        defer { sender.close() }

        let service = VsockGuestLogService(channel: receiver, label: "test", emitter: emitter)
        service.start()
        defer { service.stop() }

        var hello = Frame()
        hello.protocolVersion = 1
        hello.hello = Kernova_V1_Hello.with { $0.serviceVersion = 1 }
        try sender.send(hello)

        var errorFrame = Frame()
        errorFrame.protocolVersion = 1
        errorFrame.error = Kernova_V1_Error.with {
            $0.code = "test.error"
            $0.message = "should be logged but not emitted"
        }
        try sender.send(errorFrame)

        // Send a real LogRecord afterwards so we can wait for it — that lets
        // us assert hello/error were processed by the time we check.
        try sender.send(makeLogFrame(level: .debug, message: "real record"))
        try await waitForRecords(emitter, count: 1)

        let records = emitter.snapshot()
        #expect(records.count == 1)
        #expect(records.first?.message == "real record")
    }

    @Test("All log levels round-trip with the correct enum value")
    func allLevelsRoundTrip() async throws {
        let emitter = RecordingEmitter()
        let (sender, receiver) = try makePair()
        sender.start()
        receiver.start()
        defer { sender.close() }

        let service = VsockGuestLogService(channel: receiver, label: "test", emitter: emitter)
        service.start()
        defer { service.stop() }

        let levels: [Kernova_V1_LogRecord.Level] =
            [.debug, .info, .notice, .warning, .error, .fault]
        for level in levels {
            try sender.send(makeLogFrame(level: level, message: String(describing: level)))
        }
        try await waitForRecords(emitter, count: levels.count)

        let receivedLevels = emitter.snapshot().map(\.level)
        #expect(receivedLevels == levels)
    }

    @Test("Service stops cleanly when remote end closes")
    func serviceStopsOnRemoteClose() async throws {
        let emitter = RecordingEmitter()
        let (sender, receiver) = try makePair()
        sender.start()
        receiver.start()

        let service = VsockGuestLogService(channel: receiver, label: "test", emitter: emitter)
        service.start()

        try sender.send(makeLogFrame(level: .info, message: "before close"))
        try await waitForRecords(emitter, count: 1)

        sender.close()

        // Wait briefly for the consumer to observe EOF and finish. No assert
        // beyond "test does not hang" — the deferred service.stop() must
        // remain safe to call after the channel has already finished.
        try await Task.sleep(for: .milliseconds(50))
        service.stop()

        #expect(emitter.snapshot().count == 1)
    }
}

// MARK: - Recording emitter

private final class RecordingEmitter: GuestLogEmitter, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Kernova_V1_LogRecord] = []

    /// Fires on every `emit`; await it instead of polling `snapshot().count`.
    let recorded = AsyncGate()

    func emit(_ record: Kernova_V1_LogRecord) {
        lock.lock()
        records.append(record)
        lock.unlock()
        recorded.notify()
    }

    func snapshot() -> [Kernova_V1_LogRecord] {
        lock.lock(); defer { lock.unlock() }
        return records
    }
}
