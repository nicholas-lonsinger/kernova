#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaPlatformPOSIX
import KernovaWire
import Testing

/// A host driver and a `PeerAgentRuntime` with fake adapters, joined by a real `socketpair` through
/// `POSIXByteStream`, on the platform clock.
final class SocketPair: Sendable {
    static let payloadSize = 3 * 1_048_576
    static let manifest = UpdateManifestValue(
        payloadHash: Data(repeating: 0xC3, count: 32), payloadSize: UInt64(payloadSize), format: .executable,
        versionLabel: "next")

    let hostEvents = Recorder<HostEvent>()
    let peerEvents = Recorder<PeerEvent>()
    let stops = Recorder<StopReason>()
    let hostStream: GatedStream
    let peerStream: GatedStream
    let dialer: OneShotDialer
    let power: FakePowerAdapter
    let installer: FakeInstaller
    let source: FakePayloadSource
    let logs = LogForwarding()
    let peer: PeerAgentRuntime
    let host: HostConnection
    private let hub = DispatchQueue(label: "app.kernova.tests.hub")

    /// How the host bundles `manifest`.
    enum Bundled {
        /// Not at all.
        case nothing
        /// As an update it offers.
        case inBand
        /// Only as the payload a current peer runs.
        case notInBand
    }

    /// A pair whose host bundles `manifest` as `bundled` says.
    init(
        peerSendBuffer: Int32? = nil, bundled: Bundled = .inBand, handsOff: Bool = true, stallAfter: Int? = nil,
        sourceShortBy: Int = 0, refuses: ErrorCode? = nil
    ) throws {
        let descriptors = try RawSocket.pair(sendBuffer: peerSendBuffer)
        hostStream = GatedStream(try POSIXByteStream(adopting: descriptors.far))
        peerStream = GatedStream(try POSIXByteStream(adopting: descriptors.stream))
        dialer = OneShotDialer(peerStream)
        power = FakePowerAdapter(handsOff: handsOff)
        let content = FakePayloadSource.payload(Self.payloadSize)
        installer = FakeInstaller(expected: content, refuses: refuses)
        source = FakePayloadSource(
            content: Data(content.prefix(Self.payloadSize - sourceShortBy)), stallAfter: stallAfter)

        let hostEvents = hostEvents
        let peerEvents = peerEvents
        let stops = stops
        let runtime = HostConnectionRuntime(
            claim: Fixture.hostClaim, scheduler: SystemScheduler(), payloadSource: source, logger: Fixture.logger)
        host = runtime.makeConnection(
            hostStream, policy: Fixture.logsEnabled,
            bundles: bundled == .nothing
                ? []
                : [
                    BundledPayload(
                        os: .linux, architecture: .arm64, scope: .user, manifest: Self.manifest,
                        updatesInBand: bundled == .inBand)
                ],
            deliveringOn: hub
        ) { event in hostEvents.record(event) }
        host.start()
        peer = PeerAgentRuntime(
            claim: Fixture.peerClaim, state: Fixture.peerState,
            registry: PeerFeatureRegistry(power: power, logs: logs, update: installer), dialer: dialer,
            scheduler: SystemScheduler(), logger: Fixture.logger,
            handlers: PeerAgentRuntime.Handlers(event: { peerEvents.record($0) }, stop: { stops.record($0) }))
        peer.start()
    }

    /// Stops the peer; it closes its connection, if one is up, before the completion.
    func finish() async {
        await withCheckedContinuation { continuation in peer.close { continuation.resume() } }
        host.send(.close(.shuttingDown, retryAfter: nil))
    }

    static func record(_ index: Int) -> LogRecordValue {
        LogRecordValue(
            timestampMilliseconds: 0, level: .notice, subsystem: "app.kernova.tests", category: "Flood",
            segments: [LogSegmentValue(text: "record \(index) " + String(repeating: "x", count: 1_000))])
    }
}

extension HostEvent {
    var isHello: Bool {
        if case .helloReceived = self { return true }
        return false
    }

    var isClosed: Bool {
        if case .closed = self { return true }
        return false
    }

    var isPower: Bool {
        if case .power = self { return true }
        return false
    }

    var isUpdateResult: Bool {
        if case .update(.result) = self { return true }
        return false
    }

    var powerUsable: Bool {
        if case .featuresChanged(let table) = self { return table[.power].isAvailable }
        return false
    }
}

extension PeerEvent {
    var isClosed: Bool {
        if case .closed = self { return true }
        return false
    }
}

extension SocketTests {
    @Suite("Runtime over a socket pair")
    struct SocketPairTests {
        @Test("Both Hellos complete")
        func helloCompletes() async throws {
            let pair = try SocketPair()
            var host = pair.hostEvents.waiter()
            var peer = pair.peerEvents.waiter()
            let hello = await host.next { $0.isHello }
            guard case .helloReceived(let claim, let state) = hello else {
                Issue.record("no Hello")
                return
            }
            #expect(claim.role == .sessionPeer)
            #expect(claim.instanceID.count == 16)
            #expect(claim.instanceID != Fixture.peerClaim.instanceID)
            #expect(state.sessionID == "1")
            let established = await peer.next {
                if case .established = $0 { return true }
                return false
            }
            #expect(established == .established(host: Fixture.hostClaim))
            await pair.finish()
        }

        @Test("A power request reaches the adapter and its outcome comes back")
        func powerRequest() async throws {
            let pair = try SocketPair()
            var host = pair.hostEvents.waiter()
            _ = await host.next { $0.powerUsable }
            let id = PowerRequestID(generation: pair.host.generation, rawValue: 1)
            pair.host.send(.requestPower(id, .shutdown))
            var performed = pair.power.performed.waiter()
            _ = await performed.next { _ in true }
            let accepted = await host.next(where: \.isPower)
            #expect(accepted == .power(id, .accepted))
            let finished = await host.next(where: \.isPower)
            #expect(finished == .power(id, .finished(.handedOff)))
            await pair.finish()
        }

        @Test("An update offer is pulled, written and installed")
        func updatePull() async throws {
            let pair = try SocketPair()
            var host = pair.hostEvents.waiter()
            let result = await host.next(where: \.isUpdateResult)
            guard case .update(.result(_, let value)) = result else {
                Issue.record("no result")
                return
            }
            #expect(value.kind == .staged)
            #expect(pair.installer.calls.elements == ["complete \(SocketPair.payloadSize)"])
            await pair.finish()
        }

        @Test("A payload bundled but not updating in band is never offered, so the peer pulls nothing")
        func notInBandIsNeverPulled() async throws {
            let pair = try SocketPair(bundled: .notInBand)
            var peer = pair.peerEvents.waiter()
            let available = await peer.next {
                if case .updateAvailable = $0 { return true }
                return false
            }
            #expect(available == .updateAvailable(nil))
            await pair.finish()
            #expect(!pair.hostEvents.elements.contains { if case .update = $0 { true } else { false } })
            #expect(pair.installer.calls.elements.isEmpty)
        }

        @Test("A RESET(0) SUPERSEDED that arrives behind a failed write stops the peer instead of redialing")
        func supersededAfterWriteErrorStops() async throws {
            let pair = try SocketPair(peerSendBuffer: 4_096, bundled: .nothing)
            var peer = pair.peerEvents.waiter()
            _ = await peer.next { $0.isPolicyReceived }

            pair.hostStream.gate()
            var writes = pair.peerStream.writes.waiterFromNow()
            for index in 0..<400 { pair.logs.append(SocketPair.record(index)) }
            _ = await writes.next { $0 == nil }
            pair.peerStream.gate()

            pair.host.send(.close(.superseded, retryAfter: nil))
            _ = await writes.next { $0 != nil && $0 != .some(nil) }
            pair.peerStream.release()

            let closed = await peer.next { $0.isClosed }
            #expect(closed == .closed(.closedByPeer(WireError(.superseded))))
            var stops = pair.stops.waiter()
            #expect(await stops.next { _ in true } == .superseded)
            #expect(pair.dialer.dials.elements == [1])
        }
    }
}
#endif
