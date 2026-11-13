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

        @Test("An offer of another hash than the rejected one → .clearRejected, then the pull; once per offered hash")
        func clearsRejected() {
            let run = Self.peer(
                installer: .available(
                    UpdateOffer(formats: [.executable], rejected: RejectedPayload(hash: Self.newer.payloadHash))))
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

        // MARK: Peer rows

        @Test("The peer closing for its relaunch right after .installed still sends END STAGED, before RESET(0)")
        func installedThenRelaunch() {
            let run = Self.peer()
            run.feed([Unit.raw(1, Data(repeating: 1, count: 1_000)), Unit.end(1)])
            run.writerStalled = true
            run.input(.update(.installed(Self.id())))
            run.peer?.close(.shuttingDown, now: run.now)
            run.writerStalled = false
            run.drain()
            #expect(Self.results(run.written).map(\.kind) == [.staged])
            let end = run.written.firstIndex { $0.streamID.rawValue == 1 && $0.type == .end }
            let close = run.written.firstIndex { $0.streamID == .session && $0.type == .reset }
            #expect(end != nil && close != nil && end! < close!)
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
            run.hostEffects.compactMap { if case .read(_, _, _, let maxBytes) = $0 { maxBytes } else { nil } }
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

        @Test("The install's bundle by role and scope: USER for its session peer, SYSTEM for either of its peers")
        func installBundleTable() {
            let user = SimHub.bundle(size: 10, tag: 1, scope: .user)
            let otherOS = SimHub.bundle(size: 10, tag: 2, os: .macOS, scope: .user)
            let system = SimHub.bundle(size: 10, tag: 3, scope: .system)
            let bundles = [otherOS, user, system]
            func claim(_ role: PeerRole, _ scope: InstallScope) -> PeerClaim {
                PeerClaim(role: role, scope: scope, os: .linux, architecture: .arm64)
            }
            #expect(BundledPayload.installBundle(from: bundles, for: claim(.sessionPeer, .user)) == user)
            #expect(BundledPayload.installBundle(from: bundles, for: claim(.systemPeer, .system)) == system)
            #expect(BundledPayload.installBundle(from: bundles, for: claim(.sessionPeer, .system)) == system)
            #expect(BundledPayload.installBundle(from: bundles, for: claim(.systemPeer, .user)) == nil)
            #expect(BundledPayload.installBundle(from: bundles, for: claim(.sessionPeer, .unspecified)) == nil)
            #expect(BundledPayload.installBundle(from: [user], for: claim(.sessionPeer, .system)) == nil)
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
            #expect(Self.served(run) == [.pullRequested(Self.id(), Self.offered)])
            #expect(run.hostEffects == [.read(Self.id(), Self.offered, offset: 0, maxBytes: 262_144)])
        }

        @Test("Bytes past the grant → RESET READ_FAILED with a diagnostic (as built)")
        func bytesPastGrant() {
            let run = Self.serving()
            run.payload(.bytes(Self.id(), Data(repeating: 4, count: 262_145)))
            #expect(run.streamResets.map(\.code) == [.readFailed])
            #expect(run.hostEvents.contains { if case .diagnostic(.localFault) = $0 { true } else { false } })
        }

        @Test("payload_size bytes served → the server ENDs (empty) by itself and asks for no more")
        func endsAtSize() {
            let run = Self.serving(Self.small)
            run.payload(.bytes(Self.id(), Data(repeating: 4, count: 400)))
            run.payload(.bytes(Self.id(), Data(repeating: 4, count: 600)))
            let frames = run.written.on(1)
            #expect(frames.filter { $0.type == .data }.map(\.payload.count) == [400, 600])
            #expect(frames.last?.type == .end)
            #expect(frames.last?.payload.isEmpty == true)
            #expect(Self.grants(run) == [1_000, 600])
        }

        @Test("Bytes no read asked for, on a live pull → RESET READ_FAILED and a local fault, nothing sent")
        func unsolicitedBytesAreSourceFault() {
            let run = Self.serving(Self.small)
            run.payload(.bytes(Self.id(), Data(repeating: 4, count: 400)))
            run.payload(.bytes(Self.id(), Data(repeating: 4, count: 600)))
            let ended = run.written.on(1).count
            run.payload(.bytes(Self.id(), Data(repeating: 4, count: 10)))
            #expect(run.written.on(1).count == ended)

            let live = Self.serving()
            live.payload(.bytes(Self.id(), Data(repeating: 4, count: 100_000)))
            live.payload(.bytes(Self.id(), Data(repeating: 4, count: 100_000)))
            live.payload(.bytes(Self.id(), Data(repeating: 4, count: 10)))
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
            run.payload(.failed(Self.id(), WireError(.readFailed)))
            #expect(run.streamResets.map(\.code) == [.readFailed])
            #expect(Self.served(run).last == .closed(Self.id(), .resetLocally(WireError(.readFailed))))
        }

        @Test("A peer END before the host's is out of grammar: RESET STREAM_PROTOCOL_ERROR (as built)")
        func earlyPeerEnd() {
            let run = Self.serving()
            run.feed([Self.result(.staged)])
            #expect(run.streamResets.map(\.code) == [.streamProtocolError])
            #expect(!Self.served(run).contains { if case .result = $0 { true } else { false } })
        }
    }
}
