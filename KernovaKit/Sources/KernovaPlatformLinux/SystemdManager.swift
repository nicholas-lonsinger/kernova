#if os(Linux)
import KernovaDBus

/// A systemd manager's `org.freedesktop.systemd1` API: the system manager on the system bus, a user's on
/// that user's bus. Reading a unit's properties needs no privilege.
public struct SystemdManager: Sendable {
    /// `org.freedesktop.systemd1`.
    public static let busName = "org.freedesktop.systemd1"
    /// `/org/freedesktop/systemd1`, the manager object.
    public static let managerPath: DBusObjectPath = "/org/freedesktop/systemd1"
    /// `org.freedesktop.systemd1.Manager`.
    public static let managerInterface = "org.freedesktop.systemd1.Manager"
    /// `org.freedesktop.systemd1.Service`.
    public static let serviceInterface = "org.freedesktop.systemd1.Service"
    /// The error `GetUnit` answers for a unit the manager has not loaded.
    public static let noSuchUnit = "org.freedesktop.systemd1.NoSuchUnit"

    private let connection: DBusBusConnection

    /// The manager as reached over `connection`.
    public init(connection: DBusBusConnection) {
        self.connection = connection
    }

    /// The service `unit`'s `MainPID`: its main process, or 0 while it has none — stopped, or waiting to
    /// restart — and for a unit the manager has not loaded.
    public func mainPID(ofService unit: String) throws(DBusServiceError) -> UInt32 {
        let path: DBusObjectPath
        do throws(DBusServiceError) {
            let body = try connection.callMethod(
                destination: Self.busName, path: Self.managerPath, interface: Self.managerInterface,
                member: "GetUnit", body: [.string(unit)], expecting: "o")
            path = try DBusServiceError.read { () throws(DBusValueMismatch) in try body[0].objectPath() }
        } catch {
            if error.remoteError?.name == Self.noSuchUnit { return 0 }
            throw error
        }
        let body = try connection.callMethod(
            destination: Self.busName, path: path, interface: "org.freedesktop.DBus.Properties", member: "Get",
            body: [.string(Self.serviceInterface), .string("MainPID")], expecting: "v")
        return try DBusServiceError.read { () throws(DBusValueMismatch) in try body[0].variantContent().uint32() }
    }
}
#endif
