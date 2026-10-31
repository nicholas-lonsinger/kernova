#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaAgentSimulation
import KernovaWire
import SwiftProtobuf
import Testing

/// One hostile row: a real endpoint against a far side's raw bytes, each seed
/// splitting them differently.
struct HostileRow: Sendable, CustomTestStringConvertible {
    enum Outcome: Sendable, Equatable {
        /// The connection closes with this RESET(0) code.
        case fatal(ErrorCode)
        /// The connection closes with no RESET (the far side is not this protocol).
        case notThisProtocol
        /// The stream is reset with this code and the connection stays up.
        case streamReset(ErrorCode)
        /// The far side's RESET(0) reads as this code.
        case closedByPeer(ErrorCode)
        /// Nothing closes.
        case staysUp
    }

    var name: String
    var local: SimSide
    var testKinds = false
    var tweak: @Sendable (inout ConnectionConfiguration) -> Void = { _ in }
    var outcome: Outcome
    var script: @Sendable (HostileRun) -> Void
    var expect: @Sendable (HostileRun) -> [String] = { _ in [] }

    var testDescription: String { name }

    static let hostHello = WireFrames.hello(role: .host)
    static let peerHello = WireFrames.hello(role: .sessionPeer)
    /// The offer the update rows' peer pulls on stream 1.
    static let pulled = Unit.manifest(tag: 16, size: 20_000)

    /// The peer aborted the pull and recorded its hash rejected, once each.
    static func rejectedRecorded(_ run: HostileRun) -> [String] {
        let effects = run.peerEffects.compactMap { if case .update(let effect) = $0 { effect } else { nil } }
        let id = UpdatePullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 1))
        return effects.suffix(2) == [.abort(id), .recordRejected(pulled.payloadHash)] ? [] : ["effects: \(effects)"]
    }

    func run(seed: UInt64) -> [String] {
        let run = HostileRun(local: local, seed: seed, testKinds: testKinds, tweak: tweak)
        script(run)
        var failures = run.traceViolations + expect(run)
        let footprint = run.connectionFootprint
        if let footprint, footprint.controlFrames > 2 * 128 + 8 {
            failures.append("control frames \(footprint.controlFrames)")
        }
        switch outcome {
        case .fatal(let code):
            if run.localCloseCode != code {
                failures.append("expected a close with \(code), got \(String(describing: run.closure))")
            }
            let last = run.written.last
            if last?.type != .reset || last?.streamID != .session {
                failures.append("RESET(0) is not the last frame written")
            }
        case .notThisProtocol:
            if run.closure != .notThisProtocol {
                failures.append("expected no-RESET close, got \(String(describing: run.closure))")
            }
            if run.written.contains(where: { $0.type == .reset }) { failures.append("a RESET was written") }
        case .streamReset(let code):
            if run.closure != nil { failures.append("the connection closed: \(String(describing: run.closure))") }
            if !run.streamResets.contains(where: { $0.code == code }) {
                failures.append("expected a stream RESET \(code), wrote \(run.streamResets)")
            }
        case .closedByPeer(let code):
            guard case .closedByPeer(let error) = run.closure, error.code == code else {
                failures.append("expected the far side's close read as \(code), got \(String(describing: run.closure))")
                break
            }
        case .staysUp:
            if run.closure != nil { failures.append("the connection closed: \(String(describing: run.closure))") }
        }
        return failures
    }
}

enum HostileRows {
    static func power(_ stream: UInt32, _ stage: Kernova_V2_PowerProgress.Stage) -> Frame {
        var progress = Kernova_V2_PowerProgress()
        progress.stage = stage
        return WireFrames.message(stream, progress)
    }

    static let fatalRows: [HostileRow] = [
        HostileRow(name: "bad preamble", local: .host, outcome: .notThisProtocol) { run in
            run.feed(Data([0, 0, 0, 40]) + WireFrames.bytes([HostileRow.peerHello], preamble: false))
        },
        HostileRow(name: "unknown frame type", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(WireFrames.bytes([HostileRow.peerHello]) + Data([0, 0, 0, 0, 6, 0, 0, 0, 0, 0]))
        },
        HostileRow(name: "undefined flag bit", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(WireFrames.bytes([HostileRow.peerHello]) + Data([0, 0, 0, 0, 5, 2, 0, 0, 0, 8]) + Data(count: 8))
        },
        HostileRow(name: "MESSAGE flag on PING", local: .peer, outcome: .fatal(.protocolError)) { run in
            run.feed(WireFrames.bytes([HostileRow.hostHello]) + Data([0, 0, 0, 0, 5, 1, 0, 0, 0, 8]) + Data(count: 8))
        },
        HostileRow(name: "payload over the type's maximum", local: .host, outcome: .fatal(.frameTooLarge)) { run in
            run.feed(WireFrames.bytes([HostileRow.peerHello]) + Data([0, 0, 0, 0, 1, 0, 0, 1, 0, 1]))
        },
        HostileRow(name: "WINDOW of the wrong length", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(WireFrames.bytes([HostileRow.peerHello]) + Data([0, 0, 0, 0, 4, 0, 0, 0, 0, 3, 1, 1, 1]))
        },
        HostileRow(name: "PING over the control maximum", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(WireFrames.bytes([HostileRow.peerHello]) + Data([0, 0, 0, 0, 5, 0, 0, 2, 0, 0]))
        },
        HostileRow(name: "empty raw DATA", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(WireFrames.bytes([HostileRow.peerHello]) + Data([0, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
        },
        HostileRow(name: "first frame not a Hello", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(WireFrames.bytes([WireFrames.ping(), HostileRow.peerHello]))
        },
        HostileRow(name: "a second Hello", local: .peer, outcome: .fatal(.protocolError)) { run in
            run.feed(WireFrames.bytes([HostileRow.hostHello, HostileRow.hostHello]))
        },
        HostileRow(name: "stream-0 payload not a SessionMessage", local: .host, outcome: .fatal(.protocolError)) {
            run in
            run.feed(
                WireFrames.bytes([
                    HostileRow.peerHello,
                    Frame(streamID: .session, type: .data, flags: .message, payload: Data([0xFF, 0xFF, 0xFF])),
                ]))
        },
        HostileRow(name: "host refuses a HOST Hello", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(WireFrames.bytes([WireFrames.hello(role: .host)]))
        },
        HostileRow(name: "peer refuses a peer Hello", local: .peer, outcome: .fatal(.protocolError)) { run in
            run.feed(WireFrames.bytes([WireFrames.hello(role: .systemPeer, scope: .system)]))
        },
        HostileRow(name: "system peer with USER scope", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(WireFrames.bytes([WireFrames.hello(role: .systemPeer, scope: .user)]))
        },
        HostileRow(name: "session peer without a session id", local: .host, outcome: .fatal(.protocolError)) {
            run in
            run.feed(WireFrames.bytes([WireFrames.hello(role: .sessionPeer, sessionID: "\u{200B}")]))
        },
        HostileRow(name: "peer sends a PolicyUpdate", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(
                WireFrames.bytes([HostileRow.peerHello, WireFrames.session { $0.policy = Kernova_V2_PolicyUpdate() }]))
        },
        HostileRow(name: "peer sends an UpdateAvailable", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(
                WireFrames.bytes([
                    HostileRow.peerHello, WireFrames.session { $0.updateAvailable = Kernova_V2_UpdateAvailable() },
                ]))
        },
        HostileRow(name: "host sends a PeerState", local: .peer, outcome: .fatal(.protocolError)) { run in
            run.feed(
                WireFrames.bytes([HostileRow.hostHello, WireFrames.session { $0.peerState = Kernova_V2_PeerState() }]))
        },
        HostileRow(name: "session id changes", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(
                WireFrames.bytes([
                    HostileRow.peerHello, WireFrames.session { $0.peerState.sessionID = "other" },
                ]))
        },
        HostileRow(name: "OPEN on stream 0", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(
                WireFrames.bytes([HostileRow.peerHello, WireFrames.open(0, .logForward, body: Kernova_V2_LogOpen())]))
        },
        HostileRow(name: "END on stream 0", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(WireFrames.bytes([HostileRow.peerHello, Frame(streamID: .session, type: .end)]))
        },
        HostileRow(name: "raw DATA on stream 0", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(
                WireFrames.bytes([HostileRow.peerHello, Frame(streamID: .session, type: .data, payload: Data([1]))]))
        },
        HostileRow(name: "PING on stream 1", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(
                WireFrames.bytes([
                    HostileRow.peerHello, WireFrames.open(1, .logForward, body: Kernova_V2_LogOpen()),
                    Frame(streamID: StreamID(rawValue: 1), type: .ping, payload: Data(count: 8)),
                ]))
        },
        HostileRow(name: "OPEN with the wrong parity", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(
                WireFrames.bytes([HostileRow.peerHello, WireFrames.open(2, .logForward, body: Kernova_V2_LogOpen())]))
        },
        HostileRow(name: "OPEN not above the last", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(
                WireFrames.bytes([
                    HostileRow.peerHello, WireFrames.open(5, .logForward, body: Kernova_V2_LogOpen()),
                    WireFrames.open(3, .updatePull, body: Kernova_V2_UpdatePull()),
                ]))
        },
        HostileRow(name: "DATA on a never-opened stream", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(
                WireFrames.bytes([
                    HostileRow.peerHello, Frame(streamID: StreamID(rawValue: 7), type: .data, payload: Data([1])),
                ]))
        },
        HostileRow(
            name: "WINDOW on a never-opened stream of this side", local: .host, outcome: .fatal(.protocolError)
        ) {
            run in
            run.feed(WireFrames.bytes([HostileRow.peerHello, WireFrames.window(2, 100)]))
        },
        HostileRow(name: "RESET on a never-opened stream", local: .peer, outcome: .fatal(.protocolError)) { run in
            run.feed(WireFrames.bytes([HostileRow.hostHello, WireFrames.reset(1, code: 50)]))
        },
        HostileRow(
            name: "MESSAGE DATA beyond the stream's credit", local: .host, outcome: .fatal(.flowControlError)
        ) {
            run in
            var batch = Kernova_V2_LogBatch()
            var record = Kernova_V2_LogRecord()
            record.segments = [Kernova_V2_LogSegment()]
            record.segments[0].text = String(repeating: "x", count: 60_000)
            batch.records = [record]
            let message = WireFrames.message(1, batch)
            run.feed(
                WireFrames.bytes(
                    [HostileRow.peerHello, WireFrames.open(1, .logForward, body: Kernova_V2_LogOpen())]
                        + Array(repeating: message, count: 12)))
        },
        HostileRow(
            name: "raw DATA beyond the stream's credit", local: .peer, testKinds: true,
            outcome: .fatal(.flowControlError)
        ) { run in
            run.feed(WireFrames.bytes([HostileRow.hostHello]))
            _ = run.openTestBulk(.UNRECOGNIZED(9000), consumes: false)
            let chunk = Frame(streamID: StreamID(rawValue: 1), type: .data, payload: Data(count: 1 << 20))
            run.feed(WireFrames.bytes(Array(repeating: chunk, count: 9), preamble: false), maxSplit: 1 << 20)
        },
        HostileRow(
            name: "raw DATA beyond the connection's credit", local: .peer, testKinds: true,
            outcome: .fatal(.flowControlError)
        ) { run in
            run.feed(WireFrames.bytes([HostileRow.hostHello]))
            for _ in 0..<3 { _ = run.openTestBulk(.UNRECOGNIZED(9000), consumes: false) }
            var frames: [Frame] = []
            for stream: UInt32 in [1, 3] {
                frames += Array(
                    repeating: Frame(streamID: StreamID(rawValue: stream), type: .data, payload: Data(count: 1 << 20)),
                    count: 8)
            }
            frames.append(Frame(streamID: StreamID(rawValue: 5), type: .data, payload: Data([1])))
            run.feed(WireFrames.bytes(frames, preamble: false), maxSplit: 1 << 20)
        },
        HostileRow(name: "WINDOW past 2^31-1", local: .host, outcome: .fatal(.flowControlError)) { run in
            run.feed(WireFrames.bytes([HostileRow.peerHello, WireFrames.window(0, 0x7FFF_FFFF)]))
        },
        HostileRow(name: "WINDOW of 0", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(WireFrames.bytes([HostileRow.peerHello, WireFrames.window(0, 0)]))
        },
        HostileRow(name: "no Hello within the timeout", local: .host, outcome: .fatal(.helloTimeout)) { run in
            run.feed(WireConstants.preamble)
            run.advance(.sec(13))
        },
        HostileRow(name: "silence past the close threshold", local: .peer, outcome: .fatal(.livenessExpired)) {
            run in
            run.feed(WireFrames.bytes([HostileRow.hostHello]))
            run.advance(.sec(33))
        },
        HostileRow(
            name: "stream ids exhausted", local: .peer, testKinds: true,
            tweak: { $0.firstLocalStreamID = UInt64(UInt32.max) }, outcome: .fatal(.streamIdsExhausted)
        ) { run in
            run.feed(WireFrames.bytes([HostileRow.hostHello]))
            _ = run.openTestBulk(.UNRECOGNIZED(9000), consumes: true)
            _ = run.openTestBulk(.UNRECOGNIZED(9000), consumes: true)
        },
        HostileRow(
            name: "RESET(0) with an unknown code reads INTERNAL", local: .peer, outcome: .closedByPeer(.internal)
        ) {
            run in
            run.feed(WireFrames.bytes([HostileRow.hostHello, WireFrames.reset(0, code: 77)]))
        },
        HostileRow(name: "RESET(0) as the first frame closes", local: .peer, outcome: .closedByPeer(.shuttingDown)) {
            run in
            run.feed(WireFrames.bytes([WireFrames.reset(0, code: 6)]))
        },
        HostileRow(name: "OPEN flood past twice the limit", local: .host, outcome: .fatal(.protocolError)) { run in
            run.feed(WireFrames.bytes([HostileRow.peerHello]))
            run.writerStalled = true
            let opens = (0..<130).map {
                WireFrames.open(UInt32(2 * $0 + 1), .UNRECOGNIZED(4242), body: Kernova_V2_LogOpen())
            }
            run.feed(WireFrames.bytes(opens, preamble: false))
            run.writerStalled = false
            run.drain()
        },
    ]

    static let streamRows: [HostileRow] = [
        HostileRow(name: "unknown kind → UNSUPPORTED_KIND", local: .host, outcome: .streamReset(.unsupportedKind)) {
            run in
            run.feed(
                WireFrames.bytes([
                    HostileRow.peerHello, WireFrames.open(1, .UNRECOGNIZED(4242), body: Kernova_V2_LogOpen()),
                ]))
        },
        HostileRow(
            name: "a kind the opener's role never opens", local: .host, outcome: .streamReset(.unsupportedKind)
        ) {
            run in
            run.feed(
                WireFrames.bytes([
                    HostileRow.peerHello, WireFrames.open(1, .powerRequest, body: Kernova_V2_PowerRequest()),
                ]))
        },
        HostileRow(
            name: "an OPEN body that does not decode", local: .peer, outcome: .streamReset(.malformedMessage)
        ) {
            run in
            var open = Kernova_V2_Open()
            open.kind = .powerRequest
            open.body = Data([0xFF, 0xFF])
            run.feed(
                WireFrames.bytes([
                    HostileRow.hostHello,
                    Frame(
                        streamID: StreamID(rawValue: 2), type: .open, payload: (try? open.serializedBytes()) ?? Data()),
                ]))
        },
        HostileRow(name: "a second LOG_FORWARD", local: .host, outcome: .streamReset(.streamProtocolError)) {
            run in
            run.feed(
                WireFrames.bytes([
                    HostileRow.peerHello, WireFrames.open(1, .logForward, body: Kernova_V2_LogOpen()),
                    WireFrames.open(3, .logForward, body: Kernova_V2_LogOpen()),
                ]))
        },
        HostileRow(
            name: "a second UPDATE_PULL → UPDATE_IN_PROGRESS", local: .host,
            outcome: .streamReset(.updateInProgress)
        ) {
            run in
            var pull = Kernova_V2_UpdatePull()
            pull.payloadHash = SimHub.tagHash(1)
            run.feed(
                WireFrames.bytes([
                    WireFrames.hello(role: .sessionPeer, payloadHash: Data(repeating: 1, count: 32)),
                    WireFrames.open(1, .updatePull, body: pull), WireFrames.open(3, .updatePull, body: pull),
                ]))
        },
        HostileRow(name: "OPEN past the OPEN rate", local: .host, outcome: .streamReset(.tooManyStreams)) { run in
            run.feed(WireFrames.bytes([HostileRow.peerHello]))
            let opens = (0..<70).flatMap { index -> [Frame] in
                let stream = UInt32(2 * index + 1)
                return [WireFrames.open(stream, .logForward, body: Kernova_V2_LogOpen())]
            }
            run.feed(WireFrames.bytes(opens, preamble: false))
        },
        HostileRow(name: "a message that does not decode", local: .host, outcome: .streamReset(.malformedMessage)) {
            run in
            run.feed(
                WireFrames.bytes([
                    HostileRow.peerHello, WireFrames.open(1, .logForward, body: Kernova_V2_LogOpen()),
                    Frame(streamID: StreamID(rawValue: 1), type: .data, flags: .message, payload: Data([0xFF, 0xFF])),
                ]))
        },
        HostileRow(name: "raw DATA the kind forbids", local: .host, outcome: .streamReset(.streamProtocolError)) {
            run in
            run.feed(
                WireFrames.bytes([
                    HostileRow.peerHello, WireFrames.open(1, .logForward, body: Kernova_V2_LogOpen()),
                    Frame(streamID: StreamID(rawValue: 1), type: .data, payload: Data([1, 2, 3])),
                ]))
        },
        HostileRow(
            name: "a message on a direction that carries nothing", local: .peer,
            outcome: .streamReset(.streamProtocolError)
        ) {
            run in
            var request = Kernova_V2_PowerRequest()
            request.action = .shutdown
            request.acceptanceDeadlineMs = 10_000
            run.feed(
                WireFrames.bytes([
                    HostileRow.hostHello, WireFrames.open(2, .powerRequest, body: request),
                    WireFrames.message(2, Kernova_V2_PowerProgress()),
                ]))
        },
        HostileRow(name: "progress out of order", local: .host, outcome: .streamReset(.streamProtocolError)) {
            run in
            run.feed(WireFrames.bytes([HostileRow.peerHello]))
            run.command(
                .requestPower(PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 1), .shutdown))
            run.feed(WireFrames.bytes([power(2, .askingApps)], preamble: false))
        } expect: { run in
            let indeterminate = run.hostEvents.contains {
                $0 == .power(PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 1), .indeterminate)
            }
            return indeterminate ? [] : ["the request did not end indeterminate"]
        },
        HostileRow(
            name: "DATA after the far side's END", local: .peer, outcome: .streamReset(.streamProtocolError)
        ) { run in
            var request = Kernova_V2_PowerRequest()
            request.action = .shutdown
            run.feed(
                WireFrames.bytes([
                    HostileRow.hostHello, WireFrames.open(2, .powerRequest, body: request),
                    Frame(streamID: StreamID(rawValue: 2), type: .end),
                    Frame(streamID: StreamID(rawValue: 2), type: .data, payload: Data([1])),
                ]))
        } expect: { run in
            run.streamResets.first?.stream == 2 ? [] : ["no RESET on stream 2: \(run.streamResets)"]
        },
        HostileRow(name: "cancellation → CANCELLED", local: .host, outcome: .streamReset(.cancelled)) { run in
            run.feed(WireFrames.bytes([HostileRow.peerHello]))
            let id = PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 9)
            run.command(.requestPower(id, .restart))
            run.command(.cancelPower(id))
        },
        HostileRow(
            name: "policy turns LOGS off while open", local: .host, outcome: .streamReset(.disabledByPolicy)
        ) { run in
            run.feed(
                WireFrames.bytes([HostileRow.peerHello, WireFrames.open(1, .logForward, body: Kernova_V2_LogOpen())]))
            run.command(.setPolicy(PolicySnapshot()))
        },
        HostileRow(
            name: "an unknown stream RESET code reads STREAM_PROTOCOL_ERROR", local: .host, outcome: .staysUp
        ) {
            run in
            run.feed(WireFrames.bytes([HostileRow.peerHello]))
            let id = PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 1)
            run.command(.requestPower(id, .shutdown))
            run.feed(WireFrames.bytes([WireFrames.reset(2, code: 125)], preamble: false))
        } expect: { run in
            let closed = run.trace.contains {
                $0
                    == .event(
                        .streamClosed(
                            StreamID(rawValue: 2),
                            .resetByPeer(WireError(.streamProtocolError, debugDetail: "code 125: "))))
            }
            return closed ? [] : ["UPDATE_INSTALL_FAILED on a power stream did not read STREAM_PROTOCOL_ERROR"]
        },
        HostileRow(
            name: "an unassigned code inside 50–99 reads STREAM_PROTOCOL_ERROR", local: .host, outcome: .staysUp
        ) { run in
            run.feed(WireFrames.bytes([HostileRow.peerHello]))
            let id = PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 1)
            run.command(.requestPower(id, .shutdown))
            run.feed(WireFrames.bytes([WireFrames.reset(2, code: 77)], preamble: false))
        } expect: { run in
            let closed = run.trace.contains {
                $0
                    == .event(
                        .streamClosed(
                            StreamID(rawValue: 2),
                            .resetByPeer(WireError(.streamProtocolError, debugDetail: "code 77: "))))
            }
            return closed ? [] : ["code 77 did not read STREAM_PROTOCOL_ERROR: \(run.trace)"]
        },
        HostileRow(
            name: "the host's payload short of payload_size → END REJECTED UPDATE_SIZE_MISMATCH", local: .peer,
            outcome: .staysUp
        ) { run in
            run.feed([HostileRow.hostHello, Unit.updateAvailable(HostileRow.pulled)], preamble: true)
            run.feed([Unit.raw(1, Data(repeating: 1, count: 19_000)), Unit.end(1)])
        } expect: { run in
            let ends = run.written.on(1).filter { $0.type == .end }.compactMap {
                try? Kernova_V2_UpdateResult(serializedBytes: $0.payload)
            }
            return
                (ends.map(\.kind) == [.rejected] && ends.first?.error.code == .updateSizeMismatch
                ? [] : ["the peer's END: \(ends)"]) + HostileRow.rejectedRecorded(run)
        },
        HostileRow(
            name: "the host's payload past payload_size → RESET UPDATE_SIZE_MISMATCH", local: .peer,
            outcome: .streamReset(.updateSizeMismatch)
        ) { run in
            run.feed([HostileRow.hostHello, Unit.updateAvailable(HostileRow.pulled)], preamble: true)
            run.feed([Unit.raw(1, Data(repeating: 1, count: 20_000)), Unit.raw(1, Data(repeating: 2, count: 1_000))])
        } expect: { run in
            HostileRow.rejectedRecorded(run)
        },
        HostileRow(name: "a snapshot flood costs one event per drain", local: .host, outcome: .staysUp) { run in
            run.feed(WireFrames.bytes([HostileRow.peerHello]))
            let snapshots = (0..<5_000).map { index in
                WireFrames.session {
                    $0.peerState.sessionID = "c1"; $0.peerState.userName = "u\(index % 7)"
                }
            }
            run.feed(WireFrames.bytes(snapshots, preamble: false), maxSplit: 1 << 20)
        } expect: { run in
            let count = run.hostEvents.filter { if case .peerStateChanged = $0 { true } else { false } }.count
            return count <= 600 ? [] : ["\(count) peerStateChanged events"]
        },
    ]

    static let all = fatalRows + streamRows
}

@Suite("Hostile scenarios")
struct HostileSuite {
    @Test("Every hostile row, over seeded splits", arguments: HostileRows.all)
    func row(_ row: HostileRow) {
        for seed in UInt64(0)..<20 {
            let failures = row.run(seed: seed)
            if !failures.isEmpty {
                Issue.record("\(row.name) seed \(seed): \(failures.joined(separator: "; "))")
                return
            }
        }
    }

    @Test("A misused core closes INTERNAL in release")
    func misuse() {
        var configuration = ConnectionConfiguration(claim: PeerClaim(role: .host), adverts: [])
        configuration.assertsOnMisuse = false
        var connection = Connection(configuration, now: CoreInstant(nanoseconds: 0))
        connection.reset(StreamID(rawValue: 2), WireError(.cancelled))
        var closure: ConnectionClosure?
        while let event = connection.pollEvent() {
            if case .closed(let value) = event { closure = value }
        }
        guard case .closedLocally(let error) = closure else {
            Issue.record("no close: \(String(describing: closure))")
            return
        }
        #expect(error.code == .internal)
    }
}
