#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@testable import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire
import SwiftProtobuf
import Testing

extension Unit {
    static func record(_ text: String = "hello", stamp: Int64 = 1) -> LogRecordValue {
        LogRecordValue(
            timestampMilliseconds: stamp, level: .notice, subsystem: "app.kernova.agent", category: "test",
            segments: [LogSegmentValue(text: text)])
    }

    /// A batch whose encoded size is just under 61,440 bytes.
    static var nearlyFullBatch: LogBatchValue {
        LogBatchValue(
            records: (0..<4).map { record(String(repeating: "x", count: 15_000), stamp: $0) }, droppedBefore: 0)
    }
}

extension CoreUnits {
    @Suite("LogRing and the log record bounds")
    struct LogRingUnitTests {
        @Test("append reports true only into an empty ring, when the sink posts .recordsAvailable")
        func appendReportsEmpty() {
            var ring = LogRing()
            var intoEmpty = [ring.append(Unit.record()), ring.append(Unit.record())]
            _ = ring.takeBatch()
            intoEmpty.append(ring.append(Unit.record()))
            #expect(intoEmpty == [true, false, true])
        }

        @Test("The ring starts buffering; forwarding keeps what it holds; discarding refuses appends and empties it")
        func modes() {
            var ring = LogRing()
            #expect(ring.mode == .buffering)
            for _ in 0..<300 { ring.append(Unit.record()) }
            ring.setMode(.forwarding)
            #expect(ring.count == 256)
            ring.setMode(.discarding)
            #expect(ring.count == 0)
            #expect(ring.droppedCount == 0)
            let accepted = ring.append(Unit.record())
            #expect(!accepted)
            #expect(ring.count == 0)
            #expect(ring.takeBatch() == nil)
            ring.setMode(.forwarding)
            ring.append(Unit.record())
            #expect(ring.count == 1)
        }

        @Test("One record always fits, whatever the byte bound")
        func oneRecordAlwaysFits() {
            var ring = LogRing()
            ring.append(Unit.record(String(repeating: "z", count: 1_000)))
            ring.append(Unit.record())
            #expect(ring.takeBatch(maxRecords: 64, maxEncodedBytes: 10)?.records.count == 1)
        }

        // MARK: Record bounds

        @Test("Clipping either label alone sets truncated")
        func labelCutSetsTruncated() {
            let subsystem = LogRecordValue(
                timestampMilliseconds: 0, level: .info, subsystem: String(repeating: "s", count: 129), category: "c",
                segments: [])
            let category = LogRecordValue(
                timestampMilliseconds: 0, level: .info, subsystem: "s", category: String(repeating: "c", count: 129),
                segments: [])
            let exact = LogRecordValue(
                timestampMilliseconds: 0, level: .info, subsystem: String(repeating: "s", count: 128),
                category: String(repeating: "c", count: 128), segments: [])
            #expect(subsystem.truncated)
            #expect(category.truncated)
            #expect(!exact.truncated)
        }

        @Test("Segment text is cut to 16,384 UTF-8 bytes in total on a scalar boundary, setting truncated")
        func textBound() {
            let record = LogRecordValue(
                timestampMilliseconds: 0, level: .info, subsystem: "s", category: "c",
                segments: [
                    LogSegmentValue(text: String(repeating: "a", count: 16_000)),
                    LogSegmentValue(text: "b" + String(repeating: "€", count: 200), isPrivate: true),
                ])
            let total = record.segments.reduce(0) { $0 + $1.text.utf8.count }
            #expect(total == 16_000 + 1 + 3 * 127)
            #expect(record.segments.last?.isPrivate == true)
            #expect(record.truncated)
        }
    }

    @Suite("LogForwarder")
    struct LogForwarderUnitTests {
        /// A real session peer with the host's Hello read and, unless nil, a first policy.
        static func peer(logs: Bool? = true) -> HostileRun {
            let run = HostileRun(local: .peer, seed: 5)
            run.feed([WireFrames.hello(role: .host)], preamble: true)
            if let logs { run.feed([Unit.policy(logs: logs)]) }
            return run
        }

        static func logEffects(_ run: HostileRun) -> [LogEffect] {
            run.peerEffects.compactMap { if case .logs(let effect) = $0 { effect } else { nil } }
        }

        static func modes(_ run: HostileRun) -> [LogRingMode] {
            logEffects(run).compactMap { if case .mode(let mode) = $0 { mode } else { nil } }
        }

        static func readies(_ run: HostileRun) -> Int {
            logEffects(run).count { $0 == .ready }
        }

        /// The streams the peer opened LOG_FORWARD on, with each OPEN's body.
        static func opens(_ frames: [Frame]) -> [UInt32] {
            frames.filter { $0.type == .open }.compactMap { frame in
                guard let open = try? Kernova_V2_Open(serializedBytes: frame.payload), open.kind == .logForward,
                    (try? Kernova_V2_LogOpen(serializedBytes: open.body)) != nil
                else { return nil }
                return frame.streamID.rawValue
            }
        }

        static func batches(_ frames: [Frame], _ stream: UInt32 = 1) -> [Kernova_V2_LogBatch] {
            frames.on(stream).filter { $0.type == .data && $0.flags.contains(.message) }.compactMap {
                try? Kernova_V2_LogBatch(serializedBytes: $0.payload)
            }
        }

        // MARK: Usability

        @Test(
            "An unprompted host END is out of grammar: RESET STREAM_PROTOCOL_ERROR, no reopen until a change (as built)"
        )
        func unpromptedHostEnd() {
            let run = Self.peer(logs: true)
            run.feed([Unit.end(1)])
            #expect(run.streamResets.map(\.code) == [.streamProtocolError])
            #expect(Self.opens(run.written) == [1])
            run.feed([Unit.policy(logs: true)])
            #expect(Self.opens(run.written) == [1])
        }

        @Test("host RESET → no reopen on a repeated policy; the next usability change reopens")
        func resetWaitsForUsabilityChange() {
            let run = Self.peer(logs: true)
            run.feed([WireFrames.reset(1, code: ErrorCode.cancelled.rawValue)])
            run.feed([Unit.policy(logs: true), Unit.capabilities()])
            #expect(Self.opens(run.written) == [1])
            run.feed([Unit.capabilities(withdrawing: .logs, reason: .notImplemented)])
            run.feed([Unit.capabilities()])
            #expect(Self.opens(run.written) == [1, 3])
        }

        // MARK: Ready and batches

        @Test(
            "Below 64 KiB of stream credit there is no .ready, even with a whole batch's worth; reaching 64 KiB asks again"
        )
        func readyWaitsForCredit() {
            let run = Self.peer(logs: true)
            let batch = Unit.nearlyFullBatch
            let size = batch.encoded.count
            #expect(size <= LogRing.batchBytes && size > 59_000)
            for _ in 0..<4 { run.input(.logs(.batch(batch))) }
            #expect(Self.batches(run.written).count == 4)
            #expect(Self.readies(run) == 4)
            let remaining = 262_144 - 4 * size
            #expect(remaining < LogRing.batchBytes)
            // Credit covering a whole batch but short of 64 KiB, where `.writable`
            // rises, does not ask yet; reaching 64 KiB does.
            run.feed([WireFrames.window(1, UInt32(LogRing.batchBytes - remaining))])
            #expect(Self.readies(run) == 4)
            run.feed([WireFrames.window(1, UInt32(65_536 - LogRing.batchBytes))])
            #expect(Self.readies(run) == 5)
        }

        @Test("An empty batch with nothing dropped sends nothing and asks for no other batch")
        func emptyBatch() {
            let run = Self.peer(logs: true)
            let asked = Self.readies(run)
            #expect(asked == 1)
            run.input(.logs(.batch(LogBatchValue(records: [], droppedBefore: 0))))
            #expect(Self.batches(run.written).isEmpty)
            #expect(Self.readies(run) == asked)
            run.input(.logs(.recordsAvailable))
            #expect(Self.readies(run) == asked + 1)
        }
    }

    @Suite("LogReceiver")
    struct LogReceiverUnitTests {
        /// A real host with an established session peer and LOG_FORWARD open on stream 1.
        static func host() -> HostileRun {
            let run = HostileRun(local: .host, seed: 13)
            run.feed([WireFrames.hello(role: .sessionPeer)], preamble: true)
            run.feed([WireFrames.open(1, .logForward, body: Kernova_V2_LogOpen())])
            return run
        }

        static func deliveries(_ run: HostileRun) -> [LogDelivery] {
            run.hostEvents.compactMap { if case .log(let delivery) = $0 { delivery } else { nil } }
        }

        static func violations(_ run: HostileRun) -> Int {
            run.hostEvents.count { if case .diagnostic(.remoteViolation) = $0 { true } else { false } }
        }

        static func protoRecord(_ text: String = "r", segments: Int = 1) -> Kernova_V2_LogRecord {
            var record = Kernova_V2_LogRecord()
            record.timestampMs = 5
            record.level = .error
            record.subsystem = "sub"
            record.category = "cat"
            record.segments = (0..<segments).map { _ in
                var segment = Kernova_V2_LogSegment()
                segment.text = text
                return segment
            }
            return record
        }

        static func batch(_ records: [Kernova_V2_LogRecord], dropped: UInt64 = 0) -> Frame {
            var batch = Kernova_V2_LogBatch()
            batch.records = records
            batch.droppedBefore = dropped
            return WireFrames.message(1, batch)
        }

        @Test("Records past 64 are dropped with a diagnostic")
        func recordBound() {
            let run = Self.host()
            run.feed([Self.batch((0..<70).map { Self.protoRecord("\($0)") })])
            guard case .records(let records) = Self.deliveries(run).last else {
                Issue.record("no records delivered")
                return
            }
            #expect(records.count == 64)
            #expect(records.last?.segments.first?.text == "63")
            #expect(Self.violations(run) == 1)
        }

        @Test("Segments past 256 are dropped with a diagnostic, the record marked truncated")
        func segmentBound() {
            let run = Self.host()
            run.feed([Self.batch([Self.protoRecord(segments: 300)])])
            guard case .records(let records) = Self.deliveries(run).last else {
                Issue.record("no records delivered")
                return
            }
            #expect(records.first?.segments.count == 256)
            #expect(records.first?.truncated == true)
            #expect(Self.violations(run) == 1)
        }

        @Test("Received strings are bounded again, as a record is when built")
        func receivedBounds() {
            let run = Self.host()
            var record = Self.protoRecord(String(repeating: "t", count: 20_000))
            record.subsystem = String(repeating: "s", count: 300)
            run.feed([Self.batch([record])])
            guard case .records(let records) = Self.deliveries(run).last else {
                Issue.record("no records delivered")
                return
            }
            #expect(records.first?.subsystem.utf8.count == 128)
            #expect(records.first?.segments.first?.text.utf8.count == 16_384)
            #expect(records.first?.truncated == true)
        }

        @Test("On the peer's END the receiver sends END; it never opens anything")
        func endAnswered() {
            let run = Self.host()
            run.feed([Self.batch([Self.protoRecord()]), Unit.end(1)])
            #expect(run.written.on(1).filter { $0.type == .end }.count == 1)
            #expect(run.written.filter { $0.type == .open }.isEmpty)
        }

        @Test("Credit returns within the 256 KiB burst at once, then at no more than 1 MiB/s")
        func creditReturnCapped() {
            let run = Self.host()
            var record = Self.protoRecord(String(repeating: "w", count: 15_000))
            record.segments += Array(repeating: record.segments[0], count: 3)
            let frame = Self.batch([record])
            let size = frame.payload.count
            #expect(size < 65_536 && size > 59_000)
            func returned(since mark: Int) -> Int {
                run.written(since: mark).on(1).filter { $0.type == .window }.reduce(0) {
                    $0 + Int(Unit.window($1.payload))
                }
            }
            let start = run.written.count
            run.feed(Array(repeating: frame, count: 4))
            #expect(returned(since: start) == 4 * size)
            let second = run.written.count
            run.feed(Array(repeating: frame, count: 4))
            #expect(returned(since: second) == 0)
            run.advance(.ms(100), step: .ms(5))
            let afterTenth = returned(since: second)
            #expect(afterTenth > 0)
            #expect(afterTenth <= 1_048_576 / 10 + 65_536)
            run.advance(.ms(900), step: .ms(5))
            #expect(returned(since: second) > 4 * size - 65_536)
            #expect(Self.deliveries(run).count == 8)
        }
    }
}
