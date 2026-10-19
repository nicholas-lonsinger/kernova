import Foundation
import KernovaKit

/// One VM as `info` prints it: the wire's description plus the storage disks a
/// separate read answers with.
///
/// The disks are not part of ``VMInfo`` — measuring them reads every image,
/// which the in-memory description must not do — so the two arrive from two
/// verbs and are joined here. Encoding writes the description's own fields
/// into the same object and adds `storageDisks`, so the tool's JSON stays the
/// wire's schema rather than a second declaration of it.
struct VMInfoReport: Encodable, Sendable, Hashable {
    /// The VM itself, exactly as the app described it.
    let info: VMInfo
    /// The VM's storage disks, in the order its guest sees them.
    let storageDisks: [StorageDiskSummary]

    /// Pairs one VM with its disks.
    init(_ info: VMInfo, storageDisks: [StorageDiskSummary]) {
        self.info = info
        self.storageDisks = storageDisks
    }

    private enum CodingKeys: String, CodingKey {
        case storageDisks
    }

    /// Writes the description's fields and the disks as one flat object.
    func encode(to encoder: any Encoder) throws {
        try info.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storageDisks, forKey: .storageDisks)
    }
}
