#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire
import SwiftProtobuf

/// A parsed transcript file.
package struct Transcript: Sendable {
    package enum Line: Sendable {
        /// The pinned side's bytes, fed at `time`.
        case wire(time: UInt64, bytes: Data)
        /// A frozen frame the current side must have sent by `time`.
        case expect(time: UInt64, spec: String)
        /// A scripted input to the current side.
        case input(time: UInt64, TranscriptInput)
        /// An event the current side must have emitted by `time`.
        case event(time: UInt64, text: String)
    }

    package var pinned: SimSide
    package var pinnedFixture: String
    package var currentFixture: String
    package var end: UInt64
    package var lines: [Line] = []

    package init(parsing text: String) throws(TranscriptError) {
        var pinned: SimSide?
        var pinnedFixture = ""
        var currentFixture = ""
        var end: UInt64 = 0
        var lines: [Line] = []
        for (number, raw) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let line =
                raw.split(separator: ";", maxSplits: 1).first.map {
                    String($0.drop { $0 == " " }.reversed().drop { $0 == " " }.reversed())
                } ?? ""
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = words.first else { continue }
            func field(_ name: String) -> String? {
                words.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) }
            }
            switch first {
            case "pinned":
                pinned = words.count > 1 && words[1] == "host" ? .host : .peer
                pinnedFixture = field("fixture") ?? ""
            case "current":
                currentFixture = field("fixture") ?? ""
            case "end":
                end = words.count > 1 ? UInt64(words[1]) ?? 0 : 0
            default:
                guard first.hasPrefix("t="), let time = UInt64(first.dropFirst(2)), words.count >= 2 else {
                    throw TranscriptError.malformed(line: number + 1, text: String(raw))
                }
                let rest = words.dropFirst(2).joined(separator: " ")
                switch words[1] {
                case "h>p", "p>h":
                    guard let bytes = Self.bytes(rest) else {
                        throw TranscriptError.malformed(line: number + 1, text: String(raw))
                    }
                    lines.append(.wire(time: time, bytes: bytes))
                case "expect":
                    lines.append(.expect(time: time, spec: words.dropFirst(3).joined(separator: " ")))
                case "in":
                    guard let input = TranscriptInput(text: rest) else {
                        throw TranscriptError.malformed(line: number + 1, text: String(raw))
                    }
                    lines.append(.input(time: time, input))
                case "ev":
                    lines.append(.event(time: time, text: rest))
                default:
                    throw TranscriptError.malformed(line: number + 1, text: String(raw))
                }
            }
        }
        guard let pinned else { throw TranscriptError.missingHeader }
        self.pinned = pinned
        self.pinnedFixture = pinnedFixture
        self.currentFixture = currentFixture
        self.end = end
        self.lines = lines
    }

    /// A wire line's bytes: hex, or a header then `@gen(seed=,size=,offset=,count=)`
    /// naming a slice of `SimPayload.content(size:tag:)`.
    static func bytes(_ text: String) -> Data? {
        let parts = text.split(separator: "@", maxSplits: 1)
        guard parts.count == 2, parts[1].hasPrefix("gen(") else { return FrozenFields.unhex(Substring(text)) }
        guard var header = FrozenFields.unhex(parts[0]) else { return nil }
        let arguments = parts[1].dropFirst(4).dropLast()
        var values: [String: Int] = [:]
        for pair in arguments.split(separator: ",") {
            let parts = pair.split(separator: "=")
            if parts.count == 2 { values[String(parts[0])] = Int(parts[1]) }
        }
        guard let seed = arguments.split(separator: ",").first?.split(separator: "=").last.flatMap({ UInt64($0) }),
            let size = values["size"], let offset = values["offset"], let count = values["count"]
        else { return nil }
        let content = SimPayload.content(size: offset + count, tag: seed)
        _ = size
        header.append(content[offset..<(offset + count)])
        return header
    }

    /// Every pinned byte in order, with the time each line's bytes are fed.
    package var pinnedBytes: [(time: UInt64, bytes: Data)] {
        lines.compactMap { line in
            if case .wire(let time, let bytes) = line { return (time, bytes) }
            return nil
        }
    }
}

package enum TranscriptError: Error, Equatable {
    case malformed(line: Int, text: String)
    case missingHeader
    case unknownFixture(String)
}

/// Replays a frozen transcript solo against the current implementation of the
/// other role: the pinned side's bytes in, the frozen fields of the current
/// side's frames compared. A strict frame must come exactly where the transcript
/// expects it and none may be left over; a tolerant one is skipped when not
/// expected next. Frames of non-frozen kinds are never compared.
package final class SoloReplay {
    let transcript: Transcript
    private var host: HostEndpoint?
    private var peer: PeerEndpoint?
    private var now: UInt64 = 0
    private var decoder = FrameDecoder()
    /// Reads the pinned side's bytes too, for the kinds of the streams it opens.
    private var pinnedDecoder = FrameDecoder()
    private var preambleSeen = false
    private var kinds: [UInt32: StreamKind] = [:]
    private var produced: [FrozenLine] = []
    private var cursor = 0
    private var events: [String] = []
    private var eventCursor = 0
    private var rawTotals: [UInt32: (bytes: Int, crc: CRC32C)] = [:]
    private var pings: [UInt64] = []
    package private(set) var failures: [String] = []
    package private(set) var trace: [ConnectionTrace] = []
    private var closedCount = 0
    private var source = FixturePayloadSource()
    private var finishedAt: UInt64?
    private var localFaults: [String] = []

    package init(_ transcript: Transcript) throws(TranscriptError) {
        self.transcript = transcript
        let start = CoreInstant(nanoseconds: Duet.base)
        let generation = ConnectionGeneration(rawValue: 1)
        switch transcript.pinned {
        case .peer:
            guard let configuration = TranscriptFixture.host(transcript.currentFixture) else {
                throw .unknownFixture(transcript.currentFixture)
            }
            host = HostEndpoint(configuration, generation: generation, now: start)
        case .host:
            guard let configuration = TranscriptFixture.peer(transcript.currentFixture) else {
                throw .unknownFixture(transcript.currentFixture)
            }
            peer = PeerEndpoint(configuration, generation: generation, now: start)
        }
    }

    var instant: CoreInstant { CoreInstant(nanoseconds: Duet.base + now * 1_000_000) }

    /// The lines in the order the duet ran them. A wire line carries the time its
    /// bytes were written, and the duet's hop delivers them a millisecond later; at
    /// one instant the duet delivers, then applies inputs, and the checks follow both.
    private var timeline: [(time: UInt64, line: Transcript.Line)] {
        let keyed = transcript.lines.enumerated().map { index, line -> (time: UInt64, rank: Int, index: Int) in
            switch line {
            case .wire(let time, _): (time + 1, 0, index)
            case .input(let time, _): (time, 1, index)
            case .expect(let time, _), .event(let time, _): (time, 2, index)
            }
        }
        return keyed.sorted { ($0.time, $0.rank, $0.index) < ($1.time, $1.rank, $1.index) }.map {
            ($0.time, transcript.lines[$0.index])
        }
    }

    /// Replays every line and checks the frozen frames, the events and the PING floor.
    package func run() {
        drain()
        for (time, line) in timeline {
            advance(to: time)
            switch line {
            case .wire(_, let bytes): receive(bytes)
            case .input(_, let input): apply(input)
            case .expect(_, let spec): match(spec, time: time)
            case .event(_, let text): matchEvent(text, time: time)
            }
        }
        advance(to: transcript.end)
        for line in produced[cursor...] where line.match == .strict {
            failures.append("produced `\(line.text)`, which the transcript does not expect")
        }
        for text in events[eventCursor...] {
            failures.append("emitted event `\(text)`, which the transcript does not expect")
        }
        checkPingFloor()
    }

    /// Feeds the pinned bytes only up to `offset`, then ends the transport, and
    /// runs on to the transcript's end: every stream and the connection must end
    /// exactly once, which the trace checker and the `.closed` count assert.
    package func runCut(at offset: Int) {
        drain()
        var fed = 0
        var ended = false
        for (time, line) in timeline {
            guard !ended else { break }
            switch line {
            case .wire(_, let bytes):
                advance(to: time)
                let take = min(bytes.count, offset - fed)
                if take > 0 { receive(Data(bytes.prefix(take))) }
                fed += take
                if fed >= offset {
                    host?.transportEnded(now: instant)
                    peer?.transportEnded(now: instant)
                    drain()
                    ended = true
                }
            case .input(_, let input):
                advance(to: time)
                apply(input)
            case .expect, .event:
                break
            }
        }
        if !ended {
            host?.transportEnded(now: instant)
            peer?.transportEnded(now: instant)
            drain()
        }
        advance(to: transcript.end + 2_000)
        for violation in TraceChecker.violations(trace) { failures.append("cut at \(offset): \(violation)") }
        if closedCount != 1 { failures.append("cut at \(offset): \(closedCount) .closed events") }
        if (host?.state ?? peer?.state) != .finished { failures.append("cut at \(offset): not finished") }
    }

    private func advance(to time: UInt64) {
        while true {
            let deadline = host?.nextDeadline ?? peer?.nextDeadline
            guard let deadline else { break }
            let ms = (deadline.nanoseconds - min(deadline.nanoseconds, Duet.base) + 999_999) / 1_000_000
            guard ms <= time else { break }
            now = max(now, ms)
            host?.handleTimeout(now: instant)
            peer?.handleTimeout(now: instant)
            drain()
            if host?.state == .finished || peer?.state == .finished { break }
        }
        now = max(now, time)
    }

    private func receive(_ bytes: Data) {
        pinnedDecoder.append(bytes)
        while let frame = try? pinnedDecoder.nextFrame() {
            if frame.type == .open, let open = try? Kernova_V2_Open(serializedBytes: frame.payload) {
                kinds[frame.streamID.rawValue] = open.kind
            }
        }
        host?.receive(bytes, now: instant)
        peer?.receive(bytes, now: instant)
        drain()
    }

    private func apply(_ input: TranscriptInput) {
        let faultsBefore = localFaults.count
        switch input {
        case .host(let command): host?.handle(command, now: instant)
        case .peer(let input): peer?.handle(input, now: instant)
        case .pull(let report):
            guard peer != nil else { break }
            guard let stream = kinds.filter({ $0.value == .updatePull && $0.key % 2 == 1 }).keys.max() else {
                failures.append("t=\(now): `\(input.text)` with no UPDATE_PULL opened")
                break
            }
            peer?.handle(
                report.input(UpdatePullID(generation: TranscriptInput.generation, stream: StreamID(rawValue: stream))),
                now: instant)
        case .peerLogs: break
        }
        drain()
        for fault in localFaults[faultsBefore...] {
            failures.append("t=\(now): `\(input.text)` raised a local fault: \(fault)")
        }
    }

    private func drain() {
        var progressed = true
        while progressed {
            progressed = false
            while let event = host?.pollEvent() {
                progressed = true
                if case .diagnostic(.localFault(let text)) = event { localFaults.append("host: \(text)") }
                if case .closed = event {
                    closedCount += 1
                    finishedAt = finishedAt ?? now
                }
                if let text = TranscriptEvents.describe(event) { events.append(text) }
            }
            while let effect = host?.pollEffect() {
                progressed = true
                host?.handle(source.answer(effect), now: instant)
            }
            while let effect = peer?.pollEffect() {
                progressed = true
                if let text = TranscriptEvents.describe(effect) { events.append(text) }
                if case .update(.payload(let id, let bytes)) = effect {
                    peer?.handle(.update(.consumed(id, bytes.count)), now: instant)
                }
            }
            while let event = peer?.pollEvent() {
                progressed = true
                if case .diagnostic(.localFault(let text)) = event { localFaults.append("peer: \(text)") }
                if case .closed = event {
                    closedCount += 1
                    finishedAt = finishedAt ?? now
                }
                if let text = TranscriptEvents.describe(event) { events.append(text) }
            }
            while let transmit = host?.pollTransmit(maxBytes: 1 << 20 + 10)
                ?? peer?.pollTransmit(maxBytes: 1 << 20 + 10)
            {
                progressed = true
                written(transmit)
                if transmit.isFinal {
                    host?.finalTransmitWritten(now: instant)
                    peer?.finalTransmitWritten(now: instant)
                }
            }
        }
        trace += host?.takeTrace() ?? []
        trace += peer?.takeTrace() ?? []
    }

    private func written(_ transmit: Transmit) {
        var bytes = Data()
        for chunk in transmit.chunks { bytes.append(chunk) }
        if !preambleSeen {
            preambleSeen = true
            if bytes.prefix(4) == WireConstants.preamble { produced.append(FrozenLine("preamble")) }
        }
        decoder.append(bytes)
        while let frame = try? decoder.nextFrame() {
            let id = frame.streamID.rawValue
            if frame.type == .open, let open = try? Kernova_V2_Open(serializedBytes: frame.payload) {
                kinds[id] = open.kind
            }
            if frame.type == .ping { pings.append(now) }
            if frame.type == .data, !frame.flags.contains(.message) {
                var total = rawTotals[id] ?? (0, CRC32C())
                total.bytes += frame.payload.count
                total.crc.update(frame.payload)
                rawTotals[id] = total
            }
            if frame.type == .end, let total = rawTotals[id] {
                produced.append(
                    FrozenLine(
                        "s=\(id) DATA-TOTAL bytes=\(total.bytes) crc32c=\(FrozenFields.hex(Duet.bigEndian(total.crc.value)))"
                    ))
            }
            if let described = FrozenFields.describe(frame, kinds: kinds) { produced.append(described) }
        }
    }

    /// Consumes the next produced frozen frame, which must equal `spec`; only tolerant frames are skipped.
    private func match(_ spec: String, time: UInt64) {
        while cursor < produced.count {
            let line = produced[cursor]
            cursor += 1
            if line.text == spec { return }
            if line.match == .strict {
                failures.append("t=\(time): expected `\(spec)`; produced `\(line.text)`")
                return
            }
        }
        failures.append("t=\(time): expected `\(spec)`; produced nothing more")
    }

    /// Consumes the next emitted event, which must equal `text`: every event a
    /// transcript names reports a frozen frame's outcome, so none is skipped.
    private func matchEvent(_ text: String, time: UInt64) {
        guard eventCursor < events.count else {
            failures.append("t=\(time): expected event `\(text)`; emitted nothing more")
            return
        }
        let emitted = events[eventCursor]
        eventCursor += 1
        if emitted != text { failures.append("t=\(time): expected event `\(text)`; emitted `\(emitted)`") }
    }

    /// The frozen floor: a PING at least every 5 s from connect until the connection ends.
    private func checkPingFloor() {
        let end = finishedAt ?? transcript.end
        var last: UInt64 = 0
        for ping in pings + [end] {
            if ping > last + 5_000 { failures.append("no PING for \(ping - last) ms before t=\(ping)") }
            last = ping
        }
    }
}
