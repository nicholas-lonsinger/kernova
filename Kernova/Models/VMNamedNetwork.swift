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

    /// The network mode a VM on this network has.
    var mode: VMNetworkMode { kind.mode }
}
