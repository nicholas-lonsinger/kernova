#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// The item commands an end awaits answers to, each with the connection asked and what its answer is for: the
/// one place an end draws `ItemRequestID`s, so no two callers' commands share one.
package struct ItemRequests<Connection: Hashable & Sendable>: Sendable {
    package struct Pending: Sendable {
        package var connection: Connection
        package var command: ItemCommand
        /// A pull's: the feature of the offer it names, where the end tracks it.
        package var feature: FeatureID?
        /// Receives the answer, or nil when the connection ended without one.
        package var answer: @Sendable (ItemReply?) -> Void
    }

    /// The error of an item call whose connection was gone, or ended before answering.
    package static var connectionEnded: WireError {
        WireError(.shuttingDown, debugDetail: "the connection ended before answering")
    }

    private var pending: [ItemRequestID: Pending] = [:]
    private var nextRequest: UInt64 = 0

    package init() {}

    /// Records `command`, the one `build` makes around a fresh id, to `connection`, whose answer `answer`
    /// receives; `feature` is a pull's, as `Pending.feature` says.
    package mutating func add(
        _ connection: Connection, _ build: (ItemRequestID) -> ItemCommand, feature: FeatureID?,
        _ answer: @escaping @Sendable (ItemReply?) -> Void
    ) -> ItemCommand {
        nextRequest += 1
        let id = ItemRequestID(rawValue: nextRequest)
        let command = build(id)
        pending[id] = Pending(connection: connection, command: command, feature: feature, answer: answer)
        return command
    }

    /// The request `connection` answered with `id`, which it removes.
    package mutating func take(_ id: ItemRequestID, from connection: Connection) -> Pending? {
        guard pending[id]?.connection == connection else { return nil }
        return pending.removeValue(forKey: id)
    }

    /// Every request asked of `connection`, which it removes: the connection ended, so none is answered.
    package mutating func takeAll(of connection: Connection) -> [Pending] {
        let ended = pending.filter { $0.value.connection == connection }
        for id in ended.keys { pending[id] = nil }
        return ended.sorted { $0.key.rawValue < $1.key.rawValue }.map(\.value)
    }
}

extension ItemRequests {
    /// A `Pending.answer` calling `completion` once with what `read` reads from the reply: the endpoint answers
    /// each command with that command's kind of reply, so only no reply at all is `unanswered`.
    package static func answering<Answer: Sendable>(
        _ read: @escaping @Sendable (ItemReply) -> Answer?, unanswered: Answer,
        _ completion: @escaping @Sendable (Answer) -> Void
    ) -> @Sendable (ItemReply?) -> Void {
        { reply in
            let answer = reply.flatMap(read)
            assert(reply == nil || answer != nil, "a reply answering another command")
            completion(answer ?? unanswered)
        }
    }
}
