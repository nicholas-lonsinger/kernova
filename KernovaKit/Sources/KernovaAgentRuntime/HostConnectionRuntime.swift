#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaLogging
import KernovaSynchronization
import KernovaWire

/// The host's side of the agent protocol: one `ConnectionDriver` with a new `HostEndpoint` per accepted
/// stream, each endpoint's payload reads answered by the update payload source and its item effects by
/// the item adapters.
public final class HostConnectionRuntime: Sendable {
    private let claim: PeerClaim
    private let scheduler: any RuntimeScheduler
    private let payloadSource: any UpdatePayloadSource
    private let items: ItemAdapters?
    private let logger: KernovaLogger
    private let receiverPolicy: ReceiverPolicy
    private let generations = Locked<UInt64>(0)

    /// A runtime whose Hello carries `claim`, whose update pulls read from `payloadSource`, and whose item
    /// transfer `items` serves; without them, item transfer is advertised absent `NOT_IMPLEMENTED`.
    public init(
        claim: PeerClaim, scheduler: any RuntimeScheduler, payloadSource: any UpdatePayloadSource,
        items: ItemAdapters? = nil, logger: KernovaLogger, receiverPolicy: ReceiverPolicy = .production
    ) {
        self.claim = claim
        self.scheduler = scheduler
        self.payloadSource = payloadSource
        self.items = items
        self.logger = logger
        self.receiverPolicy = receiverPolicy
    }

    /// A connection over `stream` with a fresh session token, not yet started: nothing reaches `handler`,
    /// with `async` on `queue`, the hub's, until `HostConnection.start()`.
    public func makeConnection(
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
        configuration.itemTransfer = ItemAdapters.availability(items)
        let source = payloadSource
        let items = items
        let driver = ConnectionDriver(
            endpoint: HostEndpoint(configuration, generation: generation, now: scheduler.now), stream: stream,
            scheduler: scheduler, logger: logger,
            handlers: ConnectionDriver<HostEndpoint>.Handlers(
                effect: { effect, driver in
                    switch effect {
                    case .read(let id, let manifest, let offset, let maxBytes):
                        source.read(manifest: manifest, offset: offset, count: maxBytes) { result in
                            switch result {
                            case .success(let bytes): driver.handle(.payload(.bytes(id, bytes)))
                            case .failure(let error): driver.handle(.payload(.failed(id, error)))
                            }
                        }
                    case .itemSource(let effect):
                        items?.source.handle(
                            effect, reporter: ItemSourceReporter { driver.handle(.items(.source($0))) })
                    case .itemSink(let effect):
                        items?.sink.handle(effect, reporter: ItemSinkReporter { driver.handle(.items(.sink($0))) })
                    }
                },
                event: { event, _ in queue.async { handler(event) } }))
        return HostConnection(driver: driver)
    }
}

/// One accepted connection, as the hub holds it.
public struct HostConnection: Sendable {
    let driver: ConnectionDriver<HostEndpoint>

    /// The connection's generation; every id it hands out carries it.
    public var generation: ConnectionGeneration { driver.generation }

    /// Starts the stream's events and writes the preamble and Hello.
    public func start() {
        driver.start()
    }

    /// Sends `command` to the connection's driver with `async`.
    public func send(_ command: HostCommand) {
        driver.handle(.hub(command))
    }
}
