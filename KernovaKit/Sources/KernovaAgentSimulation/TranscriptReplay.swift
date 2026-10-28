#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// A parsed transcript file (§10.5).
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
/// other role (§10.5): pinned bytes in, frozen fields of the current side's
/// frames compared, everything else skipped.
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
    private var produced: [String] = []
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

    /// Replays every line and checks the frozen frames, the events and the PING floor.
    package func run() {
        drain()
        for line in transcript.lines {
            switch line {
            case .wire(let time, let bytes):
                advance(to: time)
                receive(bytes)
            case .input(let time, let input):
                advance(to: time)
                apply(input)
            case .expect(let time, let spec):
                advance(to: time)
                match(spec, time: time)
            case .event(let time, let text):
                advance(to: time)
                matchEvent(text, time: time)
            }
        }
        advance(to: transcript.end)
        checkPingFloor()
    }

    /// Feeds the pinned bytes only up to `offset`, then ends the transport, and
    /// runs on to the transcript's end: what must hold is that every stream and
    /// the connection end exactly once.
    package func runCut(at offset: Int) {
        drain()
        var fed = 0
        var ended = false
        for line in transcript.lines {
            guard !ended else { break }
            switch line {
            case .wire(let time, let bytes):
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
            case .input(let time, let input):
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
        switch input {
        case .host(let command): host?.handle(command, now: instant)
        case .peer(let input): peer?.handle(input, now: instant)
        case .peerLogs: break
        }
        drain()
    }

    private func drain() {
        var progressed = true
        while progressed {
            progressed = false
            while let event = host?.pollEvent() {
                progressed = true
                if case .closed = event {
                    closedCount += 1
                    finishedAt = finishedAt ?? now
                }
                if let text = TranscriptEvents.describe(event) { events.append(text) }
                for command in source.answer(event) { host?.handle(command, now: instant) }
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
            if bytes.prefix(4) == WireConstants.preamble { produced.append("preamble") }
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
                    "s=\(id) DATA-TOTAL bytes=\(total.bytes) crc32c=\(FrozenFields.hex(Duet.bigEndian(total.crc.value)))"
                )
            }
            if let described = FrozenFields.describe(frame, kinds: kinds) { produced.append(described) }
        }
    }

    /// The next produced frozen frame equal to `spec`; extra frames are skipped.
    private func match(_ spec: String, time: UInt64) {
        while cursor < produced.count {
            defer { cursor += 1 }
            if produced[cursor] == spec { return }
        }
        failures.append("t=\(time): expected `\(spec)`; produced since: \(produced.suffix(4))")
    }

    private func matchEvent(_ text: String, time: UInt64) {
        while eventCursor < events.count {
            defer { eventCursor += 1 }
            if events[eventCursor] == text { return }
        }
        failures.append("t=\(time): expected event `\(text)`; emitted: \(events.suffix(4))")
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
