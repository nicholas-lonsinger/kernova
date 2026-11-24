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
    /// What its value is.
    public let kind: ConfigurationValueKind
    /// Whether a running VM takes a write of this key, for each guest the key
    /// applies to, keyed by the guest's wire name (``VMInfo/guestOS``).
    public let editableWhileRunning: [String: Bool]

    /// Describes one key.
    public init(
        name: String, summary: String, kind: ConfigurationValueKind, editableWhileRunning: [String: Bool]
    ) {
        self.name = name
        self.summary = summary
        self.kind = kind
        self.editableWhileRunning = editableWhileRunning
    }
}

/// What a configuration key's value is — the kind its text spells.
public enum ConfigurationValueKind: String, Codable, Sendable, Hashable, CaseIterable {
    /// `true` or `false`.
    case boolean
    /// A whole number.
    case integer
    /// A number of gigabytes, with decimals where it isn't whole.
    case gigabytes
    /// A network mode — `nat`, `bridged` or `hostOnly` — or `none`.
    case networkMode
    /// One of a fixed set of words.
    case choice
    /// Text.
    case text
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
