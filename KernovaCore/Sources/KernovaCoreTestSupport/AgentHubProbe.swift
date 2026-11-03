import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaSynchronization

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

/// Stands in for a VM's host connections and transport, so a test sees what
/// `VMInstance` drives its agent hub to do: each connection's commands, and
/// each stream the hub's acceptor shuts down.
///
/// Its connections never start a driver, so nothing is read or written.
package final class AgentHubProbe: HostConnectionMaking, GuestStreamTransport {
    private struct State: Sendable {
        var acceptor: GuestStreamAcceptor?
        var commands: [HostCommand] = []
        var policies: [PolicySnapshot] = []
        var bundles: [[BundledPayload]] = []
        var handlers: [(queue: DispatchQueue, handler: @Sendable (HostEvent) -> Void)] = []
        var shutdowns = 0
    }

    private let state = Locked(State())
    /// Notified on every change a test waits for.
    package let changed = AsyncGate()

    package init() {}

    /// Every command sent to any connection, in order.
    package var commands: [HostCommand] { state.withLock(\.commands) }
    /// The policy each connection was built with, in order.
    package var policies: [PolicySnapshot] { state.withLock(\.policies) }
    /// The bundles each connection was built to offer, in order.
    package var bundles: [[BundledPayload]] { state.withLock(\.bundles) }
    /// How many accepted streams have been shut down.
    package var shutdowns: Int { state.withLock(\.shutdowns) }
    /// Whether a hub has started this transport.
    package var isStarted: Bool { state.withLock { $0.acceptor != nil } }

    /// Opens one connection through the acceptor the hub started this
    /// transport with, answering whether it was accepted.
    package func connect() -> Bool {
        guard let acceptor = state.withLock(\.acceptor) else { return false }
        return acceptor.offer { [self] released in InertStream(probe: self, released: released) }
    }

    /// Delivers `event` to the hub as connection `index` (from 0, in accept order) reports it: on the
    /// queue the hub built the connection to deliver on.
    package func deliver(_ event: HostEvent, fromConnection index: Int) {
        let (queue, handler) = state.withLock { $0.handlers[index] }
        queue.async { handler(event) }
    }

    // MARK: GuestStreamTransport

    package func start(admitting acceptor: GuestStreamAcceptor) {
        state.withLock { $0.acceptor = acceptor }
        changed.notify()
    }

    package func stop() {}

    // MARK: HostConnectionMaking

    package func makeConnection(
        _ stream: any ByteStream, policy: PolicySnapshot, bundles: [BundledPayload],
        deliveringOn queue: DispatchQueue, _ handler: @escaping @Sendable (HostEvent) -> Void
    ) -> any HostConnectionHandle {
        let index = state.withLock { state in
            state.policies.append(policy)
            state.bundles.append(bundles)
            state.handlers.append((queue, handler))
            return state.handlers.count
        }
        changed.notify()
        return Connection(probe: self, generation: ConnectionGeneration(rawValue: UInt64(index)))
    }

    private struct Connection: HostConnectionHandle {
        let probe: AgentHubProbe
        /// From 1, in accept order.
        let generation: ConnectionGeneration

        func start() {}

        func send(_ command: HostCommand) {
            probe.state.withLock { $0.commands.append(command) }
            probe.changed.notify()
        }
    }

    /// A stream that delivers nothing and counts its shutdown.
    private final class InertStream: ByteStream {
        private let probe: AgentHubProbe
        private let released: @Sendable () -> Void
        private let isShutDown = Locked(false)

        init(probe: AgentHubProbe, released: @escaping @Sendable () -> Void) {
            self.probe = probe
            self.released = released
        }

        func start(on queue: DispatchQueue, _ handler: @escaping @Sendable (ByteStreamEvent) -> Void) {}
        func readMore() {}
        func write(_ chunks: [Data], _ completion: @escaping @Sendable (ByteStreamError?) -> Void) {}

        func shutdown() {
            let first = isShutDown.withLock { isShutDown in
                defer { isShutDown = true }
                return !isShutDown
            }
            guard first else { return }
            probe.state.withLock { $0.shutdowns += 1 }
            released()
            probe.changed.notify()
        }
    }
}
