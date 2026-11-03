#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaSynchronization

/// Connections that never run a driver: the test delivers their events and reads the commands the hub sends
/// them, each by connection number, from 0 in accept order.
final class ScriptedConnector: HostConnectionMaking {
    private struct Connection: HostConnectionHandle {
        let generation: ConnectionGeneration
        let number: Int
        let commands: Recorder<(connection: Int, command: HostCommand)>

        func start() {}

        func send(_ command: HostCommand) { commands.record((number, command)) }
    }

    private let handlers = Locked<[(queue: DispatchQueue, handler: @Sendable (HostEvent) -> Void)]>([])
    /// Every command the hub sent, by connection number.
    let commands = Recorder<(connection: Int, command: HostCommand)>()

    func makeConnection(
        _ stream: any ByteStream, policy: PolicySnapshot, bundles: [BundledPayload],
        deliveringOn queue: DispatchQueue, _ handler: @escaping @Sendable (HostEvent) -> Void
    ) -> any HostConnectionHandle {
        let number = handlers.withLock { handlers in
            handlers.append((queue, handler))
            return handlers.count - 1
        }
        return Connection(
            generation: ConnectionGeneration(rawValue: UInt64(number + 1)), number: number, commands: commands)
    }

    /// Delivers `event` to the hub as connection `number`'s, after every event delivered before it.
    func deliver(_ event: HostEvent, _ number: Int) {
        let (queue, handler) = handlers.withLock { $0[number] }
        queue.async { handler(event) }
    }

    /// The commands the hub sent connection `number`, in order.
    func commands(to number: Int) -> [HostCommand] {
        commands.elements.filter { $0.connection == number }.map(\.command)
    }
}
