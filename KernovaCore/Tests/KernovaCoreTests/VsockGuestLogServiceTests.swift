import Foundation
import KernovaKit
import KernovaLogging
import KernovaSynchronization
import KernovaTestSupport
import SwiftProtobuf
import Synchronization
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VsockGuestLogService", .caseScoped)
@MainActor
struct VsockGuestLogServiceTests {
    // MARK: - Helpers

    private func makePair() throws -> (sender: VsockChannel, receiver: VsockChannel) {
        let (a, b) = try makeRawSocketPair()
        return (VsockChannel(fileDescriptor: a), VsockChannel(fileDescriptor: b))
    }

    // Event-driven: awaits the emitter's gate (fired on each `emit`) until at
    // least `count` records have arrived. The gate's stuck-stream backstop
    // bounds the wait, not a success deadline — so a slow CI runner no longer
    // trips it.
    private func waitForRecords(
        _ emitter: RecordingEmitter,
        count: Int
    ) async throws {
        try await emitter.recorded.wait {
            emitter.snapshot().count >= count
        }
    }

    private func makeSegment(_ text: String, isPrivate: Bool = false) -> Kernova_V1_LogSegment {
        Kernova_V1_LogSegment.with {
            $0.text = text
            $0.private = isPrivate
        }
    }

    /// The record's message whole, the way the host reassembles it.
    private func joinedText(_ record: Kernova_V1_LogRecord) -> String {
        record.segments.map(\.text).joined()
    }

    private func makeLogFrame(
        level: Kernova_V1_LogRecord.Level,
        subsystem: String = "app.kernova.macosagent",
        category: String = "Test",
        message: String = "hello",
        timestampMs: Int64 = 1_700_000_000_000
    ) -> Frame {
        makeLogFrame(
            level: level, subsystem: subsystem, category: category,
            segments: [makeSegment(message)], timestampMs: timestampMs)
    }

    private func makeLogFrame(
        level: Kernova_V1_LogRecord.Level,
        subsystem: String = "app.kernova.macosagent",
        category: String = "Test",
        segments: [Kernova_V1_LogSegment],
        timestampMs: Int64 = 1_700_000_000_000
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.logRecord = Kernova_V1_LogRecord.with {
            $0.timestampMs = timestampMs
            $0.level = level
            $0.subsystem = subsystem
            $0.category = category
            $0.segments = segments
        }
        return frame
    }

    // MARK: - Tests

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

        let messages = emitter.snapshot().map(joinedText)
        #expect(messages == ["msg 1", "msg 2", "msg 3", "msg 4"])
    }

    @Test("Error frames are logged but not emitted; the channel stays open")
    func errorFramesAreFilteredWithoutClosing() async throws {
        let emitter = RecordingEmitter()
        let (sender, receiver) = try makePair()
        sender.start()
        receiver.start()
        defer { sender.close() }

        let service = VsockGuestLogService(channel: receiver, label: "test", emitter: emitter)
        service.start()
        defer { service.stop() }

        var errorFrame = Frame()
        errorFrame.protocolVersion = 1
        errorFrame.error = Kernova_V1_Error.with {
            $0.code = "test.error"
            $0.message = "should be logged but not emitted"
        }
        try sender.send(errorFrame)

        // Send a real LogRecord afterwards so we can wait for it — that lets
        // us assert the error frame was processed (and didn't close the
        // channel) by the time we check.
        try sender.send(makeLogFrame(level: .debug, message: "real record"))
        try await waitForRecords(emitter, count: 1)

        let records = emitter.snapshot()
        #expect(records.count == 1)
        #expect(records.first.map(joinedText) == "real record")
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

    @Test("A record's per-segment privacy reaches the emitter intact")
    func privateSegmentsReachTheEmitter() async throws {
        let emitter = RecordingEmitter()
        let (sender, receiver) = try makePair()
        sender.start()
        receiver.start()
        defer { sender.close() }

        let service = VsockGuestLogService(channel: receiver, label: "test", emitter: emitter)
        service.start()
        defer { service.stop() }

        try sender.send(
            makeLogFrame(
                level: .notice,
                segments: [makeSegment("copied "), makeSegment("secret.txt", isPrivate: true)]))
        try await waitForRecords(emitter, count: 1)

        let segments = emitter.snapshot().first?.segments ?? []
        #expect(segments.map(\.text) == ["copied ", "secret.txt"])
        #expect(segments.map(\.private) == [false, true])
    }

    /// What an `OSLogGuestLogEmitter` hands its logger's sink for each record.
    private struct Emitted: Equatable {
        let level: KernovaLogLevel
        let subsystem: String
        let category: String
        let segments: [LogSegment]
    }

    /// An emitter whose logger captures through its own sink, labelled `vm`.
    private func makeCapturingEmitter() -> (OSLogGuestLogEmitter, Locked<[Emitted]>) {
        let emitted = Locked<[Emitted]>([])
        let logger = KernovaLogger(subsystem: "app.kernova.guest", category: "vm") {
            level, subsystem, category, segments in
            emitted.withLock {
                $0.append(Emitted(level: level, subsystem: subsystem, category: category, segments: segments))
            }
        }
        return (OSLogGuestLogEmitter(logger: logger), emitted)
    }

    private func logRecord(of frame: Frame) throws -> Kernova_V1_LogRecord {
        guard case .logRecord(let record) = frame.payload else {
            throw RecordMissing()
        }
        return record
    }

    private struct RecordMissing: Error {}

    @Test("The emitter republishes a record behind a public [subsystem/category] label")
    func emitterLabelsTheRecord() throws {
        let (emitter, emitted) = makeCapturingEmitter()

        let record = try logRecord(of: makeLogFrame(level: .notice, category: "Cat", message: "started"))
        emitter.emit(record)

        #expect(
            emitted.withLock { $0 } == [
                Emitted(
                    level: .notice, subsystem: "app.kernova.guest", category: "vm",
                    segments: [
                        LogSegment(text: "[app.kernova.macosagent/Cat] ", isPrivate: false),
                        LogSegment(text: "started", isPrivate: false),
                    ])
            ])
    }

    @Test("The emitter carries each guest segment's privacy through")
    func emitterKeepsSegmentPrivacy() throws {
        let (emitter, emitted) = makeCapturingEmitter()

        let record = try logRecord(
            of: makeLogFrame(
                level: .notice,
                category: "Cat",
                segments: [
                    makeSegment("copied "), makeSegment("secret.txt", isPrivate: true), makeSegment(" done"),
                ]))
        emitter.emit(record)

        #expect(
            emitted.withLock { $0.first?.segments } == [
                LogSegment(text: "[app.kernova.macosagent/Cat] ", isPrivate: false),
                LogSegment(text: "copied ", isPrivate: false),
                LogSegment(text: "secret.txt", isPrivate: true),
                LogSegment(text: " done", isPrivate: false),
            ])
    }

    @Test(
        "The emitter maps each guest level to the host level",
        arguments: [
            (Kernova_V1_LogRecord.Level.debug, KernovaLogLevel.debug),
            (.info, .info),
            (.notice, .notice),
            (.warning, .warning),
            (.error, .error),
            (.fault, .fault),
            (.unspecified, .notice),
            (.UNRECOGNIZED(99), .notice),
        ])
    func emitterMapsLevels(guest: Kernova_V1_LogRecord.Level, host: KernovaLogLevel) throws {
        let (emitter, emitted) = makeCapturingEmitter()

        let record = try logRecord(of: makeLogFrame(level: guest))
        emitter.emit(record)

        #expect(emitted.withLock { $0.map(\.level) } == [host])
    }

    @Test("A wrong-port payload notifies the owner that the channel is gone")
    func wrongPortPayloadNotifiesOwner() async throws {
        let emitter = RecordingEmitter()
        let (sender, receiver) = try makePair()
        sender.start()
        receiver.start()
        defer { sender.close() }

        let service = VsockGuestLogService(channel: receiver, label: "test", emitter: emitter)
        let lost = ChannelLostRecorder()
        service.onChannelLost = { lost.record() }
        service.start()
        defer { service.stop() }

        // The channel really is gone: the service closed it on the violation,
        // so the owner is owed the same notice a peer disconnect earns.
        var hello = Frame()
        hello.protocolVersion = 1
        hello.hello = Kernova_V1_Hello.with { $0.serviceVersion = 1 }
        try sender.send(hello)

        try await lost.changed.wait { lost.count == 1 }
        await expectEOF(on: sender)
        #expect(emitter.snapshot().isEmpty)
    }

    @Test("An owner stop() is terminal: a record still in flight is never emitted")
    func stopIsTerminalForRecordsInFlight() async throws {
        let emitter = RecordingEmitter()
        let (sender, receiver) = try makePair()
        sender.start()
        receiver.start()
        defer { sender.close() }

        let service = VsockGuestLogService(channel: receiver, label: "test", emitter: emitter)
        service.start()
        let tasks = service.lifecycleTasksForTesting
        // In flight at the teardown, at whichever stage the channel's GCD reader
        // reaches first: still on the socket, or already yielded into `incoming`
        // and buffered there. The consume task is `@MainActor` like this body, so
        // it cannot run before `stop()` either way — and `stop()` closes the
        // channel, which is what refuses a buffered frame to every consumer.
        try sender.send(makeLogFrame(level: .notice, message: "in flight"))
        service.stop()

        // Terminal, like the control service: a reconnect is served by a fresh
        // instance, so `start()` does not resume the closed channel.
        service.start()
        #expect(service.lifecycleTasksForTesting == tasks)

        // Only the consume task emits, so once it has ended nothing can.
        for task in tasks { await task.value }
        #expect(emitter.snapshot().isEmpty)
    }
}

// MARK: - Recording emitter

private final class RecordingEmitter: GuestLogEmitter {
    private let records = Mutex<[Kernova_V1_LogRecord]>([])

    /// Fires on every `emit`; await it instead of polling `snapshot().count`.
    let recorded = AsyncGate()

    func emit(_ record: Kernova_V1_LogRecord) {
        records.withLock { $0.append(record) }
        recorded.notify()
    }

    func snapshot() -> [Kernova_V1_LogRecord] {
        records.withLock { $0 }
    }
}
