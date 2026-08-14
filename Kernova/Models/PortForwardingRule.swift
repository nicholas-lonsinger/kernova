import Foundation

/// The transport a forwarding rule covers.
enum PortForwardingTransport: String, Codable, Sendable, CaseIterable {
    case tcp
    case udp

    /// How the transport reads in the UI.
    var displayName: String { rawValue.uppercased() }
}

/// One host→guest port mapping on an app-managed network.
///
/// The app's single forwarding model (docs/NETWORKING.md): every consumer of
/// port mappings uses this rule and the enforcement path behind it.
struct PortForwardingRule: Codable, Sendable, Equatable, Hashable {
    /// The transport forwarded.
    var transport: PortForwardingTransport
    /// The port traffic arrives on, on the host side (vmnet's *external* port).
    var hostPort: UInt16
    /// The port traffic is delivered to inside the guest (vmnet's *internal*
    /// port).
    var guestPort: UInt16

    /// The ports a rule may carry — port 0 addresses no service.
    static let portRange: ClosedRange<Int> = 1...65535

    /// What makes this rule collide with another.
    var hostClaim: PortForwardingHostClaim {
        PortForwardingHostClaim(transport: transport, hostPort: hostPort)
    }
}

/// A claim on one host-side port.
///
/// A network carries one rule per (transport, host port): the host port is
/// claimed network-wide, across every VM joined to it.
struct PortForwardingHostClaim: Hashable, Sendable {
    var transport: PortForwardingTransport
    var hostPort: UInt16
}
