#if os(Linux)
import KernovaDBus

/// polkit's `org.freedesktop.PolicyKit1.Authority`: whether the guest's
/// policy authorizes this connection for an action.
public struct PolkitAuthority: Sendable {
    /// `org.freedesktop.PolicyKit1`.
    public static let busName = "org.freedesktop.PolicyKit1"
    /// `/org/freedesktop/PolicyKit1/Authority`.
    public static let path: DBusObjectPath = "/org/freedesktop/PolicyKit1/Authority"
    /// `org.freedesktop.PolicyKit1.Authority`.
    public static let interface = "org.freedesktop.PolicyKit1.Authority"

    private let connection: DBusBusConnection

    /// polkit as reached over `connection`, the system bus.
    public init(connection: DBusBusConnection) {
        self.connection = connection
    }

    /// `CheckAuthorization` for `actionID`, with no user interaction: true
    /// only for polkit's yes — a challenge is false.
    ///
    /// The subject is this connection's own bus name, which is the subject a
    /// service such as logind asks polkit about when this connection calls it.
    public func isAuthorized(_ actionID: String) throws(DBusServiceError) -> Bool {
        let subject = DBusValue.struct([
            .string("system-bus-name"),
            .dictionary(key: .string, value: .variant, [(.string("name"), .variant(.string(connection.uniqueName)))]),
        ])
        let body = try connection.callMethod(
            destination: Self.busName, path: Self.path, interface: Self.interface, member: "CheckAuthorization",
            body: [
                subject, .string(actionID), .dictionary(key: .string, value: .string, []), .uint32(0), .string(""),
            ],
            expecting: "(bba{ss})")
        return try DBusServiceError.read { () throws(DBusValueMismatch) in
            try body[0].structFields()[0].boolean()
        }
    }

    /// Calls `onChange`, on the connection's reader thread, each time polkit
    /// signals `Changed` — its rules or its authorizations may have changed —
    /// until the subscription is cancelled.
    public func observeChanges(_ onChange: @escaping @Sendable () -> Void) throws(DBusServiceError)
        -> DBusSubscription
    {
        let rule = DBusMatchRule(sender: Self.busName, path: Self.path, interface: Self.interface, member: "Changed")
        do throws(DBusCallError) {
            return try connection.subscribe(rule) { _ in onChange() }
        } catch {
            throw .call(error)
        }
    }

    /// Whether `error` says polkit is not on the bus: no service owns its name,
    /// and none can be started.
    public static func isAbsent(_ error: DBusServiceError) -> Bool {
        guard let remote = error.remoteError else { return false }
        return remote.name == "org.freedesktop.DBus.Error.ServiceUnknown"
            || remote.name == "org.freedesktop.DBus.Error.NameHasNoOwner"
    }
}
#endif
