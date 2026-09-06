import Foundation

/// What one ``VMCommandRequest`` answered with.
public struct VMCommandResponse: Codable, Sendable, Hashable {
    /// The vocabulary this response is written in.
    public var protocolVersion: Int
    /// What the verb answered with.
    public var result: Result

    /// Wraps one answer for the wire.
    public init(
        result: Result, protocolVersion: Int = VMCommandRequest.currentProtocolVersion
    ) {
        self.protocolVersion = protocolVersion
        self.result = result
    }

    /// What a verb can answer with — one payload shape per return type in the
    /// facade, plus the refusal every verb shares.
    public enum Result: Codable, Sendable, Hashable {
        /// The verb succeeded and answers with nothing.
        case ok
        /// A listing.
        case summaries([VMSummary])
        /// One VM a verb created or named.
        case summary(VMSummary)
        /// One VM's full description.
        case info(VMInfo)
        /// What a VM's address resolves to on the network its mode joins.
        case ipAddress(GuestIPAddress)
        /// A VM's restore points.
        case snapshots([SnapshotSummary])
        /// One restore point a capture produced.
        case snapshot(SnapshotSummary)
        /// One library change, for a transport streaming them.
        case event(VMLibraryEvent)
        /// The verb was refused, or ran and did not complete.
        case failure(CommandErrorDTO)
        /// The request was refused by the envelope, before any verb ran.
        case refused(VMCommandTransportRefusal)
    }

    /// The refusal this response carries, or `nil` when the verb succeeded.
    public var failure: CommandErrorDTO? {
        guard case .failure(let error) = result else { return nil }
        return error
    }
}
