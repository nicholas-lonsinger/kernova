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
    @Suite("LogRing and §7.1's record bounds")
    struct LogRingUnitTests {
        @Test("Capacity is 256: an append to a full ring evicts the oldest and counts it")
        func evictsOldest() {
            var ring = LogRing()
            for stamp in 0..<300 { ring.append(Unit.record(stamp: Int64(stamp))) }
            #expect(ring.count == 256)
            #expect(ring.droppedCount == 44)
            let batch = ring.takeBatch()
            #expect(batch?.records.first?.timestampMilliseconds == 44)
            #expect(batch?.droppedBefore == 44)
        }

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

        @Test("takeBatch removes at most 64 records, oldest first, and resets the dropped count")
        func batchRecordBound() {
            var ring = LogRing()
            for stamp in 0..<100 { ring.append(Unit.record(stamp: Int64(stamp))) }
            let first = ring.takeBatch()
            #expect(first?.records.map(\.timestampMilliseconds) == (0..<64).map { Int64($0) })
            #expect(first?.droppedBefore == 0)
            let second = ring.takeBatch()
            #expect(second?.records.map(\.timestampMilliseconds) == (64..<100).map { Int64($0) })
            #expect(ring.takeBatch() == nil)
        }

        @Test("takeBatch keeps the encoded batch within 61,440 bytes, so it fits a 64 KiB message")
        func batchByteBound() {
            var ring = LogRing()
            for stamp in 0..<20 { ring.append(Unit.record(String(repeating: "y", count: 16_384), stamp: Int64(stamp))) }
            var taken = 0
            while let batch = ring.takeBatch() {
                #expect(batch.encoded.count <= LogRing.batchBytes)
                #expect(!batch.records.isEmpty)
                taken += batch.records.count
            }
            #expect(taken == 20)
        }

        @Test("One record always fits, whatever the byte bound")
        func oneRecordAlwaysFits() {
            var ring = LogRing()
            ring.append(Unit.record(String(repeating: "z", count: 1_000)))
            ring.append(Unit.record())
            #expect(ring.takeBatch(maxRecords: 64, maxEncodedBytes: 10)?.records.count == 1)
        }

        @Test("The dropped count rides the next batch only")
        func droppedRidesNextBatch() {
            var ring = LogRing()
            for _ in 0..<257 { ring.append(Unit.record()) }
            #expect(ring.takeBatch()?.droppedBefore == 1)
            #expect(ring.takeBatch()?.droppedBefore == 0)
        }

        // MARK: §7.1

        @Test("Subsystem and category are clipped to 128 UTF-8 bytes on a scalar boundary")
        func labelBounds() {
            let record = LogRecordValue(
                timestampMilliseconds: 0, level: .info, subsystem: "a" + String(repeating: "é", count: 100),
                category: String(repeating: "c", count: 200), segments: [])
            #expect(record.subsystem.utf8.count == 127)
            #expect(record.subsystem.unicodeScalars.last == "é")
            #expect(record.category.utf8.count == 128)
            #expect(record.truncated)
        }

        @Test("Clipping either label alone sets truncated (§7.1)")
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

        @Test("At most 256 segments; cutting them sets truncated")
        func segmentBound() {
            let record = LogRecordValue(
                timestampMilliseconds: 0, level: .info, subsystem: "s", category: "c",
                segments: (0..<300).map { LogSegmentValue(text: "\($0)", isPrivate: $0 % 2 == 0) })
            #expect(record.segments.count == 256)
            #expect(record.segments.last == LogSegmentValue(text: "255", isPrivate: false))
            #expect(record.truncated)
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

        @Test("A record within every bound keeps its segments and its own truncated flag")
        func withinBounds() {
            let segments = [LogSegmentValue(text: "a"), LogSegmentValue(text: "b", isPrivate: true)]
            let plain = LogRecordValue(
                timestampMilliseconds: 7, level: .fault, subsystem: "s", category: "c", segments: segments)
            #expect(plain.segments == segments)
            #expect(!plain.truncated)
            let flagged = LogRecordValue(
                timestampMilliseconds: 7, level: .fault, subsystem: "s", category: "c", segments: segments,
                truncated: true)
            #expect(flagged.truncated)
        }
    }

    @Suite("LogForwarder: every row of §7.3")
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

        static func ends(_ frames: [Frame], _ stream: UInt32 = 1) -> Int {
            frames.on(stream).count { $0.type == .end }
        }

        static func batches(_ frames: [Frame], _ stream: UInt32 = 1) -> [Kernova_V2_LogBatch] {
            frames.on(stream).filter { $0.type == .data && $0.flags.contains(.message) }.compactMap {
                try? Kernova_V2_LogBatch(serializedBytes: $0.payload)
            }
        }

        // MARK: Policy

        @Test("Before the first PolicyUpdate LOGS is undecided: no mode, no stream")
        func undecided() {
            let run = Self.peer(logs: nil)
            #expect(Self.modes(run).isEmpty)
            #expect(Self.opens(run.written).isEmpty)
        }

        @Test("PolicyUpdate enables LOGS → mode forwarding and LOG_FORWARD opened with LogOpen{}")
        func enables() {
            let run = Self.peer(logs: true)
            #expect(Self.modes(run) == [.forwarding])
            #expect(Self.opens(run.written) == [1])
        }

        @Test("PolicyUpdate enables LOGS while it is not usable → mode forwarding, nothing opened")
        func enablesUnusable() {
            let run = Self.peer(logs: nil)
            run.feed([Unit.capabilities(withdrawing: .logs, reason: .notImplemented)])
            run.feed([Unit.policy(logs: true)])
            #expect(Self.modes(run) == [.forwarding])
            #expect(Self.opens(run.written).isEmpty)
        }

        @Test("PolicyUpdate disables LOGS → mode discarding, nothing opened")
        func disables() {
            let run = Self.peer(logs: false)
            #expect(Self.modes(run) == [.discarding])
            #expect(Self.opens(run.written).isEmpty)
        }

        @Test("PolicyUpdate disables LOGS with the stream open → mode discarding and END")
        func disablesOpen() {
            let run = Self.peer(logs: true)
            run.feed([Unit.policy(logs: false)])
            #expect(Self.modes(run) == [.forwarding, .discarding])
            #expect(Self.ends(run.written) == 1)
            #expect(run.written.on(1).last.map { $0.type == .end && $0.payload.isEmpty } == true)
        }

        @Test("A repeated enabling PolicyUpdate opens no second stream and repeats no mode")
        func repeatedPolicy() {
            let run = Self.peer(logs: true)
            run.feed([Unit.policy(logs: true)])
            #expect(Self.modes(run) == [.forwarding])
            #expect(Self.opens(run.written) == [1])
        }

        // MARK: Usability

        @Test("LOGS stops being usable → END the stream; the mode is unchanged")
        func usabilityLost() {
            let run = Self.peer(logs: true)
            run.feed([Unit.capabilities(withdrawing: .logs, reason: .notImplemented)])
            #expect(Self.ends(run.written) == 1)
            #expect(Self.modes(run) == [.forwarding])
        }

        @Test("host END after the peer's END completes the stream; it reopens once LOGS is usable again")
        func reopensAfterHostEnd() {
            let run = Self.peer(logs: true)
            run.feed([Unit.capabilities(withdrawing: .logs, reason: .notImplemented)])
            run.feed([Unit.end(1)])
            #expect(Self.opens(run.written) == [1])
            run.feed([Unit.capabilities()])
            #expect(Self.opens(run.written) == [1, 3])
        }

        @Test("host END after a disabling policy's END: re-enabling reopens")
        func reopensAfterPolicyFlip() {
            let run = Self.peer(logs: true)
            run.feed([Unit.policy(logs: false), Unit.end(1)])
            run.feed([Unit.policy(logs: true)])
            #expect(Self.modes(run) == [.forwarding, .discarding, .forwarding])
            #expect(Self.opens(run.written) == [1, 3])
        }

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

        @Test("host RESET → the next policy change reopens")
        func resetWaitsForPolicyChange() {
            let run = Self.peer(logs: true)
            run.feed([WireFrames.reset(1, code: ErrorCode.cancelled.rawValue)])
            run.feed([Unit.policy(logs: false)])
            #expect(Self.opens(run.written) == [1])
            run.feed([Unit.policy(logs: true)])
            #expect(Self.opens(run.written) == [1, 3])
        }

        @Test("host RESET DISABLED_BY_POLICY under a policy that enables LOGS → reopens at once")
        func disabledResetUnderEnabledPolicyReopens() {
            // The host coalesced LOGS off-then-on into one enabling PolicyUpdate, already
            // read here, while the RESET its off-policy caused still follows (§3.5).
            let run = Self.peer(logs: true)
            run.feed([WireFrames.reset(1, code: ErrorCode.disabledByPolicy.rawValue)])
            #expect(Self.opens(run.written) == [1, 3])
        }

        @Test("host RESET DISABLED_BY_POLICY under a policy that disables LOGS → no reopen until it enables")
        func disabledResetUnderDisabledPolicyWaits() {
            let run = Self.peer(logs: true)
            run.feed([Unit.policy(logs: false), WireFrames.reset(1, code: ErrorCode.disabledByPolicy.rawValue)])
            #expect(Self.opens(run.written) == [1])
            run.feed([Unit.policy(logs: true)])
            #expect(Self.opens(run.written) == [1, 3])
        }

        // MARK: Ready and batches

        @Test("The stream open with credit for a whole batch and records maybe waiting → .ready once")
        func readyOnOpen() {
            let run = Self.peer(logs: true)
            #expect(Self.readies(run) == 1)
            run.feed([WireFrames.window(1, 70_000)])
            #expect(Self.readies(run) == 1)
        }

        @Test(".recordsAvailable re-checks: with the stream sendable it asks for a batch again")
        func recordsAvailable() {
            let run = Self.peer(logs: true)
            run.input(.logs(.recordsAvailable))
            #expect(Self.readies(run) == 2)
            run.input(.logs(.recordsAvailable))
            #expect(Self.readies(run) == 3)
        }

        @Test("Before the stream opens, .recordsAvailable asks for nothing")
        func recordsAvailableUndecided() {
            let run = Self.peer(logs: nil)
            run.input(.logs(.recordsAvailable))
            #expect(Self.readies(run) == 0)
            run.feed([Unit.policy(logs: true)])
            #expect(Self.readies(run) == 1)
        }

        @Test("input .batch → one LogBatch message on the stream, and the next .ready while credit lasts")
        func batchSent() {
            let run = Self.peer(logs: true)
            let batch = LogBatchValue(records: [Unit.record("one"), Unit.record("two")], droppedBefore: 3)
            run.input(.logs(.batch(batch)))
            let sent = Self.batches(run.written)
            #expect(sent.count == 1)
            #expect(sent.first?.droppedBefore == 3)
            #expect(sent.first?.records.map { $0.segments.first?.text } == ["one", "two"])
            #expect(Self.readies(run) == 2)
        }

        @Test("Below 61,440 bytes of stream credit there is no .ready; credit back to a whole batch asks again")
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

        @Test("A batch still unsent holds the next .ready until it is handed out")
        func readyWaitsForUnsentMessage() {
            let run = Self.peer(logs: true)
            run.writerStalled = true
            run.input(.logs(.batch(LogBatchValue(records: [Unit.record()], droppedBefore: 0))))
            #expect(Self.readies(run) == 1)
            run.writerStalled = false
            run.drain()
            #expect(Self.batches(run.written).count == 1)
            #expect(Self.readies(run) == 2)
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

        @Test("A batch after the stream ended sends nothing")
        func batchAfterEnd() {
            let run = Self.peer(logs: true)
            run.feed([Unit.policy(logs: false)])
            run.input(.logs(.batch(LogBatchValue(records: [Unit.record()], droppedBefore: 0))))
            #expect(Self.batches(run.written).isEmpty)
        }
    }

    @Suite("LogReceiver: every row of §7.4")
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

        @Test("A batch with dropped_before > 0 → .dropped(n) first, then .records")
        func droppedFirst() {
            let run = Self.host()
            run.feed([Self.batch([Self.protoRecord("a"), Self.protoRecord("b")], dropped: 9)])
            let expected = LogRecordValue(
                timestampMilliseconds: 5, level: .error, subsystem: "sub", category: "cat",
                segments: [LogSegmentValue(text: "a")])
            #expect(Self.deliveries(run).count == 2)
            #expect(Self.deliveries(run).first == .dropped(9))
            guard case .records(let records) = Self.deliveries(run).last else {
                Issue.record("no records delivered")
                return
            }
            #expect(records.first == expected)
            #expect(records.map { $0.segments.first?.text } == ["a", "b"])
        }

        @Test("A batch with nothing dropped → .records only; a drop report alone → .dropped only")
        func recordsOnlyAndDroppedOnly() {
            let run = Self.host()
            run.feed([Self.batch([Self.protoRecord()])])
            run.feed([Self.batch([], dropped: 4)])
            #expect(Self.deliveries(run).count == 2)
            #expect(Self.deliveries(run).last == .dropped(4))
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

        @Test("Received strings are bounded again as §7.1")
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

        @Test("A LogBatch that does not decode → RESET MALFORMED_MESSAGE")
        func malformed() {
            let run = Self.host()
            run.feed([Unit.rawMessage(1, Data([0xFF, 0xFF, 0xFF]))])
            #expect(run.streamResets.map(\.code) == [.malformedMessage])
            #expect(Self.deliveries(run).isEmpty)
        }

        @Test("A second LOG_FORWARD while one is open → RESET STREAM_PROTOCOL_ERROR (§3.6 step 5)")
        func secondStreamRefused() {
            let run = Self.host()
            run.feed([WireFrames.open(3, .logForward, body: Kernova_V2_LogOpen())])
            #expect(run.streamResets.map(\.stream) == [3])
            #expect(run.streamResets.map(\.code) == [.streamProtocolError])
            run.feed([Self.batch([Self.protoRecord()])])
            #expect(Self.deliveries(run).count == 1)
        }

        @Test("On the peer's END the receiver sends END; it never opens anything")
        func endAnswered() {
            let run = Self.host()
            run.feed([Self.batch([Self.protoRecord()]), Unit.end(1)])
            #expect(run.written.on(1).filter { $0.type == .end }.count == 1)
            #expect(run.written.filter { $0.type == .open }.isEmpty)
        }

        @Test("Policy turning LOGS off while the stream is open → RESET DISABLED_BY_POLICY (§3.7)")
        func policyOff() {
            let run = Self.host()
            run.command(.setPolicy(PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: false)])))
            #expect(run.streamResets.map(\.code) == [.disabledByPolicy])
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
