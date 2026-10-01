import Foundation
import KernovaKit

/// One snapshot as the tool prints it: the wire's own row plus the size a
/// separate read answers with.
///
/// The size is not part of ``SnapshotSummary`` — reading it walks the bundle,
/// which the cheap listing must not do — so the two arrive from two verbs and
/// are joined here. Encoding writes the summary's own fields into the same
/// object and adds the size's keys, so the tool's JSON stays the wire's schema rather
/// than a second declaration of it.
struct SnapshotRow: Encodable, Sendable, Hashable {
    /// The restore point itself, exactly as the app described it.
    let snapshot: SnapshotSummary
    /// The snapshot's size, `nil` when the size read did not answer for it.
    let size: SnapshotSize?

    /// Pairs one restore point with its size.
    init(_ snapshot: SnapshotSummary, size: SnapshotSize?) {
        self.snapshot = snapshot
        self.size = size
    }

    private enum CodingKeys: String, CodingKey {
        case sizeBytes
        case privateBytes
    }

    /// Writes the summary's fields and the size as one flat object; a figure
    /// nobody answered for is left out rather than written as zero.
    func encode(to encoder: any Encoder) throws {
        try snapshot.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(size?.bytes, forKey: .sizeBytes)
        try container.encodeIfPresent(size?.privateBytes, forKey: .privateBytes)
    }
}
