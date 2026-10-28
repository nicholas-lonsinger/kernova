#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaWire
import KernovaLogging
import KernovaSynchronization

/// The host's side of the agent protocol: one `ConnectionDriver` with a new `HostEndpoint` per accepted
/// stream, and the update payload source behind every pull (§9.5).
public final class HostConnectionRuntime: Sendable {
    private let claim: PeerClaim
    private let scheduler: any RuntimeScheduler
    private let payloadSource: any UpdatePayloadSource
    private let logger: KernovaLogger
    private let receiverPolicy: ReceiverPolicy
    private let generations = Locked<UInt64>(0)

    /// A runtime whose Hello carries `claim` and whose pulls read from `payloadSource`.
    public init(
        claim: PeerClaim, scheduler: any RuntimeScheduler, payloadSource: any UpdatePayloadSource,
        logger: KernovaLogger, receiverPolicy: ReceiverPolicy = .production
    ) {
        self.claim = claim
        self.scheduler = scheduler
        self.payloadSource = payloadSource
        self.logger = logger
        self.receiverPolicy = receiverPolicy
    }

    /// Starts a connection over `stream` with a fresh session token. Its events reach `handler` with
    /// `async` on `queue`, the hub's; update `.writable` events are the runtime's own and never reach it.
    public func accept(
        _ stream: any ByteStream, policy: PolicySnapshot, bundles: [BundledPayload], deliveringOn queue: DispatchQueue,
        _ handler: @escaping @Sendable (HostEvent) -> Void
    ) -> HostConnection {
        let generation = generations.withLock { count in
            count += 1
            return ConnectionGeneration(rawValue: count)
        }
        var generator = SystemRandomNumberGenerator()
        let token = Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        var configuration = HostConfiguration(claim: claim, sessionToken: token, policy: policy, bundles: bundles)
        configuration.receiverPolicy = receiverPolicy
        let serving = PayloadServing(source: payloadSource)
        let driver = ConnectionDriver(
            endpoint: HostEndpoint(configuration, generation: generation, now: scheduler.now), stream: stream,
            scheduler: scheduler, logger: logger,
            handlers: ConnectionDriver<HostEndpoint>.Handlers(event: { event, driver in
                guard serving.handle(event, driver: driver) else { return }
                queue.async { handler(event) }
            }))
        driver.start()
        return HostConnection(driver: driver)
    }
}

/// One accepted connection, as the hub holds it.
public struct HostConnection: Sendable {
    let driver: ConnectionDriver<HostEndpoint>

    /// The connection's generation; every id it hands out carries it.
    public var generation: ConnectionGeneration { driver.generation }

    /// Sends `command` to the connection's driver with `async`.
    public func send(_ command: HostCommand) {
        driver.handle(command)
    }
}

/// Feeds one connection's pulls from the payload source: each `.writable` reads exactly the bytes the
/// core granted, which it caps at what the pull still owes, and the core ends the pull once they are sent.
private final class PayloadServing: Sendable {
    private let source: any UpdatePayloadSource
    /// Each open pull's manifest; touched only on the driver queue.
    private let manifests = Locked<[UpdatePullID: UpdateManifestValue]>([:])

    init(source: any UpdatePayloadSource) {
        self.source = source
    }

    /// Acts on `event`; true when the hub should see it too.
    func handle(_ event: HostEvent, driver: ConnectionDriver<HostEndpoint>) -> Bool {
        guard case .update(let serve) = event else { return true }
        switch serve {
        case .pullRequested(let id, let manifest):
            manifests.withLock { $0[id] = manifest }
            return true
        case .writable(let id, let maxBytes):
            guard let manifest = manifests.withLock({ $0[id] }) else { return false }
            source.read(id, manifest: manifest, maxBytes: maxBytes) { result in
                switch result {
                case .success(let bytes): driver.handle(.updateBytes(id, bytes))
                case .failure(let error): driver.handle(.updateFailed(id, error))
                }
            }
            return false
        case .result(let id, _), .closed(let id, _):
            manifests.withLock { $0[id] = nil }
            return true
        }
    }
}
