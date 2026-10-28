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
    @Suite("UpdateClient: the pull decision and the peer rows")
    struct UpdateClientUnitTests {
        static let manifest = Unit.manifest(tag: 1, size: 1_000)
        static let newer = Unit.manifest(tag: 2, size: 1_000)
        static let ownHash = Data(repeating: 0xA1, count: 32)

        static func id(_ stream: UInt32 = 1) -> UpdatePullID {
            UpdatePullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: stream))
        }

        /// A real session peer: its installer's availability, the host's Hello, then the host's offer.
        static func peer(
            offer: UpdateManifestValue? = manifest, installer: Availability<UpdateOffer>? = nil
        ) -> HostileRun {
            let run = HostileRun(local: .peer, seed: 17)
            if let installer { run.input(.update(.availability(installer))) }
            run.feed([WireFrames.hello(role: .host)], preamble: true)
            run.feed([Unit.updateAvailable(offer)])
            return run
        }

        static func effects(_ run: HostileRun) -> [UpdateEffect] {
            run.peerEffects.compactMap { if case .update(let effect) = $0 { effect } else { nil } }
        }

        /// The hash each UPDATE_PULL the peer opened asks for, by stream.
        static func pulls(_ frames: [Frame]) -> [UInt32: Data] {
            var pulls: [UInt32: Data] = [:]
            for frame in frames where frame.type == .open {
                guard let open = try? Kernova_V2_Open(serializedBytes: frame.payload), open.kind == .updatePull,
                    let body = try? Kernova_V2_UpdatePull(serializedBytes: open.body)
                else { continue }
                pulls[frame.streamID.rawValue] = body.payloadHash
            }
            return pulls
        }

        static func results(_ frames: [Frame], _ stream: UInt32 = 1) -> [Kernova_V2_UpdateResult] {
            frames.on(stream).filter { $0.type == .end }.compactMap {
                try? Kernova_V2_UpdateResult(serializedBytes: $0.payload)
            }
        }

        // MARK: The pull decision

        @Test("An offer differing from its own hash, in a format it installs, not rejected → OPEN UPDATE_PULL{hash}")
        func pulls() {
            let run = Self.peer()
            #expect(Self.pulls(run.written) == [1: Self.manifest.payloadHash])
            #expect(Self.effects(run).isEmpty)
        }

        @Test("An offer of its own hash is up to date: no pull")
        func upToDate() {
            let run = Self.peer(
                offer: UpdateManifestValue(payloadHash: Self.ownHash, payloadSize: 10, format: .executable))
            #expect(Self.pulls(run.written).isEmpty)
        }

        @Test("An offer in a format its installer does not take: no pull")
        func formatNotTaken() {
            let run = Self.peer(offer: Unit.manifest(tag: 1, size: 1_000, format: .paxTree))
            #expect(Self.pulls(run.written).isEmpty)
        }

        @Test("No offer at all: no pull")
        func noOffer() {
            let run = Self.peer(offer: nil)
            #expect(Self.pulls(run.written).isEmpty)
        }

        @Test("An offer of the install's rejected hash: no pull and the rejected hash stays")
        func rejectedHash() {
            let run = Self.peer(
                installer: .available(UpdateOffer(formats: [.executable], rejectedHash: Self.manifest.payloadHash)))
            #expect(Self.pulls(run.written).isEmpty)
            #expect(Self.effects(run).isEmpty)
        }

        @Test("An offer of another hash than the rejected one → .clearRejected, then the pull; once per offered hash")
        func clearsRejected() {
            let run = Self.peer(
                installer: .available(UpdateOffer(formats: [.executable], rejectedHash: Self.newer.payloadHash)))
            #expect(Self.effects(run) == [.clearRejected])
            #expect(Self.pulls(run.written) == [1: Self.manifest.payloadHash])
            run.feed([Unit.updateAvailable(Self.manifest)])
            #expect(Self.effects(run) == [.clearRejected])
        }

        @Test("Without an installer nothing is pulled; the installer becoming available pulls")
        func installerArrives() {
            let run = Self.peer(installer: .absent(.notImplemented, debugDetail: ""))
            #expect(Self.pulls(run.written).isEmpty)
            run.input(.update(.availability(.available(UpdateOffer(formats: [.executable])))))
            #expect(Self.pulls(run.written) == [1: Self.manifest.payloadHash])
        }

        @Test("A new offer while a pull is open opens nothing; once it closes the newer offer is pulled")
        func onePullAtATime() {
            let run = Self.peer()
            run.feed([Unit.updateAvailable(Self.newer)])
            #expect(Self.pulls(run.written).count == 1)
            run.feed([WireFrames.reset(1, code: ErrorCode.updateStale.rawValue)])
            #expect(Self.effects(run) == [.abort(Self.id())])
            #expect(Self.pulls(run.written) == [1: Self.manifest.payloadHash, 3: Self.newer.payloadHash])
        }

        @Test("An offer arriving during pull n is pulled once END(n) is handed out, not when the stream closes")
        func newOfferPulledAfterEndLeaves() {
            let run = Self.peer(installer: .available(UpdateOffer(formats: [.executable])))
            run.feed([Unit.raw(1, Data(repeating: 1, count: 1_000)), Unit.end(1)])
            run.feed([Unit.updateAvailable(Self.newer)])
            #expect(Self.pulls(run.written).keys.sorted() == [1])
            run.writerStalled = true
            run.input(.update(.installed(Self.id())))
            #expect(Self.pulls(run.written).keys.sorted() == [1])
            run.writerStalled = false
            run.drain()
            #expect(Self.results(run.written).map(\.kind) == [.staged])
            #expect(Self.pulls(run.written) == [1: Self.manifest.payloadHash, 3: Self.newer.payloadHash])
        }

        @Test("One hash is never pulled twice on one connection")
        func noSecondPullOfOneHash() {
            let run = Self.peer()
            run.feed([WireFrames.reset(1, code: ErrorCode.readFailed.rawValue)])
            run.feed([Unit.updateAvailable(Self.manifest)])
            #expect(Self.pulls(run.written).count == 1)
            run.feed([Unit.updateAvailable(Self.newer)])
            #expect(Self.pulls(run.written)[3] == Self.newer.payloadHash)
        }

        // MARK: Peer rows

        @Test("raw DATA → .payload in order; .consumed releases the held bytes")
        func payload() {
            let run = Self.peer()
            run.feed([Unit.raw(1, Data(repeating: 1, count: 400)), Unit.raw(1, Data(repeating: 2, count: 300))])
            #expect(
                Self.effects(run) == [
                    .payload(Self.id(), Data(repeating: 1, count: 400)),
                    .payload(Self.id(), Data(repeating: 2, count: 300)),
                ])
            #expect(run.connectionFootprint?.heldRawBytes == 700)
            run.input(.update(.consumed(Self.id(), 700)))
            #expect(run.connectionFootprint?.heldRawBytes == 0)
        }

        @Test("DATA past payload_size → RESET UPDATE_SIZE_MISMATCH; .abort and .recordRejected(hash)")
        func dataPastSize() {
            let run = Self.peer()
            run.feed([Unit.raw(1, Data(repeating: 1, count: 600)), Unit.raw(1, Data(repeating: 2, count: 401))])
            #expect(
                Self.effects(run) == [
                    .payload(Self.id(), Data(repeating: 1, count: 600)), .abort(Self.id()),
                    .recordRejected(Self.manifest.payloadHash),
                ])
            #expect(run.streamResets.map(\.code) == [.updateSizeMismatch])
        }

        @Test(
            "host END short of payload_size → END REJECTED UPDATE_SIZE_MISMATCH; .abort, .recordRejected")
        func endShort() {
            let run = Self.peer()
            run.feed([Unit.raw(1, Data(repeating: 1, count: 999)), Unit.end(1)])
            #expect(Self.effects(run).suffix(2) == [.abort(Self.id()), .recordRejected(Self.manifest.payloadHash)])
            let result = Self.results(run.written).first
            #expect(result?.kind == .rejected)
            #expect(result?.error.code == .updateSizeMismatch)
        }

        @Test("host END with all bytes → .complete(manifest); nothing written yet")
        func endComplete() {
            let run = Self.peer()
            run.feed([Unit.raw(1, Data(repeating: 1, count: 1_000)), Unit.end(1)])
            #expect(Self.effects(run).last == .complete(Self.id(), Self.manifest))
            #expect(Self.results(run.written).isEmpty)
        }

        @Test("installer .installed → END STAGED; the completed stream aborts nothing")
        func installed() {
            let run = Self.peer()
            run.feed([Unit.raw(1, Data(repeating: 1, count: 1_000)), Unit.end(1)])
            run.input(.update(.installed(Self.id())))
            #expect(Self.results(run.written).map(\.kind) == [.staged])
            #expect(!Self.effects(run).contains(.abort(Self.id())))
        }

        @Test("installer .rejected → END REJECTED with its error")
        func rejected() {
            let run = Self.peer()
            run.feed([Unit.raw(1, Data(repeating: 1, count: 1_000)), Unit.end(1)])
            run.input(.update(.rejected(Self.id(), WireError(.updateHashMismatch))))
            let result = Self.results(run.written).first
            #expect(result?.kind == .rejected)
            #expect(result?.error.code == .updateHashMismatch)
            #expect(!Self.effects(run).contains(.abort(Self.id())))
        }

        @Test("installer .failed mid-stream → RESET with its code")
        func failedMidStream() {
            let run = Self.peer()
            run.feed([Unit.raw(1, Data(repeating: 1, count: 500))])
            run.input(.update(.failed(Self.id(), WireError(.diskFull, posixErrno: 28))))
            #expect(run.streamResets.map(\.code) == [.diskFull])
            #expect(!Self.effects(run).contains(.abort(Self.id())))
        }

        enum Closing: String, CaseIterable, Sendable, CustomTestStringConvertible {
            case hostReset, hostResetAfterComplete, transportEnded, connectionReset

            var testDescription: String { rawValue }
        }

        @Test("The stream closing any other way → .abort", arguments: Closing.allCases)
        func closesOtherwise(_ closing: Closing) {
            let run = Self.peer()
            run.feed([Unit.raw(1, Data(repeating: 1, count: 500))])
            switch closing {
            case .hostReset:
                run.feed([WireFrames.reset(1, code: ErrorCode.readFailed.rawValue)])
            case .hostResetAfterComplete:
                run.feed([Unit.raw(1, Data(repeating: 1, count: 500)), Unit.end(1)])
                run.feed([WireFrames.reset(1, code: ErrorCode.cancelled.rawValue)])
            case .transportEnded:
                run.peer?.transportEnded(now: run.now)
                run.drain()
            case .connectionReset:
                run.feed([WireFrames.reset(0, code: ErrorCode.shuttingDown.rawValue)])
            }
            #expect(Self.effects(run).last == .abort(Self.id()))
            #expect(Self.effects(run).count { $0 == .abort(Self.id()) } == 1)
        }

        @Test("An installer report naming another generation is dropped")
        func otherGeneration() {
            let run = Self.peer()
            run.feed([Unit.raw(1, Data(repeating: 1, count: 1_000)), Unit.end(1)])
            let stale = UpdatePullID(generation: ConnectionGeneration(rawValue: 9), stream: StreamID(rawValue: 1))
            run.input(.update(.installed(stale)))
            #expect(Self.results(run.written).isEmpty)
            #expect(!run.peerEvents.contains { if case .diagnostic = $0 { true } else { false } })
        }
    }

    @Suite("UpdateServer: the offer and the host rows")
    struct UpdateServerUnitTests {
        static let bundle = SimHub.bundle(size: 4_000_000, tag: 1)
        static let offered = bundle.manifest

        static func id(_ stream: UInt32 = 1) -> UpdatePullID {
            UpdatePullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: stream))
        }

        /// A real host offering `bundle` to a session peer whose Hello claims `scope`.
        static func host(
            scope: Kernova_V2_PeerIdentity.InstallScope = .user, bundle: BundledPayload = bundle
        ) -> HostileRun {
            let run = HostileRun(local: .host, seed: 19, bundles: [bundle])
            run.feed([WireFrames.hello(role: .sessionPeer, scope: scope)], preamble: true)
            return run
        }

        static func pull(_ run: HostileRun, hash: Data = offered.payloadHash, stream: UInt32 = 1) {
            var body = Kernova_V2_UpdatePull()
            body.payloadHash = hash
            run.feed([WireFrames.open(stream, .updatePull, body: body)])
        }

        /// A host serving a matching pull of `bundle` on stream 1.
        static func serving(_ bundle: BundledPayload = bundle) -> HostileRun {
            let run = host(bundle: bundle)
            pull(run, hash: bundle.manifest.payloadHash)
            return run
        }

        /// A 1,000-byte payload, inside one grant.
        static let small = SimHub.bundle(size: 1_000, tag: 5)

        static func served(_ run: HostileRun) -> [UpdateServeEvent] {
            run.hostEvents.compactMap { if case .update(let event) = $0 { event } else { nil } }
        }

        static func grants(_ run: HostileRun) -> [Int] {
            served(run).compactMap { if case .read(_, _, let maxBytes) = $0 { maxBytes } else { nil } }
        }

        static func result(_ kind: Kernova_V2_UpdateResult.Kind, _ code: ErrorCode? = nil) -> Frame {
            var result = Kernova_V2_UpdateResult()
            result.kind = kind
            if let code { result.error.code = code }
            return Unit.end(1, Unit.encode(result))
        }

        // MARK: The offer

        @Test("The offer by role and scope: USER session peer, SYSTEM system peer; nothing else")
        func offerTable() {
            let user = SimHub.bundle(size: 10, tag: 1, scope: .user)
            let otherOS = SimHub.bundle(size: 10, tag: 2, os: .macOS, scope: .user)
            let system = SimHub.bundle(size: 10, tag: 3, scope: .system)
            let bundles = [otherOS, user, system]
            func claim(_ role: PeerRole, _ scope: InstallScope) -> PeerClaim {
                PeerClaim(role: role, scope: scope, os: .linux, architecture: .arm64)
            }
            #expect(BundledPayload.offer(from: bundles, for: claim(.sessionPeer, .user)) == user.manifest)
            #expect(BundledPayload.offer(from: bundles, for: claim(.systemPeer, .system)) == system.manifest)
            #expect(BundledPayload.offer(from: bundles, for: claim(.sessionPeer, .system)) == nil)
            #expect(BundledPayload.offer(from: bundles, for: claim(.sessionPeer, .unspecified)) == nil)
            #expect(BundledPayload.offer(from: bundles, for: claim(.systemPeer, .unspecified)) == nil)
            #expect(BundledPayload.offer(from: [system], for: claim(.sessionPeer, .user)) == nil)
        }

        @Test("Right after the peer's Hello the host sends PolicyUpdate, then UpdateAvailable with the offer")
        func offerFollowsPolicy() {
            let run = Self.host()
            let messages = run.written.filter { $0.streamID == .session && $0.type == .data }.compactMap {
                try? Kernova_V2_SessionMessage(serializedBytes: $0.payload)
            }
            let kinds = messages.map { message -> String in
                switch message.message {
                case .hello: "hello"
                case .policy: "policy"
                case .updateAvailable: "updateAvailable"
                default: "other"
                }
            }
            #expect(kinds == ["hello", "policy", "updateAvailable"])
            #expect(messages.last?.updateAvailable.manifest.payloadHash == Self.offered.payloadHash)
        }

        // MARK: Host rows

        @Test("OPEN while the host offers this peer nothing → RESET UPDATE_UNAVAILABLE, checked before the hash")
        func unavailable() {
            let run = Self.host(scope: .unspecified)
            Self.pull(run, hash: Data(repeating: 7, count: 32))
            #expect(run.streamResets.map(\.code) == [.updateUnavailable])
            #expect(Self.served(run).isEmpty)
        }

        @Test("OPEN with a hash other than the offered manifest's → RESET UPDATE_STALE")
        func stale() {
            let run = Self.host()
            Self.pull(run, hash: Data(repeating: 7, count: 32))
            #expect(run.streamResets.map(\.code) == [.updateStale])
            #expect(Self.served(run).isEmpty)
        }

        @Test("OPEN with the offered hash → .pullRequested(manifest), then a read grant within writableData")
        func pullRequested() {
            let run = Self.serving()
            #expect(
                Self.served(run) == [
                    .pullRequested(Self.id(), Self.offered), .read(Self.id(), offset: 0, maxBytes: 262_144),
                ])
        }

        @Test("A second UPDATE_PULL while one is open → RESET UPDATE_IN_PROGRESS")
        func secondPull() {
            let run = Self.serving()
            Self.pull(run, stream: 3)
            #expect(run.streamResets.map(\.stream) == [3])
            #expect(run.streamResets.map(\.code) == [.updateInProgress])
        }

        @Test("Grants are demand-driven: one outstanding at a time, the next after the bytes, none below 64 KiB")
        func grantsOnDemand() {
            let run = Self.serving()
            run.feed([WireFrames.window(1, 8_388_608 - 262_144)])
            #expect(Self.grants(run) == [262_144])
            run.command(.updateBytes(Self.id(), Data(repeating: 4, count: 100_000)))
            #expect(run.written.on(1).filter { $0.type == .data }.map(\.payload.count) == [100_000])
            #expect(Self.grants(run) == [262_144, 1_048_576])
        }

        @Test("With credit spent no grant is made; credit rising past 64 KiB grants again")
        func grantAfterCredit() {
            let run = Self.serving()
            run.command(.updateBytes(Self.id(), Data(repeating: 4, count: 262_144 - 1_000)))
            #expect(Self.grants(run) == [262_144])
            run.feed([WireFrames.window(1, 70_000)])
            #expect(Self.grants(run) == [262_144, 71_000])
        }

        @Test("Bytes past the grant → RESET READ_FAILED with a diagnostic (as built)")
        func bytesPastGrant() {
            let run = Self.serving()
            run.command(.updateBytes(Self.id(), Data(repeating: 4, count: 262_145)))
            #expect(run.streamResets.map(\.code) == [.readFailed])
            #expect(run.hostEvents.contains { if case .diagnostic(.localFault) = $0 { true } else { false } })
        }

        @Test("Each read is capped at payload_size − sent, from the offset served so far")
        func grantsCappedAtSize() {
            let run = Self.serving(Self.small)
            run.command(.updateBytes(Self.id(), Data(repeating: 4, count: 400)))
            #expect(
                Self.served(run).dropFirst() == [
                    .read(Self.id(), offset: 0, maxBytes: 1_000), .read(Self.id(), offset: 400, maxBytes: 600),
                ])
        }

        @Test("payload_size bytes served → the server ENDs (empty) by itself and asks for no more")
        func endsAtSize() {
            let run = Self.serving(Self.small)
            run.command(.updateBytes(Self.id(), Data(repeating: 4, count: 400)))
            run.command(.updateBytes(Self.id(), Data(repeating: 4, count: 600)))
            let frames = run.written.on(1)
            #expect(frames.filter { $0.type == .data }.map(\.payload.count) == [400, 600])
            #expect(frames.last?.type == .end)
            #expect(frames.last?.payload.isEmpty == true)
            #expect(Self.grants(run) == [1_000, 600])
        }

        @Test("The source returning no bytes short of payload_size → RESET READ_FAILED and a local fault")
        func emptyReadIsSourceFault() {
            let run = Self.serving(Self.small)
            run.command(.updateBytes(Self.id(), Data(repeating: 4, count: 400)))
            run.command(.updateBytes(Self.id(), Data()))
            #expect(run.streamResets.map(\.code) == [.readFailed])
            #expect(!run.written.on(1).contains { $0.type == .end })
            #expect(run.hostEvents.contains { if case .diagnostic(.localFault) = $0 { true } else { false } })
            #expect(Self.served(run).last == .closed(Self.id(), .resetLocally(Self.readFailed(run))))
        }

        @Test("Bytes no read asked for, on a live pull → RESET READ_FAILED and a local fault, nothing sent")
        func unsolicitedBytesAreSourceFault() {
            let run = Self.serving(Self.small)
            run.command(.updateBytes(Self.id(), Data(repeating: 4, count: 400)))
            run.command(.updateBytes(Self.id(), Data(repeating: 4, count: 600)))
            let ended = run.written.on(1).count
            run.command(.updateBytes(Self.id(), Data(repeating: 4, count: 10)))
            #expect(run.written.on(1).count == ended)

            let live = Self.serving()
            live.command(.updateBytes(Self.id(), Data(repeating: 4, count: 100_000)))
            live.command(.updateBytes(Self.id(), Data(repeating: 4, count: 100_000)))
            live.command(.updateBytes(Self.id(), Data(repeating: 4, count: 10)))
            #expect(live.streamResets.map(\.code) == [.readFailed])
            #expect(live.written.on(1).filter { $0.type == .data }.map(\.payload.count) == [100_000, 100_000])
            #expect(live.hostEvents.contains { if case .diagnostic(.localFault) = $0 { true } else { false } })
        }

        /// The READ_FAILED this run's server reset its pull with.
        static func readFailed(_ run: HostileRun) -> WireError {
            for case .update(.closed(_, .resetLocally(let error))) in run.hostEvents { return error }
            return WireError(.unspecified)
        }

        @Test("The payload source failing → RESET READ_FAILED, and .closed without a result")
        func sourceFailed() {
            let run = Self.serving()
            run.command(.updateFailed(Self.id(), WireError(.readFailed)))
            #expect(run.streamResets.map(\.code) == [.readFailed])
            #expect(Self.served(run).last == .closed(Self.id(), .resetLocally(WireError(.readFailed))))
        }

        @Test("The offer changing while the pull is open → RESET UPDATE_STALE and .closed")
        func offerChanges() {
            let run = Self.serving()
            run.command(.setBundles([SimHub.bundle(size: 100_000, tag: 2)]))
            #expect(run.streamResets.map(\.code) == [.updateStale])
            #expect(Self.served(run).last == .closed(Self.id(), .resetLocally(WireError(.updateStale))))
        }

        @Test("The offer withdrawn while the pull is open → RESET UPDATE_STALE")
        func offerWithdrawn() {
            let run = Self.serving()
            run.command(.setBundles([]))
            #expect(run.streamResets.map(\.code) == [.updateStale])
        }

        @Test("Bundles re-sent unchanged leave the pull alone")
        func offerUnchanged() {
            let run = Self.serving()
            run.command(.setBundles([Self.bundle]))
            #expect(run.streamResets.isEmpty)
        }

        @Test(
            "peer END after the host's → .result with the peer's verdict, and no .closed",
            arguments: [
                (Kernova_V2_UpdateResult.Kind.staged, ErrorCode?.none),
                (.rejected, ErrorCode.updateHashMismatch),
            ])
        func result(_ kind: Kernova_V2_UpdateResult.Kind, _ code: ErrorCode?) {
            let run = Self.serving(Self.small)
            run.command(.updateBytes(Self.id(), Data(repeating: 4, count: 1_000)))
            run.feed([Self.result(kind, code)])
            let expected = UpdateResultValue(
                kind: kind == .staged ? .staged : .rejected, error: code.map { WireError($0) })
            #expect(Self.served(run).last == .result(Self.id(), expected))
            #expect(!Self.served(run).contains { if case .closed = $0 { true } else { false } })
        }

        @Test("The stream closing without a result → .closed with the closure")
        func closedWithoutResult() {
            let reset = Self.serving()
            reset.feed([WireFrames.reset(1, code: ErrorCode.diskFull.rawValue)])
            #expect(Self.served(reset).last == .closed(Self.id(), .resetByPeer(WireError(.diskFull))))

            let lost = Self.serving()
            lost.host?.transportEnded(now: lost.now)
            lost.drain()
            #expect(Self.served(lost).last == .closed(Self.id(), .connectionLost))
        }

        @Test("A peer END before the host's is out of grammar: RESET STREAM_PROTOCOL_ERROR (as built)")
        func earlyPeerEnd() {
            let run = Self.serving()
            run.feed([Self.result(.staged)])
            #expect(run.streamResets.map(\.code) == [.streamProtocolError])
            #expect(!Self.served(run).contains { if case .result = $0 { true } else { false } })
        }

        @Test("A command naming another generation is dropped")
        func otherGeneration() {
            let run = Self.serving()
            let stale = UpdatePullID(generation: ConnectionGeneration(rawValue: 4), stream: StreamID(rawValue: 1))
            run.command(.updateFailed(stale, WireError(.readFailed)))
            run.command(.updateBytes(stale, Data(repeating: 1, count: 10)))
            #expect(run.streamResets.isEmpty)
            #expect(run.written.on(1).filter { $0.type == .data }.isEmpty)
        }
    }
}
