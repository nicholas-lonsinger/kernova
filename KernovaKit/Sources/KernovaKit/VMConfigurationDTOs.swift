import Foundation

/// One dotted configuration key, as the keyspace describes itself.
///
/// The listing a client renders for `get --keys`, so nothing outside the app
/// has to carry its own copy of what the keyspace holds.
public struct ConfigurationKeyDescriptor: Codable, Sendable, Hashable {
    /// The dotted name a `get` or `set` addresses the value by.
    public let name: String
    /// One line naming the unit or the accepted values.
    public let summary: String
    /// Whether a running VM takes a write of this key.
    public let editableWhileRunning: Bool

    /// Describes one key.
    public init(name: String, summary: String, editableWhileRunning: Bool) {
        self.name = name
        self.summary = summary
        self.editableWhileRunning = editableWhileRunning
    }
}

/// One configuration key and the value it holds, in the spelling a `set`
/// accepts back.
///
/// The same type in both directions: reading and writing are inverse, so a
/// second shape for the write side would be one more thing to keep in step.
public struct ConfigurationEntry: Codable, Sendable, Hashable {
    /// The dotted key name.
    public let key: String
    /// The value, rendered the way `set` parses it.
    public let value: String

    /// Names one key and the value it holds.
    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// One change to a VM's host→guest port mappings.
///
/// Removal names the host-side claim rather than the whole rule: a network
/// carries one rule per (transport, host port), so that pair identifies it.
public enum PortForwardingEdit: Codable, Sendable, Hashable {
    case add(rule: PortForwardingRule)
    case remove(claim: PortForwardingHostClaim)
}
