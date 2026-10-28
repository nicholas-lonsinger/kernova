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

extension CoreUnits {
    @Suite("Connection: transmit order, credit, misuse, coalescing, diagnostics")
    struct ConnectionUnitTests {
        static let hostBulk = StreamKind.UNRECOGNIZED(9001)
        static let peerBulk = StreamKind.UNRECOGNIZED(9000)

        // MARK: Transmit order

        @Test("pollTransmit hands frames out in order: session, connection WINDOW, PING, RESETs, WINDOWs, FIFOs")
        func transmitOrder() {
            var policy = ReceiverPolicy.production
            policy.connectionReplenishThreshold = 1_000
            policy.bulkReceiveTarget = 300_000
            var wire = Wire.host(policy: policy) { $0.addTestKinds() }
            wire.establish()
            let first = wire.connection.open(Self.hostBulk, body: Data())
            let second = wire.connection.open(Self.hostBulk, body: Data())
            #expect(wire.flush().shape == ["2:open", "4:open", "2:window", "4:window"])
            wire.feed([Unit.raw(first.rawValue, Data(repeating: 1, count: 80_000))])
            wire.connection.consumed(80_000, on: first)
            wire.connection.reset(second, WireError(.cancelled))
            let third = wire.connection.open(Self.hostBulk, body: Data())
            wire.connection.setPolicy(PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: false)]))
            wire.advance(to: Unit.at(5_000))
            let frames = wire.flush()
            #expect(
                frames.shape == [
                    "0:data+msg", "0:window", "0:ping", "4:reset", "2:window", "\(third.rawValue):open",
                    "\(third.rawValue):window",
                ])
            #expect(frames.count == 7)
            if frames.count == 7 {
                #expect(Unit.window(frames[1].payload) == 80_000)
                #expect(Unit.error(frames[3].payload).code == .cancelled)
                #expect(Unit.window(frames[4].payload) == 80_000)
                #expect(Unit.window(frames[6].payload) == UInt32(300_000 - 262_144))
            }
        }

        @Test("Stream FIFOs are served round-robin by id, one frame per stream per turn")
        func roundRobin() {
            var wire = Wire.host()
            wire.establish()
            let body = Unit.encode(Unit.powerRequest(.shutdown))
            let first = wire.connection.open(.powerRequest, body: body)
            wire.connection.end(first, body: Data())
            let second = wire.connection.open(.powerRequest, body: body)
            wire.connection.end(second, body: Data())
            #expect(wire.flush().shape == ["2:open", "4:open", "2:end", "4:end"])
        }

        @Test("pollTransmit returns one whole frame even past maxBytes")
        func wholeFramePastMaxBytes() {
            var wire = Wire.host()
            let transmit = wire.connection.pollTransmit(maxBytes: 1)
            #expect(transmit.map { $0.byteCount > 1 } == true)
            #expect(transmit?.isFinal == false)
        }

        @Test("A RESET queued before its OPEN is handed out drops the stream unsent, closes it .resetLocally once")
        func resetBeforeOpenHandedOut() {
            var wire = Wire.host()
            wire.establish()
            let body = Unit.encode(Unit.powerRequest(.shutdown))
            let dropped = wire.connection.open(.powerRequest, body: body)
            wire.connection.end(dropped, body: Data())
            wire.connection.reset(dropped, WireError(.cancelled))
            let events = wire.takeEvents()
            #expect(
                events == [.streamClosed(dropped, .resetLocally(WireError(.cancelled))), .slotFreed(.powerRequest)])
            let next = wire.connection.open(.powerRequest, body: body)
            #expect(next.rawValue == dropped.rawValue + 2)
            let frames = wire.flush()
            #expect(frames.on(dropped.rawValue).isEmpty)
            #expect(frames.shape == ["\(next.rawValue):open"])
            #expect(wire.takeEvents().isEmpty)
            #expect(wire.connection.footprint.streamRecords == 1)
        }

        @Test("A RESET that drops an unsent OPEN frees its concurrency slot at once")
        func resetBeforeOpenFreesSlot() {
            var wire = Wire.host()
            wire.establish()
            let body = Unit.encode(Unit.powerRequest(.shutdown))
            var streams: [StreamID] = []
            for _ in 0..<64 { streams.append(wire.connection.open(.powerRequest, body: body)) }
            #expect(!wire.connection.canOpen(.powerRequest))
            wire.connection.reset(streams[10], WireError(.cancelled))
            #expect(wire.connection.canOpen(.powerRequest))
        }

        @Test("A RESET after its OPEN was handed out holds the slot until the RESET itself is handed out")
        func resetAfterOpenHoldsSlotUntilHandedOut() {
            var wire = Wire.host()
            wire.establish()
            let body = Unit.encode(Unit.powerRequest(.shutdown))
            var streams: [StreamID] = []
            for _ in 0..<64 { streams.append(wire.connection.open(.powerRequest, body: body)) }
            _ = wire.flush()
            wire.connection.reset(streams[0], WireError(.cancelled))
            #expect(!wire.connection.canOpen(.powerRequest))
            #expect(wire.flush().shape == ["\(streams[0].rawValue):reset"])
            #expect(wire.connection.canOpen(.powerRequest))
        }

        // MARK: Credit

        @Test("Connection credit is conserved after a RESET with raw DATA held, queued and in flight")
        func conservationAfterReset() {
            var pair = Pair()
            let stream = pair.peer.connection.open(Self.peerBulk, body: Data())
            pair.peerToHost()
            #expect(pair.hostEvents.contains(.opened(stream, Self.peerBulk, body: Data())))
            let mebibyte = Data(repeating: 7, count: 1 << 20)
            pair.host.connection.send(data: mebibyte, on: stream)
            pair.host.connection.send(data: mebibyte, on: stream)
            pair.hostToPeer()
            #expect(pair.peer.connection.footprint.heldRawBytes == 2 << 20)
            pair.host.connection.send(data: mebibyte, on: stream)
            let inFlight = pair.takeHostBytes()
            pair.host.connection.send(data: Data(repeating: 8, count: 1 << 19), on: stream)
            pair.peer.connection.reset(stream, WireError(.cancelled))
            pair.peer.connection.receive(inFlight, now: pair.peer.now)
            pair.peerToHost()
            pair.settle()
            let total = Limits.initialConnectionWindow
            #expect(Pair.conserved(sender: pair.host.connection, receiver: pair.peer.connection) == total)
            #expect(Pair.conserved(sender: pair.peer.connection, receiver: pair.host.connection) == total)
            #expect(pair.host.connection.footprint.queuedRawBytes == 0)
            #expect(pair.peer.connection.footprint.heldRawBytes == 0)
        }

        @Test("Connection credit is conserved after a local close with raw DATA held and queued")
        func conservationAfterClose() {
            var pair = Pair()
            let stream = pair.peer.connection.open(Self.peerBulk, body: Data())
            pair.peerToHost()
            let mebibyte = Data(repeating: 7, count: 1 << 20)
            pair.host.connection.send(data: mebibyte, on: stream)
            pair.hostToPeer()
            pair.host.connection.send(data: mebibyte, on: stream)
            pair.host.connection.close(.shuttingDown, retryAfter: nil, now: pair.host.now)
            #expect(pair.host.connection.footprint.queuedRawBytes == 0)
            pair.settle()
            let total = Limits.initialConnectionWindow
            #expect(Pair.conserved(sender: pair.host.connection, receiver: pair.peer.connection) == total)
            #expect(pair.host.connection.state == .finished)
            #expect(pair.peer.connection.state == .finished)
        }

        @Test("Consuming held raw DATA returns connection credit at 4 MiB and conserves it")
        func conservationAfterConsume() {
            var pair = Pair()
            let stream = pair.peer.connection.open(Self.peerBulk, body: Data())
            pair.peerToHost()
            let mebibyte = Data(repeating: 7, count: 1 << 20)
            for _ in 0..<5 {
                pair.host.connection.send(data: mebibyte, on: stream)
                pair.hostToPeer()
            }
            pair.peer.connection.consumed(3 << 20, on: stream)
            #expect(pair.peer.connection.footprint.unreturnedConnectionCredit == 3 << 20)
            pair.peer.connection.consumed(1 << 20, on: stream)
            pair.settle()
            #expect(pair.peer.connection.footprint.unreturnedConnectionCredit == 0)
            #expect(pair.host.connection.footprint.connectionSendCredit == Limits.initialConnectionWindow - (1 << 20))
            #expect(
                Pair.conserved(sender: pair.host.connection, receiver: pair.peer.connection)
                    == Limits.initialConnectionWindow)
        }

        @Test("R3: the opener of a bulk direction puts one WINDOW of 8 MiB − 256 KiB right after its OPEN")
        func bulkWindowOpener() {
            var wire = Wire.peer()
            wire.establish()
            var pull = Kernova_V2_UpdatePull()
            pull.payloadHash = Data(repeating: 3, count: 32)
            let stream = wire.connection.open(.updatePull, body: Unit.encode(pull))
            let frames = wire.flush()
            #expect(frames.shape == ["\(stream.rawValue):open", "\(stream.rawValue):window"])
            #expect(frames.last.map { Unit.window($0.payload) } == UInt32(8_388_608 - 262_144))
        }

        @Test("R3: a message-only direction stays at 256 KiB, no WINDOW after the OPEN")
        func messageDirectionStaysAtInitialWindow() {
            var wire = Wire.peer()
            wire.establish()
            wire.feed([Unit.policy(logs: true)])
            let stream = wire.connection.open(.logForward, body: Unit.encode(Kernova_V2_LogOpen()))
            #expect(wire.flush().shape == ["\(stream.rawValue):open"])
        }

        @Test("R3: the acceptor of a bulk direction queues the raising WINDOW with its first frames")
        func bulkWindowAcceptor() {
            let kind = StreamKind.UNRECOGNIZED(9100)
            var wire = Wire.host {
                $0.kinds.append(
                    StreamKindDescriptor(
                        kind: kind, feature: nil, owner: .testBulk, openerRole: .peer, openerToAcceptor: .rawData,
                        acceptorToOpener: .nothing, maxPerConnection: nil, isValidOpenBody: { _ in true }))
            }
            wire.establish()
            var open = Kernova_V2_Open()
            open.kind = kind
            wire.feed([Frame(streamID: StreamID(rawValue: 1), type: .open, payload: Unit.encode(open))])
            #expect(wire.takeEvents() == [.opened(StreamID(rawValue: 1), kind, body: Data())])
            let frames = wire.flush()
            #expect(frames.shape == ["1:window"])
            #expect(frames.first.map { Unit.window($0.payload) } == UInt32(8_388_608 - 262_144))
        }

        @Test("A capped credit return sends the burst, then no more than the rate allows")
        func creditReturnRateCap() {
            var wire = Wire.host()
            wire.establish()
            wire.feed([WireFrames.open(1, .logForward, body: Kernova_V2_LogOpen())])
            let stream = StreamID(rawValue: 1)
            #expect(wire.takeEvents() == [.opened(stream, .logForward, body: Data())])
            wire.connection.setCreditReturnRate(1_048_576, burst: 262_144, on: stream)
            let message = Unit.rawMessage(1, Data(repeating: 0x5A, count: 65_536))
            var credit = 262_144
            var returned: [(at: CoreInstant, bytes: Int)] = []
            func send(_ wire: inout Wire) {
                var frames: [Frame] = []
                while credit >= 65_536 {
                    frames.append(message)
                    credit -= 65_536
                }
                wire.feed(frames)
                _ = wire.takeEvents()
                for frame in wire.flush().on(1) where frame.type == .window {
                    let bytes = Int(Unit.window(frame.payload))
                    credit += bytes
                    returned.append((wire.now, bytes))
                }
            }
            send(&wire)
            #expect(returned.map(\.bytes) == [262_144])
            send(&wire)
            #expect(returned.count == 1)
            #expect(
                wire.connection.nextDeadline
                    == Unit.at(0).advanced(by: .milliseconds(62) + CoreDuration(nanoseconds: 500_000)))
            let end = Unit.at(1_000)
            while wire.now < end {
                let next = min(wire.connection.nextDeadline ?? end, end)
                wire.advance(to: max(next, wire.now.advanced(by: CoreDuration(nanoseconds: 1))))
                send(&wire)
            }
            let afterBurst = returned.dropFirst().reduce(0) { $0 + $1.bytes }
            #expect(afterBurst <= 1_048_576)
            #expect(afterBurst >= 1_048_576 - 2 * 65_536)
            #expect(returned.dropFirst().first.map { $0.at >= Unit.at(62) } == true)
        }

        // MARK: Writability

        @Test("A message stream fires .writable on the rising edge of credit ≥ 64 KiB with no message unsent")
        func writableRisingEdge() {
            var wire = Wire.peer()
            wire.establish()
            wire.feed([Unit.policy(logs: true)])
            let stream = wire.connection.open(.logForward, body: Unit.encode(Kernova_V2_LogOpen()))
            _ = wire.flush()
            _ = wire.takeEvents()
            let message = Data(repeating: 1, count: 60_000)
            for _ in 0..<4 {
                #expect(wire.connection.canSendMessage(message.count, on: stream))
                wire.connection.send(message: message, on: stream)
                #expect(!wire.connection.canSendMessage(1, on: stream))
                _ = wire.flush()
            }
            #expect(wire.takeEvents() == [.writable(stream), .writable(stream), .writable(stream)])
            #expect(!wire.connection.canSendMessage(60_000, on: stream))
            wire.feed([WireFrames.window(stream.rawValue, 40_000)])
            #expect(wire.takeEvents().isEmpty)
            wire.feed([WireFrames.window(stream.rawValue, 20_000)])
            #expect(wire.takeEvents() == [.writable(stream)])
        }

        // MARK: Misuse

        enum Misuse: String, CaseIterable, Sendable, CustomTestStringConvertible {
            case messageOnSilentDirection, rawPastWritable, sendAfterEnd, resetOfClosed, openOtherRolesKind
            case consumedPastHeld, peerStateOnHost

            var testDescription: String { rawValue }
        }

        @Test("A misused core closes the connection INTERNAL when assertions are off", arguments: Misuse.allCases)
        func misuseClosesInternal(_ misuse: Misuse) {
            var wire = Wire.host { $0.addTestKinds() }
            wire.establish()
            let power = wire.connection.open(.powerRequest, body: Unit.encode(Unit.powerRequest(.shutdown)))
            _ = wire.flush()
            switch misuse {
            case .messageOnSilentDirection:
                wire.connection.send(message: Data([1]), on: power)
            case .rawPastWritable:
                let bulk = wire.connection.open(Self.hostBulk, body: Data())
                wire.connection.send(data: Data([1]), on: bulk)
            case .sendAfterEnd:
                wire.connection.end(power, body: Data())
                wire.connection.end(power, body: Data())
            case .resetOfClosed:
                wire.connection.reset(power, WireError(.cancelled))
                wire.connection.reset(power, WireError(.cancelled))
            case .openOtherRolesKind:
                wire.connection.open(.updatePull, body: Data())
            case .consumedPastHeld:
                let bulk = wire.connection.open(Self.hostBulk, body: Data())
                wire.connection.consumed(1, on: bulk)
            case .peerStateOnHost:
                wire.connection.setPeerState(PeerSessionState(sessionID: "x"))
            }
            #expect(wire.connection.state == .closing)
            let events = wire.takeEvents()
            #expect(
                events.contains { event in
                    if case .diagnostic(.localFault(let text)) = event { return text.hasPrefix("misuse:") }
                    return false
                })
            #expect(
                events.contains { event in
                    if case .closed(.closedLocally(let error)) = event { return error.code == .internal }
                    return false
                })
            let frames = wire.flush()
            #expect(frames.shape == ["0:reset"])
            #expect(frames.first.map { Unit.error($0.payload).code } == .internal)
            #expect(wire.connection.state == .finished)
        }

        // MARK: Coalescing

        @Test("Unsent snapshots coalesce in the transmit queue, the newest replacing the older")
        func coalescedTransmit() {
            var peer = Wire.peer()
            peer.establish()
            for name in ["a", "b", "c"] {
                peer.connection.setPeerState(PeerSessionState(console: .on, sessionID: "c1", userName: name))
            }
            var adverts = Unit.peerAdverts()
            adverts[0].1 = LocalAdvert(version: 1, availability: .absent(.notOnConsole, debugDetail: ""))
            peer.connection.setLocalAdverts(adverts)
            peer.connection.setLocalAdverts(Array(Unit.peerAdverts().reversed()))
            peer.connection.setLocalAdverts(adverts)
            let frames = peer.flush()
            #expect(frames.shape == ["0:data+msg", "0:data+msg"])
            let messages = frames.compactMap { try? Kernova_V2_SessionMessage(serializedBytes: $0.payload) }
            #expect(messages.first?.peerState.userName == "c")
            #expect(messages.last?.capabilities.features.first?.absent.reason == .notOnConsole)

            var host = Wire.host()
            host.establish()
            host.connection.setPolicy(PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: false)]))
            host.connection.setPolicy(
                PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: true, params: Data([1]))]))
            let policies = host.flush().compactMap { try? Kernova_V2_SessionMessage(serializedBytes: $0.payload) }
            #expect(policies.count == 1)
            #expect(policies.first?.policy.features.first?.params == Data([1]))
        }

        // MARK: Diagnostics rate limit

        @Test("Diagnostics are limited to 20 a minute, then one .suppressed(count) when the minute ends")
        func diagnosticsRateLimit() {
            var wire = Wire.host(policy: Unit.patientPolicy)
            wire.establish()
            let bad = WireFrames.session { $0.extension = Data([0x08]) }
            wire.feed(Array(repeating: bad, count: 25))
            let diagnostics = wire.takeEvents().filter { event in
                if case .diagnostic(.remoteViolation) = event { return true }
                return false
            }
            #expect(diagnostics.count == 20)
            #expect(wire.connection.nextDeadline.map { $0 <= Unit.at(60_000) } == true)
            wire.advance(to: Unit.at(59_000))
            #expect(!wire.takeEvents().contains(.diagnostic(.suppressed(5))))
            wire.advance(to: Unit.at(60_000))
            #expect(
                wire.takeEvents().filter { if case .diagnostic = $0 { true } else { false } } == [
                    .diagnostic(.suppressed(5))
                ])
            wire.feed([bad])
            #expect(wire.takeEvents().count == 1)
            wire.advance(to: Unit.at(130_000))
            #expect(wire.takeEvents().filter { if case .diagnostic = $0 { true } else { false } }.isEmpty)
        }
    }
}
