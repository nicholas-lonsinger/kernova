#if os(Linux)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaDBus
import KernovaSynchronization

/// gnome-session's inhibitors on the session bus: the apps holding the session's logout, by name.
///
/// logind lists only gnome-session as the holder of the session's shutdown lock; gnome-session's own list
/// names each app (docs/research/2026-10-28-linux-logind-polkit-user-service-and-inhibitors.md, finding 3).
public final class GnomeSessionInhibitors: Sendable {
    /// `org.gnome.SessionManager`.
    public static let busName = "org.gnome.SessionManager"
    /// `/org/gnome/SessionManager`.
    public static let path: DBusObjectPath = "/org/gnome/SessionManager"
    /// `org.gnome.SessionManager`.
    public static let interface = "org.gnome.SessionManager"
    /// `org.gnome.SessionManager.Inhibitor`.
    public static let inhibitorInterface = "org.gnome.SessionManager.Inhibitor"
    /// GsmInhibitorFlag's logout bit.
    static let logoutFlag: UInt32 = 1
    /// How long each call waits: the list is read while the host waits on the outcome.
    static let callTimeout: Duration = .seconds(3)

    private let applicationDirectories: [String]
    private let connect: @Sendable () throws(DBusConnectError) -> DBusBusConnection
    /// The session-bus connection, made on first use and dropped after a failed call.
    private let connection = Locked<DBusBusConnection?>(nil)

    /// gnome-session as reached by `connect`, naming apps from the `.desktop` files in
    /// `applicationDirectories`, searched in order.
    public init(
        applicationDirectories: [String] = GnomeSessionInhibitors.applicationDirectories(
            environment: ProcessInfo.processInfo.environment),
        connect: @escaping @Sendable () throws(DBusConnectError) -> DBusBusConnection = {
            () throws(DBusConnectError) in try DBusBusConnection(bus: .session)
        }
    ) {
        self.applicationDirectories = applicationDirectories
        self.connect = connect
    }

    /// The `applications` directories the XDG Base Directory specification searches for `.desktop` files:
    /// `$XDG_DATA_HOME` (`$HOME/.local/share`), each of `$XDG_DATA_DIRS` (`/usr/local/share:/usr/share`),
    /// then Flatpak's system exports. A relative entry is ignored, as the specification says.
    public static func applicationDirectories(environment: [String: String]) -> [String] {
        var roots: [String] = []
        if let data = environment["XDG_DATA_HOME"], data.hasPrefix("/") {
            roots.append(data)
        } else if let home = environment["HOME"], home.hasPrefix("/") {
            roots.append(home + "/.local/share")
        }
        let dirs = environment["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/share:/usr/share"
        roots += dirs.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        roots.append("/var/lib/flatpak/exports/share")
        return roots.map { $0 + "/applications" }
    }

    /// The apps whose inhibitors hold the session's logout, each named by its `.desktop` file's `Name`, or
    /// by its app id when it has none.
    public func logoutInhibitors() throws(GnomeSessionError) -> [AppValue] {
        let connection = try connected()
        do throws(DBusServiceError) {
            let body = try call(connection, Self.path, Self.interface, "GetInhibitors", expecting: "ao")
            let inhibitors = try DBusServiceError.read { () throws(DBusValueMismatch) in
                try body[0].arrayElements().map { element throws(DBusValueMismatch) in try element.objectPath() }
            }
            var apps: [AppValue] = []
            for inhibitor in inhibitors {
                let reply = try call(connection, inhibitor, Self.inhibitorInterface, "GetFlags", expecting: "u")
                let flags = try DBusServiceError.read { () throws(DBusValueMismatch) in try reply[0].uint32() }
                guard flags & Self.logoutFlag != 0 else { continue }
                let appID = try call(connection, inhibitor, Self.inhibitorInterface, "GetAppId", expecting: "s")
                let identifier = try DBusServiceError.read { () throws(DBusValueMismatch) in try appID[0].string() }
                apps.append(AppValue(displayName: displayName(ofApp: identifier) ?? identifier, identifier: identifier))
            }
            return apps
        } catch {
            self.connection.withLock { if $0 === connection { $0 = nil } }
            connection.close()
            throw .call(error)
        }
    }

    /// The `Name` of the first `<appID>.desktop` found in `applicationDirectories`.
    func displayName(ofApp appID: String) -> String? {
        guard !appID.isEmpty, !appID.contains("/") else { return nil }
        let file = appID.hasSuffix(".desktop") ? appID : appID + ".desktop"
        for directory in applicationDirectories {
            guard let text = LinuxIdentity.readText(directory + "/" + file) else { continue }
            return Self.desktopEntryName(parsing: text)
        }
        return nil
    }

    /// The first unlocalized `Name` in a desktop entry's `[Desktop Entry]` group; nil when it has none.
    public static func desktopEntryName(parsing text: String) -> String? {
        var inEntry = false
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = Self.trimmed(line)
            if trimmed.hasPrefix("[") {
                inEntry = trimmed == "[Desktop Entry]"
                continue
            }
            guard inEntry, let equals = trimmed.firstIndex(of: "="), Self.trimmed(trimmed[..<equals]) == "Name"
            else { continue }
            let name = Self.trimmed(trimmed[trimmed.index(after: equals)...])
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }

    private static func trimmed(_ text: Substring) -> Substring {
        var text = text.drop { $0 == " " || $0 == "\t" }
        while let last = text.last, last == " " || last == "\t" || last == "\r" { text.removeLast() }
        return text
    }

    private func connected() throws(GnomeSessionError) -> DBusBusConnection {
        if let existing = connection.withLock({ $0 }) { return existing }
        do throws(DBusConnectError) {
            let made = try connect()
            connection.withLock { $0 = made }
            return made
        } catch {
            throw .connect(error)
        }
    }

    private func call(
        _ connection: DBusBusConnection, _ path: DBusObjectPath, _ interface: String, _ member: String,
        expecting signature: DBusSignature
    ) throws(DBusServiceError) -> [DBusValue] {
        try connection.callMethod(
            destination: Self.busName, path: path, interface: interface, member: member, expecting: signature,
            timeout: Self.callTimeout)
    }
}

/// Why gnome-session's inhibitors could not be read.
public enum GnomeSessionError: Error, Hashable, Sendable {
    /// The session bus could not be reached.
    case connect(DBusConnectError)
    /// A call to gnome-session failed, as one does where gnome-session is not running.
    case call(DBusServiceError)
}
#endif
