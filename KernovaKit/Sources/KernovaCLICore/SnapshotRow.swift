import Foundation
import KernovaKit

/// One snapshot as the tool prints it: the wire's own row plus the size a
/// separate read answers with.
///
/// The size is not part of ``SnapshotSummary`` — reading it walks the bundle,
/// which the cheap listing must not do — so the two arrive from two verbs and
/// are joined here. Encoding writes the summary's own fields into the same
/// object and adds one key, so the tool's JSON stays the wire's schema rather
/// than a second declaration of it.
public struct SnapshotRow: Encodable, Sendable, Hashable {
    /// The restore point itself, exactly as the app described it.
    public let snapshot: SnapshotSummary
    /// Bytes the snapshot's files occupy, `nil` when the size read did not
    /// answer for it.
    public let onDiskBytes: UInt64?

    /// Pairs one restore point with its size.
    public init(_ snapshot: SnapshotSummary, onDiskBytes: UInt64?) {
        self.snapshot = snapshot
        self.onDiskBytes = onDiskBytes
    }

    private enum CodingKeys: String, CodingKey {
        case onDiskBytes
    }

    /// Writes the summary's fields and the size as one flat object.
    public func encode(to encoder: any Encoder) throws {
        try snapshot.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(onDiskBytes, forKey: .onDiskBytes)
    }
}
