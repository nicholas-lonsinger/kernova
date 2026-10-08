import KernovaKit
import Foundation

/// A network the user named: the VMs naming it in their membership
/// (``VMNetworkMembership/network(_:)``) reach each other on it, and no other
/// guest (docs/NETWORKING.md).
///
/// Lives at library level, in ``VMNetworkDirectory``; a VM names it by ``id``,
/// so a rename touches no VM.
struct VMNamedNetwork: Codable, Sendable, Hashable, Identifiable {
    let id: UUID
    var name: String
    /// The mode every VM on it runs in. Fixed at creation: a VM joins the
    /// network only in this mode, so changing it would move every member.
    let kind: VmnetNetworkKind

    /// The kinds the New Network sheet offers, in its order: the first is the
    /// kind a new network gets unless another is chosen.
    static let kindsInCreationOrder: [VmnetNetworkKind] = [.nat, .hostOnly]

    /// The kind a new network gets unless another is chosen.
    static var defaultKind: VmnetNetworkKind { kindsInCreationOrder[0] }

    /// The network mode a VM on this network has.
    var mode: VMNetworkMode { kind.mode }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind
    }
}

extension VMNamedNetwork {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            kind: try c.decode(
                VmnetNetworkKind.self, forKey: .kind, repairingTo: Self.defaultKind, in: decoder))
    }
}
