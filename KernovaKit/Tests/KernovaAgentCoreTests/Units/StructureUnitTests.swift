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
    @Suite("Connection: stream ordering, slots and the shared send budget")
    struct ConnectionStructureUnitTests {
        static let hostBulk = StreamKind.UNRECOGNIZED(9001)
        static let peerBulk = StreamKind.UNRECOGNIZED(9000)

        @Test("OPENs leave in id order even when round-robin would start between them")
        func openOrderAcrossRoundRobin() {
            var wire = Wire.peer { $0.addTestKinds() }
            wire.establish()
            wire.feed([WireFrames.open(2, Self.hostBulk, body: Kernova_V2_LogOpen())])
            wire.connection.send(data: Data(repeating: 1, count: 10), on: StreamID(rawValue: 2))
            #expect(wire.flush().shape == ["2:data"])
            #expect(wire.connection.roundRobinAfter == 2)
            let first = wire.connection.open(Self.peerBulk, body: Data())
            let second = wire.connection.open(Self.peerBulk, body: Data())
            #expect([first.rawValue, second.rawValue] == [1, 3])
            #expect(wire.flush().shape == ["1:open", "3:open", "3:window", "1:window"])
        }

        @Test("A stream reset before its OPEN left blocks no later OPEN")
        func droppedOpenBlocksNothing() {
            var wire = Wire.host { $0.addTestKinds() }
            wire.establish()
            let dropped = wire.connection.open(Self.hostBulk, body: Data())
            let kept = wire.connection.open(Self.hostBulk, body: Data())
            wire.connection.reset(dropped, WireError(.cancelled))
            #expect(wire.flush().shape == ["\(kept.rawValue):open", "\(kept.rawValue):window"])
        }

        @Test("A kind's per-connection limit counts a stream until this side's last frame is handed out")
        func perKindLimitHoldsUntilHandedOut() {
            var wire = Wire.peer()
            wire.establish()
            var pull = Kernova_V2_UpdatePull()
            pull.payloadHash = Data(repeating: 3, count: 32)
            let first = wire.connection.open(.updatePull, body: Unit.encode(pull))
            _ = wire.flush()
            wire.feed([Unit.end(first.rawValue)])
            wire.connection.end(first, body: Data())
            #expect(wire.connection.phase(of: first) == .closed)
            #expect(wire.connection.openRefusal(.updatePull)?.code == .updateInProgress)
            #expect(wire.flush().shape == ["\(first.rawValue):end"])
            #expect(wire.connection.canOpen(.updatePull))
        }

        @Test(
            "A local stream that outlives its streamClosed raises .slotFreed when it retires: END out, or a crossing RESET",
            arguments: [false, true])
        func slotFreedOnRetire(_ crossingReset: Bool) {
            var wire = Wire.peer()
            wire.establish()
            var pull = Kernova_V2_UpdatePull()
            pull.payloadHash = Data(repeating: 3, count: 32)
            let first = wire.connection.open(.updatePull, body: Unit.encode(pull))
            _ = wire.flush()
            wire.feed([Unit.end(first.rawValue)])
            wire.connection.end(first, body: Data())
            #expect(!wire.takeEvents().contains(.slotFreed(.updatePull)))
            if crossingReset {
                wire.feed([WireFrames.reset(first.rawValue, code: ErrorCode.cancelled.rawValue)])
            } else {
                #expect(wire.flush().shape == ["\(first.rawValue):end"])
            }
            #expect(wire.takeEvents() == [.slotFreed(.updatePull)])
            #expect(wire.connection.canOpen(.updatePull))
        }

        @Test("A RESET for a stream closed with its last frame unsent drops that frame and frees the slot")
        func resetOnClosedRetires() {
            var wire = Wire.host()
            wire.establish()
            wire.feed([WireFrames.open(1, .UNRECOGNIZED(4242), body: Kernova_V2_LogOpen())])
            #expect(wire.connection.remoteSlotsCounted == 1)
            wire.feed([WireFrames.reset(1, code: ErrorCode.cancelled.rawValue)])
            #expect(wire.connection.remoteSlotsCounted == 0)
            #expect(wire.connection.footprint.streamRecords == 0)

            wire.feed([WireFrames.open(3, .logForward, body: Kernova_V2_LogOpen()), Unit.end(3)])
            wire.connection.end(StreamID(rawValue: 3), body: Data())
            #expect(wire.connection.remoteSlotsCounted == 1)
            wire.feed([WireFrames.reset(3, code: ErrorCode.cancelled.rawValue)])
            #expect(wire.connection.remoteSlotsCounted == 0)
            #expect(wire.flush().filter { $0.streamID != .session }.isEmpty)
        }

        @Test("A discarded FIFO's refund raises .writable on another raw stream the shared budget held back")
        func discardRefreshesWritable() {
            var wire = Wire.host { $0.addTestKinds() }
            wire.establish()
            let held = StreamID(rawValue: 1)
            let waiting = StreamID(rawValue: 3)
            wire.feed([
                WireFrames.open(1, Self.peerBulk, body: Kernova_V2_LogOpen()),
                WireFrames.open(3, Self.peerBulk, body: Kernova_V2_LogOpen()), WireFrames.window(1, 8_000_000),
                WireFrames.window(3, 8_000_000),
            ])
            wire.connection.send(data: Data(repeating: 1, count: 1_048_576), on: held)
            wire.connection.send(data: Data(repeating: 1, count: 1_048_576), on: held)
            #expect(wire.connection.writableData(waiting) == 0)
            _ = wire.takeEvents()
            wire.connection.reset(held, WireError(.cancelled))
            #expect(wire.takeEvents().contains(.writable(waiting)))
        }

        @Test("A refused OPEN's record names no machine; an accepted one names its kind's")
        func refusedRecordHasNoOwner() {
            var wire = Wire.host()
            wire.establish()
            wire.feed([
                WireFrames.open(1, .UNRECOGNIZED(4242), body: Kernova_V2_LogOpen()),
                WireFrames.open(3, .logForward, body: Kernova_V2_LogOpen()),
                WireFrames.open(5, .logForward, body: Kernova_V2_LogOpen()),
            ])
            let refused = wire.connection.streams.filter { !$0.isAccepted }
            #expect(refused.map(\.id.rawValue) == [1, 5])
            #expect(refused.allSatisfy { $0.owner == nil })
            #expect(wire.connection.streams.first { $0.isAccepted }?.owner == .logs)
        }

        @Test("A frame in the turn after a deadline was found passed ends the judgment first")
        func framesBeforeDeadlines() {
            var wire = Wire.peer()
            wire.advance(to: Unit.at(10_000))
            #expect(wire.connection.state == .handshaking)
            wire.now = Unit.at(11_500)
            wire.feed([WireFrames.hello(role: .host)], preamble: true)
            #expect(wire.connection.state == .established)
        }

        @Test("Handing out RESET(0) leaves the connection closing, with nothing more to send, until its write")
        func finishesOnFinalWrite() {
            var wire = Wire.host()
            wire.establish()
            wire.connection.close(.shuttingDown, retryAfter: nil, now: wire.now)
            #expect(wire.connection.pollTransmit(maxBytes: 1 << 20)?.isFinal == true)
            #expect(wire.connection.state == .closing)
            #expect(wire.connection.pollTransmit(maxBytes: 1 << 20) == nil)
            wire.connection.finalTransmitWritten(now: wire.now)
            #expect(wire.connection.state == .finished)
        }

        @Test("The closing deadline finishes a connection whose final write never completes")
        func closingDeadlineFinishesUnwritten() {
            var wire = Wire.host()
            wire.establish()
            wire.connection.close(.shuttingDown, retryAfter: nil, now: wire.now)
            #expect(wire.connection.pollTransmit(maxBytes: 1 << 20)?.isFinal == true)
            #expect(wire.connection.nextDeadline == wire.now.advanced(by: .seconds(1)))
            wire.advance(by: .milliseconds(999))
            #expect(wire.connection.state == .closing)
            wire.advance(by: .milliseconds(1))
            #expect(wire.connection.state == .finished)
            #expect(wire.connection.nextDeadline == nil)
        }

        @Test("PINGs are due every 4 s, each one interval after the last was due, however late its turn")
        func pingAnchored() {
            var wire = Wire.host(policy: Unit.patientPolicy)
            wire.establish()
            wire.advance(to: Unit.at(4_300))
            #expect(wire.flush().shape == ["0:ping"])
            #expect(wire.connection.nextDeadline == Unit.at(8_000))
            wire.advance(to: Unit.at(13_100))
            #expect(wire.flush().shape == ["0:ping"])
            #expect(wire.connection.nextDeadline == Unit.at(16_000))
        }
    }

    @Suite("Endpoints: session snapshots, coalescing and deadlines")
    struct EndpointUnitTests {
        static func sessionMessages(_ run: HostileRun) -> [Kernova_V2_SessionMessage] {
            run.written.filter { $0.streamID == .session && $0.type == .data }.compactMap {
                try? Kernova_V2_SessionMessage(serializedBytes: $0.payload)
            }
        }

        @Test("A policy and bundles set before the peer's Hello go out in the Hello-time messages, once each")
        func policyAndBundlesBeforeHello() {
            let run = HostileRun(local: .host, seed: 23)
            let newer = SimHub.bundle(size: 5_000, tag: 9)
            run.command(.setPolicy(PolicySnapshot([FeaturePolicyValue(feature: .logs, enabled: false)])))
            run.command(.setBundles([newer]))
            run.feed([WireFrames.hello(role: .sessionPeer)], preamble: true)
            let messages = Self.sessionMessages(run)
            let policies = messages.compactMap { if case .policy(let policy) = $0.message { policy } else { nil } }
            #expect(policies.count == 1)
            #expect(policies.first?.features.map(\.enabled) == [false])
            let offers = messages.compactMap { message -> Kernova_V2_UpdateAvailable? in
                if case .updateAvailable(let available) = message.message { available } else { nil }
            }
            #expect(offers.map(\.manifest.payloadHash) == [newer.manifest.payloadHash])
        }

        @Test("Snapshots read in one turn raise one event each on the host, the newest kept")
        func hostEventsCoalesce() {
            let run = HostileRun(local: .host, seed: 29)
            run.feed([WireFrames.hello(role: .sessionPeer)], preamble: true)
            let states = ["a", "b", "c"].map { name in
                WireFrames.session { message in
                    message.peerState.sessionID = "c1"
                    message.peerState.console = .on
                    message.peerState.userName = name
                }
            }
            let mark = run.hostEvents.count
            let frames = states + [Unit.capabilities(withdrawing: .power), Unit.capabilities()]
            run.feed(WireFrames.bytes(frames, preamble: false), maxSplit: 1 << 20)
            let events = Array(run.hostEvents.dropFirst(mark))
            #expect(
                events.filter { if case .peerStateChanged = $0 { true } else { false } } == [
                    .peerStateChanged(PeerSessionState(console: .on, sessionID: "c1", userName: "c"))
                ])
            #expect(events.count { if case .featuresChanged = $0 { true } else { false } } == 1)
        }

        @Test("PolicyUpdates and offers read in one turn raise one event each on the peer, the newest kept")
        func peerEventsCoalesce() {
            let run = HostileRun(local: .peer, seed: 31)
            run.feed([WireFrames.hello(role: .host)], preamble: true)
            let last = Unit.manifest(tag: 2)
            let frames = [
                Unit.policy(logs: true), Unit.updateAvailable(Unit.manifest(tag: 1)), Unit.policy(logs: false),
                Unit.updateAvailable(nil), Unit.policy(logs: true), Unit.updateAvailable(last),
            ]
            run.feed(WireFrames.bytes(frames, preamble: false), maxSplit: 1 << 20)
            #expect(run.peerEvents.count { $0 == .policyReceived } == 1)
            #expect(
                run.peerEvents.filter { if case .updateAvailable = $0 { true } else { false } } == [
                    .updateAvailable(last)
                ])
        }

        @Test("A machine's deadline counts the moment the VM resumes, whatever turns ran while it was frozen")
        func machineDeadlineAfterUnfreeze() {
            let run = HostileRun(local: .host, seed: 37)
            run.feed([WireFrames.hello(role: .sessionPeer)], preamble: true)
            run.command(
                .requestPower(PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 1), .shutdown))
            run.advanceLive(.sec(14), pingEvery: .ms(500))
            run.command(.setPeerFrozen(true))
            run.advance(.sec(2))
            run.command(.setPeerFrozen(false))
            let deadline = run.host?.nextDeadline
            #expect(deadline.map { $0 <= run.now.advanced(by: .seconds(1)) } == true)
        }

        @Test("A receive turn reads its frames before it judges: a late Hello beats its found-passed deadline")
        func endpointFramesBeforeDeadlines() {
            let run = HostileRun(local: .peer, seed: 41)
            run.advance(.sec(10))
            #expect(run.state == .handshaking)
            run.now = run.now.advanced(by: .milliseconds(1_500))
            run.feed(WireFrames.bytes([WireFrames.hello(role: .host)]), maxSplit: 1 << 20)
            #expect(run.state == .established)
        }
    }

    @Suite("Power: the process-wide request, the wire bounds of apps, and the refusal's reason")
    struct PowerStructureUnitTests {
        static let id = PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 2)
        static let earlier = PowerRequestID(generation: ConnectionGeneration(rawValue: 9), rawValue: 2)

        static func peer(ledger: PowerLedger = PowerLedger()) -> HostileRun {
            let run = HostileRun(local: .peer, seed: 7, powerLedger: ledger)
            run.feed([WireFrames.hello(role: .host)], preamble: true)
            return run
        }

        static func request(_ run: HostileRun, stream: UInt32 = 2) {
            run.feed([WireFrames.open(stream, .powerRequest, body: Unit.powerRequest(.shutdown)), Unit.end(stream)])
        }

        static func outcomes(_ run: HostileRun, stream: UInt32) -> [Kernova_V2_PowerOutcome] {
            run.written.on(stream).filter { $0.type == .end }.compactMap {
                try? Kernova_V2_PowerOutcome(serializedBytes: $0.payload)
            }
        }

        static func performed(_ run: HostileRun) -> [PowerRequestID] {
            run.peerEffects.compactMap { if case .power(.perform(let id, _, _)) = $0 { id } else { nil } }
        }

        static func localFaults(_ run: HostileRun) -> Int {
            run.peerEvents.count(where: { if case .diagnostic(.localFault) = $0 { true } else { false } })
        }

        @Test("PowerLedger holds a request from .perform until that request's terminal report, in any order")
        func ledger() {
            let other = PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 4)
            let terminals: [PowerInput] = [
                .refused(Self.id, WireError(.powerOsFailed)), .cancelled(Self.id), .handedOff(Self.id),
                .blocked(Self.id, []), .cancelledInGuest(Self.id), .failed(Self.id, WireError(.powerOsFailed)),
            ]
            for terminal in terminals {
                var ledger = PowerLedger()
                ledger.record(.perform(Self.id, .shutdown))
                ledger.record(.cancel(Self.id))
                ledger.record(.accepted(Self.id))
                ledger.record(.waitingOnApps(Self.id, []))
                ledger.record(.handedOff(other))
                #expect(ledger.held == Self.id)
                ledger.record(terminal)
                #expect(ledger.held == nil)
            }
        }

        @Test("accepted + host RESET keeps the request: its later reports are no faults, a new OPEN is IN_PROGRESS")
        func streamlessRequestStays() {
            let run = Self.peer()
            Self.request(run)
            run.input(.power(.accepted(Self.id)))
            run.feed([WireFrames.reset(2, code: ErrorCode.cancelled.rawValue)])
            run.input(.power(.askingApps(Self.id)))
            run.input(.power(.waitingOnApps(Self.id, [AppValue(displayName: "Editor")])))
            #expect(Self.localFaults(run) == 0)
            Self.request(run, stream: 4)
            #expect(Self.outcomes(run, stream: 4).map(\.error.code) == [.powerInProgress])
            run.input(.power(.handedOff(Self.id)))
            Self.request(run, stream: 6)
            #expect(Self.performed(run).map(\.rawValue) == [2, 6])
        }

        @Test("cancelling + .accepted on a closed stream keeps the request until its terminal report")
        func cancellingAcceptedStreamlessStays() {
            let run = Self.peer()
            Self.request(run)
            run.feed([WireFrames.reset(2, code: ErrorCode.cancelled.rawValue)])
            run.input(.power(.accepted(Self.id)))
            Self.request(run, stream: 4)
            #expect(Self.outcomes(run, stream: 4).map(\.error.code) == [.powerInProgress])
            run.input(.power(.blocked(Self.id, [])))
            #expect(Self.localFaults(run) == 0)
        }

        @Test("A request the adapter still holds from an earlier connection refuses IN_PROGRESS until it ends")
        func ledgerCarriesAcrossConnections() {
            var ledger = PowerLedger()
            ledger.record(.perform(Self.earlier, .shutdown))
            let run = Self.peer(ledger: ledger)
            Self.request(run)
            #expect(Self.outcomes(run, stream: 2).map(\.error.code) == [.powerInProgress])
            run.input(.power(.askingApps(Self.earlier)))
            run.input(.power(.handedOff(Self.earlier)))
            #expect(Self.localFaults(run) == 0)
            Self.request(run, stream: 4)
            #expect(Self.performed(run) == [PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 4)])
        }

        @Test("BlockingApp strings are clipped at the sender to the receiver's bounds, so 32 long apps fit a message")
        func longAppsFit() {
            let run = Self.peer()
            Self.request(run)
            run.input(.power(.accepted(Self.id)))
            let long = String(repeating: "n", count: 10_000)
            let apps = (0..<32).map {
                AppValue(displayName: long, identifier: "\u{200B}" + long, processID: Int32($0))
            }
            run.input(.power(.waitingOnApps(Self.id, apps)))
            run.input(.power(.blocked(Self.id, apps)))
            #expect(run.closure == nil)
            let waiting = run.written.on(2).last { $0.type == .data }.flatMap {
                try? Kernova_V2_PowerProgress(serializedBytes: $0.payload)
            }
            #expect(waiting?.stage == .waitingOnApps)
            let blocked = Self.outcomes(run, stream: 2).first
            #expect(blocked?.kind == .blocked)
            #expect(blocked?.apps.count == 32)
            #expect(blocked?.apps.first?.displayName.utf8.count == 128)
            #expect(blocked?.apps.first?.identifier == String(repeating: "n", count: 256))
        }

        static let hostID = PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: 7)

        static func results(_ run: HostileRun) -> [PowerRequestResult] {
            run.hostEvents.compactMap { event in
                guard case .power(let id, let result) = event, id == Self.hostID else { return nil }
                return result
            }
        }

        @Test("A request on a closing connection is refused with the close's own error, not TOO_MANY_STREAMS")
        func refusedWhileClosing() {
            let run = HostileRun(local: .host, seed: 43)
            run.feed([WireFrames.hello(role: .sessionPeer)], preamble: true)
            run.writerStalled = true
            run.command(.close(.superseded, retryAfter: nil))
            run.command(.requestPower(Self.hostID, .shutdown))
            #expect(Self.results(run) == [.refused(WireError(.superseded))])
        }

        @Test("A request before the peer's Hello is refused FEATURE_UNAVAILABLE")
        func refusedBeforeHello() {
            let run = HostileRun(local: .host, seed: 47)
            run.command(.requestPower(Self.hostID, .shutdown))
            let codes = Self.results(run).map { result -> ErrorCode? in
                if case .refused(let error) = result { return error.code }
                return nil
            }
            #expect(codes == [.featureUnavailable])
        }

        @Test("The 65th concurrent request is refused TOO_MANY_STREAMS")
        func refusedAtTheLimit() {
            let run = HostileRun(local: .host, seed: 53)
            run.feed([WireFrames.hello(role: .sessionPeer)], preamble: true)
            for raw in UInt64(100)..<164 {
                run.command(
                    .requestPower(
                        PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: raw), .shutdown))
            }
            run.command(.requestPower(Self.hostID, .shutdown))
            #expect(Self.results(run) == [.refused(WireError(.tooManyStreams))])
        }

        @Test("RoutingPeer from a peer's feature table takes POWER's usability and its PowerCapability's actions")
        func routingPeerFromTable() {
            var capability = Kernova_V2_PowerCapability()
            capability.actions = [.restart]
            capability.asksAppsToQuit = true
            let params = Unit.encode(capability)
            #expect(PowerOffer(params: params) == PowerOffer(actions: [.restart], asksAppsToQuit: true))
            #expect(PowerOffer(params: Data([0xFF])) == nil)
            let skipping = PowerOffer(actions: [], skippingBlockers: [.shutdown], actionsAbsence: .unsavedWorkUnseen)
            #expect(PowerOffer(params: skipping.encoded) == skipping)
            let both = PowerOffer(actions: [.shutdown, .restart], skippingBlockers: [.shutdown, .restart])
            #expect(PowerOffer(params: both.encoded) == both)
            // An absence beside listed actions, or outside 1-99, reads as none.
            capability.actionsAbsence = .unsavedWorkUnseen
            #expect(PowerOffer(params: Unit.encode(capability))?.actionsAbsence == nil)
            capability.actions = []
            capability.actionsAbsence = .noAgent
            #expect(PowerOffer(params: Unit.encode(capability))?.actionsAbsence == nil)
            #expect(
                PowerOffer.waitingStatus(.available(skipping.encoded))
                    == .absent(.unsavedWorkUnseen, debugDetail: ""))
            #expect(PowerOffer.waitingStatus(.available(both.encoded)) == .available(both.encoded))
            let state = PeerSessionState(console: .on, sessionID: "c1")
            let usable = RoutingPeer(
                handle: PeerHandle(rawValue: 1), role: .sessionPeer, state: state, connectedOrder: 1,
                features: FeatureStatusTable([(feature: .power, status: .available(params))]))
            #expect(usable.powerUsable)
            #expect(usable.actions == [.restart])
            let absent = RoutingPeer(
                handle: PeerHandle(rawValue: 2), role: .sessionPeer, state: state, connectedOrder: 2,
                features: FeatureStatusTable([(feature: .power, status: .absent(.notOnConsole, debugDetail: ""))]))
            #expect(!absent.powerUsable)
            #expect(absent.actions.isEmpty)
        }
    }
}
