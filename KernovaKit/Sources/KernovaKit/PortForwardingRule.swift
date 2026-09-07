import Foundation

/// The transport a forwarding rule covers.
public enum PortForwardingTransport: String, Codable, Sendable, Hashable, CaseIterable {
    case tcp
    case udp

    /// How the transport reads in the UI.
    public var displayName: String { rawValue.uppercased() }
}

/// One host→guest port mapping on an app-managed network.
///
/// The app's single forwarding model (docs/NETWORKING.md): every consumer of
/// port mappings uses this rule and the enforcement path behind it — the
/// persisted configuration, the vmnet declaration, and the wire edit alike.
public struct PortForwardingRule: Codable, Sendable, Equatable, Hashable {
    /// The transport forwarded.
    public var transport: PortForwardingTransport
    /// The port traffic arrives on, on the host side (vmnet's *external* port).
    public var hostPort: UInt16
    /// The port traffic is delivered to inside the guest (vmnet's *internal*
    /// port).
    public var guestPort: UInt16

    /// The ports a rule may carry — port 0 addresses no service.
    public static let portRange: ClosedRange<Int> = 1...65535

    /// Maps one host port onto one guest port.
    public init(transport: PortForwardingTransport, hostPort: UInt16, guestPort: UInt16) {
        self.transport = transport
        self.hostPort = hostPort
        self.guestPort = guestPort
    }

    /// What makes this rule collide with another.
    public var hostClaim: PortForwardingHostClaim {
        PortForwardingHostClaim(transport: transport, hostPort: hostPort)
    }
}

/// A claim on one host-side port.
///
/// A network carries one rule per (transport, host port): the host port is
/// claimed network-wide, across every VM joined to it.
public struct PortForwardingHostClaim: Codable, Hashable, Sendable {
    /// The transport claimed.
    public var transport: PortForwardingTransport
    /// The host-side port claimed.
    public var hostPort: UInt16

    /// Names one claim.
    public init(transport: PortForwardingTransport, hostPort: UInt16) {
        self.transport = transport
        self.hostPort = hostPort
    }
}
