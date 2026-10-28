/// A match rule: the text `AddMatch` registers with the bus, and the same test
/// applied to each received message, since the bus delivers every connection's
/// matches, and messages addressed to it, on one stream.
public struct DBusMatchRule: Sendable, Hashable {
    /// The message type; nil matches any.
    public var kind: DBusMessageKind?
    /// The sender, a unique or well-known bus name; nil matches any.
    public var sender: String?
    /// The object path; nil matches any.
    public var path: DBusObjectPath?
    /// The interface; nil matches any.
    public var interface: String?
    /// The member; nil matches any.
    public var member: String?
    /// The first argument, which must then be a string; nil matches any.
    public var arg0: String?

    /// A rule matching what each non-nil key names.
    public init(
        kind: DBusMessageKind? = .signal, sender: String? = nil, path: DBusObjectPath? = nil,
        interface: String? = nil, member: String? = nil, arg0: String? = nil
    ) {
        self.kind = kind
        self.sender = sender
        self.path = path
        self.interface = interface
        self.member = member
        self.arg0 = arg0
    }

    /// The rule as `AddMatch` takes it.
    public var text: String {
        var pairs: [String] = []
        if let kind {
            let name =
                switch kind {
                case .methodCall: "method_call"
                case .methodReturn: "method_return"
                case .error: "error"
                case .signal: "signal"
                }
            pairs.append("type=" + Self.quoted(name))
        }
        if let sender { pairs.append("sender=" + Self.quoted(sender)) }
        if let interface { pairs.append("interface=" + Self.quoted(interface)) }
        if let member { pairs.append("member=" + Self.quoted(member)) }
        if let path { pairs.append("path=" + Self.quoted(path.rawValue)) }
        if let arg0 { pairs.append("arg0=" + Self.quoted(arg0)) }
        return pairs.joined(separator: ",")
    }

    /// Whether `message` matches, where `senderOwner` is the unique name that
    /// owns `sender` — `sender` itself when that is a unique name or the bus's
    /// own name, nil when the name has no owner.
    public func matches(_ message: DBusReceivedMessage, senderOwner: String?) -> Bool {
        let header = message.header
        if let kind, header.kind != kind { return false }
        if sender != nil, header.sender == nil || header.sender != senderOwner { return false }
        if let path, header.path != path { return false }
        if let interface, header.interface != interface { return false }
        if let member, header.member != member { return false }
        if let arg0 {
            guard message.signature.types.first == .string,
                case .string(let first)? = try? message.decodeBody().first, first == arg0
            else { return false }
        }
        return true
    }

    /// `value` in single quotes, each apostrophe closing the quote, written
    /// as `\'`, and reopening it.
    private static func quoted(_ value: String) -> String {
        "'" + value.split(separator: "'", omittingEmptySubsequences: false).joined(separator: "'\\''") + "'"
    }
}
