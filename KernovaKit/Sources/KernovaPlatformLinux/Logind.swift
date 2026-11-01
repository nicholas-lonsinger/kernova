#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import KernovaDBus

/// systemd-logind's `org.freedesktop.login1` API: the calls the guest agent
/// makes.
public struct Logind: Sendable {
    /// `org.freedesktop.login1`.
    public static let busName = "org.freedesktop.login1"
    /// `/org/freedesktop/login1`, the manager object.
    public static let managerPath: DBusObjectPath = "/org/freedesktop/login1"
    /// `org.freedesktop.login1.Manager`.
    public static let managerInterface = "org.freedesktop.login1.Manager"
    /// `org.freedesktop.login1.Session`.
    public static let sessionInterface = "org.freedesktop.login1.Session"
    /// `org.freedesktop.login1.User`.
    public static let userInterface = "org.freedesktop.login1.User"
    /// `org.freedesktop.login1.Seat`.
    public static let seatInterface = "org.freedesktop.login1.Seat"

    private static let propertiesInterface = "org.freedesktop.DBus.Properties"

    private let connection: DBusBusConnection

    /// logind as reached over `connection`, normally the system bus.
    public init(connection: DBusBusConnection) {
        self.connection = connection
    }

    /// `PowerOff(false)`: powers the machine off, with no interactive polkit
    /// authorization, waiting `timeout` for logind's reply.
    ///
    /// logind lets an inhibitor's own user through some shutdown blocks: since
    /// systemd 257 a `block-weak` lock passes its own user and root, and before
    /// 257 a `block` lock passes its own user too (org.freedesktop.login1(5)).
    /// gnome-session holds its lock as the session's user — `block` through
    /// GNOME 50, `block-weak` from 51 (gsm-systemd.c). So a session's own
    /// power-off can pass its apps' unsaved work, and a caller that must not
    /// checks `shutdownBlockers()` first.
    public func powerOff(timeout: Duration = DBusBusConnection.defaultTimeout) throws(DBusServiceError) {
        _ = try call(
            Self.managerPath, Self.managerInterface, "PowerOff", [.boolean(false)], expecting: .empty, timeout: timeout)
    }

    /// `Reboot(false)`, as `powerOff(timeout:)`.
    public func reboot(timeout: Duration = DBusBusConnection.defaultTimeout) throws(DBusServiceError) {
        _ = try call(
            Self.managerPath, Self.managerInterface, "Reboot", [.boolean(false)], expecting: .empty, timeout: timeout)
    }

    /// `ListInhibitors()`: every inhibitor lock held now.
    public func inhibitors() throws(DBusServiceError) -> [LogindInhibitor] {
        let body = try call(Self.managerPath, Self.managerInterface, "ListInhibitors", [], expecting: "a(ssssuu)")
        return try DBusServiceError.read { () throws(DBusValueMismatch) in
            try body[0].arrayElements().map { element throws(DBusValueMismatch) in
                let fields = try element.structFields()
                return LogindInhibitor(
                    what: try fields[0].string().split(separator: ":").map(String.init),
                    who: try fields[1].string(), why: try fields[2].string(),
                    mode: LogindInhibitorMode(rawValue: try fields[3].string()),
                    uid: try fields[4].uint32(), pid: try fields[5].uint32())
            }
        }
    }

    /// The inhibitors that block a power-off or reboot for some caller.
    public func shutdownBlockers() throws(DBusServiceError) -> [LogindInhibitor] {
        try inhibitors().filter(\.blocksShutdown)
    }

    /// `GetUser(uid)`: the user's object. logind answers with an ERROR for a
    /// user with no login.
    ///
    /// The peers run as services — a user service in `user@UID.service`, a
    /// system service — so they belong to no session of their own; their
    /// user's or their seat's is what names the session they serve.
    public func user(_ uid: UInt32) throws(DBusServiceError) -> DBusObjectPath {
        let body = try call(Self.managerPath, Self.managerInterface, "GetUser", [.uint32(uid)], expecting: "o")
        return try DBusServiceError.read { () throws(DBusValueMismatch) in try body[0].objectPath() }
    }

    /// The user's `Display`: the graphical session logind names the user's
    /// primary display; nil when it names none.
    public func displaySession(ofUser user: DBusObjectPath) throws(DBusServiceError) -> LogindSessionReference? {
        try LogindSessionReference(try property("Display", of: user, Self.userInterface))
    }

    /// The user's `Name`: their login name, as logind holds it. A static
    /// binary has no NSS to look a uid up with, so this is how the agent
    /// learns it.
    public func userName(_ user: DBusObjectPath) throws(DBusServiceError) -> String {
        let value = try property("Name", of: user, Self.userInterface)
        return try DBusServiceError.read { () throws(DBusValueMismatch) in try value.string() }
    }

    /// Calls `onChange` for each `PropertiesChanged` logind emits for the
    /// user that touches `Display`, until the subscription is cancelled; as
    /// `observeSession(_:onChange:)`, subscribe before reading
    /// `displaySession(ofUser:)`.
    ///
    /// logind emits it as one of the user's sessions starts and as one is
    /// finalized (systemd's `session_start` and `session_finalize`). A
    /// session that stops re-elects `Display` at once but emits nothing until
    /// it is finalized, which waits on its last process.
    public func observeUser(
        _ user: DBusObjectPath, onChange: @escaping @Sendable (Result<LogindUserChange, DBusServiceError>) -> Void
    ) throws(DBusServiceError) -> DBusSubscription {
        try observeProperties(of: user, Self.userInterface, onChange: onChange) {
            changed, invalidated throws(DBusServiceError) in
            if let value = changed["Display"] {
                let content = try DBusServiceError.read { () throws(DBusValueMismatch) in try value.variantContent() }
                return .display(try LogindSessionReference(content))
            }
            return invalidated.contains("Display") ? .displayInvalidated : nil
        }
    }

    /// `GetSeat(id)`: the seat's object, as `seat0` for the console. logind
    /// answers with an ERROR for a seat that does not exist.
    public func seat(_ id: String) throws(DBusServiceError) -> DBusObjectPath {
        let body = try call(Self.managerPath, Self.managerInterface, "GetSeat", [.string(id)], expecting: "o")
        return try DBusServiceError.read { () throws(DBusValueMismatch) in try body[0].objectPath() }
    }

    /// The seat's `ActiveSession`: the session in its foreground, a greeter's
    /// or a user's; nil when it has none.
    public func activeSession(onSeat seat: DBusObjectPath) throws(DBusServiceError) -> LogindSessionReference? {
        try LogindSessionReference(try property("ActiveSession", of: seat, Self.seatInterface))
    }

    /// `ListSessions()`: every session's object.
    public func sessions() throws(DBusServiceError) -> [DBusObjectPath] {
        let body = try call(Self.managerPath, Self.managerInterface, "ListSessions", [], expecting: "a(susso)")
        return try DBusServiceError.read { () throws(DBusValueMismatch) in
            try body[0].arrayElements().map { element throws(DBusValueMismatch) in
                try element.structFields()[4].objectPath()
            }
        }
    }

    /// The sessions running a desktop: each not `closing`, of a class other than `greeter`, and of type
    /// `x11`, `wayland` or `mir`. A session finalized between the listing and the read is left out.
    public func desktopSessions() throws(DBusServiceError) -> [LogindSessionProperties] {
        var desktops: [LogindSessionProperties] = []
        for path in try sessions() {
            let properties: LogindSessionProperties
            do throws(DBusServiceError) {
                properties = try sessionProperties(path)
            } catch let error where error.remoteError?.name == "org.freedesktop.DBus.Error.UnknownObject" {
                continue
            }
            if properties.runsDesktop { desktops.append(properties) }
        }
        return desktops
    }

    /// Calls `onChange`, on the connection's reader thread, for each `SessionNew` and `SessionRemoved`
    /// logind emits, until both subscriptions are cancelled. Subscribe before reading `desktopSessions()`.
    public func observeSessionList(_ onChange: @escaping @Sendable () -> Void) throws(DBusServiceError)
        -> [DBusSubscription]
    {
        var subscriptions: [DBusSubscription] = []
        for member in ["SessionNew", "SessionRemoved"] {
            let rule = DBusMatchRule(
                sender: Self.busName, path: Self.managerPath, interface: Self.managerInterface, member: member)
            do throws(DBusCallError) {
                subscriptions.append(try connection.subscribe(rule) { _ in onChange() })
            } catch {
                subscriptions.forEach { $0.cancel() }
                throw .call(error)
            }
        }
        return subscriptions
    }

    /// The session's `Id`, `Active`, `State`, `Class`, `Type` and `Seat`.
    public func sessionProperties(_ session: DBusObjectPath) throws(DBusServiceError) -> LogindSessionProperties {
        let body = try call(
            session, Self.propertiesInterface, "GetAll", [.string(Self.sessionInterface)], expecting: "a{sv}")
        let properties = try DBusServiceError.read { () throws(DBusValueMismatch) in try body[0].stringKeyedEntries() }
        let change = try LogindSessionChange(changed: properties, invalidated: [])
        guard let active = change.active else { throw .missingProperty(LogindSessionProperty.active.name) }
        guard let sessionClass = change.sessionClass else {
            throw .missingProperty(LogindSessionProperty.sessionClass.name)
        }
        func string(_ name: String) throws(DBusServiceError) -> String {
            guard let value = properties[name] else { throw .missingProperty(name) }
            return try DBusServiceError.read { () throws(DBusValueMismatch) in try value.variantContent().string() }
        }
        guard let seat = properties["Seat"] else { throw .missingProperty("Seat") }
        // The `(so)` logind holds for a seat has the shape of a session reference, the empty ID for none.
        let seatReference = try LogindSessionReference(
            try DBusServiceError.read { () throws(DBusValueMismatch) in try seat.variantContent() })
        return LogindSessionProperties(
            id: try string("Id"), active: active, state: LogindSessionState(rawValue: try string("State")),
            sessionClass: sessionClass, type: LogindSessionType(rawValue: try string("Type")), seat: seatReference?.id)
    }

    /// Calls `onChange` for each `PropertiesChanged` logind emits for the
    /// session that touches `Active` or `Class`, until the subscription is
    /// cancelled. logind emits none for `State`, so a session's end shows as
    /// its user's `Display` or its seat's `ActiveSession` moving.
    ///
    /// Subscribe before reading `sessionProperties(_:)`, so no change falls
    /// between the read and the first notification. `onChange` runs on the
    /// connection's reader thread.
    public func observeSession(
        _ session: DBusObjectPath, onChange: @escaping @Sendable (Result<LogindSessionChange, DBusServiceError>) -> Void
    ) throws(DBusServiceError) -> DBusSubscription {
        try observeProperties(of: session, Self.sessionInterface, onChange: onChange) {
            changed, invalidated throws(DBusServiceError) in
            let change = try LogindSessionChange(changed: changed, invalidated: invalidated)
            return change.isEmpty ? nil : change
        }
    }

    /// Calls `onChange` for each `PropertiesChanged` logind emits for the seat
    /// that touches `ActiveSession`, until the subscription is cancelled; as
    /// `observeSession(_:onChange:)`, subscribe before reading
    /// `activeSession(onSeat:)`.
    ///
    /// Takes a seat's own object, as `seat(_:)` returns it: logind emits no
    /// signals on `seat/self` or `seat/auto`.
    public func observeSeat(
        _ seat: DBusObjectPath, onChange: @escaping @Sendable (Result<LogindSeatChange, DBusServiceError>) -> Void
    ) throws(DBusServiceError) -> DBusSubscription {
        try observeProperties(of: seat, Self.seatInterface, onChange: onChange) {
            changed, invalidated throws(DBusServiceError) in
            if let value = changed["ActiveSession"] {
                let content = try DBusServiceError.read { () throws(DBusValueMismatch) in try value.variantContent() }
                return .activeSession(try LogindSessionReference(content))
            }
            return invalidated.contains("ActiveSession") ? .activeSessionInvalidated : nil
        }
    }

    /// Subscribes to `PropertiesChanged` for `interface` on `path`, handing
    /// `onChange` what `parse` makes of each, when it makes anything.
    private func observeProperties<Change: Sendable>(
        of path: DBusObjectPath, _ interface: String,
        onChange: @escaping @Sendable (Result<Change, DBusServiceError>) -> Void,
        parse: @escaping @Sendable ([String: DBusValue], [String]) throws(DBusServiceError) -> Change?
    ) throws(DBusServiceError) -> DBusSubscription {
        let rule = DBusMatchRule(
            sender: Self.busName, path: path, interface: Self.propertiesInterface, member: "PropertiesChanged",
            arg0: interface)
        do throws(DBusCallError) {
            return try connection.subscribe(rule) { signal in
                let result = Result { () throws(DBusServiceError) -> Change? in
                    let body: [DBusValue]
                    do throws(DBusProtocolError) {
                        body = try signal.decodeBody(expecting: "sa{sv}as")
                    } catch {
                        throw .unexpectedReply(error)
                    }
                    let (changed, invalidated) = try DBusServiceError.read { () throws(DBusValueMismatch) in
                        (
                            try body[1].stringKeyedEntries(),
                            try body[2].arrayElements().map { name throws(DBusValueMismatch) in try name.string() }
                        )
                    }
                    return try parse(changed, invalidated)
                }
                switch result {
                case .success(let change?): onChange(.success(change))
                case .success(nil): break
                case .failure(let error): onChange(.failure(error))
                }
            }
        } catch {
            throw .call(error)
        }
    }

    /// `Properties.Get(interface, name)` on `path`: the property's value, out
    /// of its variant.
    private func property(_ name: String, of path: DBusObjectPath, _ interface: String) throws(DBusServiceError)
        -> DBusValue
    {
        let body = try call(path, Self.propertiesInterface, "Get", [.string(interface), .string(name)], expecting: "v")
        return try DBusServiceError.read { () throws(DBusValueMismatch) in try body[0].variantContent() }
    }

    private func call(
        _ path: DBusObjectPath, _ interface: String, _ member: String, _ body: [DBusValue],
        expecting signature: DBusSignature, timeout: Duration = DBusBusConnection.defaultTimeout
    ) throws(DBusServiceError) -> [DBusValue] {
        try connection.callMethod(
            destination: Self.busName, path: path, interface: interface, member: member, body: body,
            expecting: signature, timeout: timeout)
    }
}

/// One inhibitor lock, as `ListInhibitors()` lists it.
public struct LogindInhibitor: Sendable, Hashable {
    /// The operations it inhibits: `shutdown`, `sleep`, `idle`, and others.
    public var what: [String]
    /// The application holding it, in its own words.
    public var who: String
    /// Why, in the application's words.
    public var why: String
    /// How it inhibits.
    public var mode: LogindInhibitorMode
    /// The holder's user.
    public var uid: UInt32
    /// The holder's process.
    public var pid: UInt32

    /// An inhibitor with these fields.
    public init(what: [String], who: String, why: String, mode: LogindInhibitorMode, uid: UInt32, pid: UInt32) {
        self.what = what
        self.who = who
        self.why = why
        self.mode = mode
        self.uid = uid
        self.pid = pid
    }

    /// Whether it blocks a power-off or reboot for some caller: a `block` or
    /// `block-weak` lock on `shutdown`. A `delay` lock only delays.
    public var blocksShutdown: Bool {
        what.contains("shutdown") && (mode == .block || mode == .blockWeak)
    }
}

/// An inhibitor's mode.
public struct LogindInhibitorMode: RawRepresentable, Sendable, Hashable {
    /// The mode as logind spells it.
    public var rawValue: String

    /// The mode logind spells `rawValue`.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// `block`.
    public static let block = LogindInhibitorMode(rawValue: "block")
    /// `block-weak`.
    public static let blockWeak = LogindInhibitorMode(rawValue: "block-weak")
    /// `delay`.
    public static let delay = LogindInhibitorMode(rawValue: "delay")
}

/// A session's state: `online`, `active` or `closing`.
public struct LogindSessionState: RawRepresentable, Sendable, Hashable {
    /// The state as logind spells it.
    public var rawValue: String

    /// The state logind spells `rawValue`.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// `online`: logged in, in the background.
    public static let online = LogindSessionState(rawValue: "online")
    /// `active`: logged in and in the foreground.
    public static let active = LogindSessionState(rawValue: "active")
    /// `closing`: logged out, with processes still running.
    public static let closing = LogindSessionState(rawValue: "closing")
}

/// A session's type: `x11`, `wayland`, `mir`, `tty` or `unspecified`.
public struct LogindSessionType: RawRepresentable, Sendable, Hashable {
    /// The type as logind spells it.
    public var rawValue: String

    /// The type logind spells `rawValue`.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// `x11`.
    public static let x11 = LogindSessionType(rawValue: "x11")
    /// `wayland`.
    public static let wayland = LogindSessionType(rawValue: "wayland")
    /// `mir`.
    public static let mir = LogindSessionType(rawValue: "mir")
    /// `tty`: a text console or SSH login.
    public static let tty = LogindSessionType(rawValue: "tty")
}

/// A session's class: `user`, `greeter`, `lock-screen`, among others.
public struct LogindSessionClass: RawRepresentable, Sendable, Hashable {
    /// The class as logind spells it.
    public var rawValue: String

    /// The class logind spells `rawValue`.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// `user`: a normal user session.
    public static let user = LogindSessionClass(rawValue: "user")
    /// `greeter`: a display manager's pseudo-session.
    public static let greeter = LogindSessionClass(rawValue: "greeter")
    /// `lock-screen`: a display lock screen.
    public static let lockScreen = LogindSessionClass(rawValue: "lock-screen")
}

/// The session properties a `LogindSessionChange` carries: those logind
/// emits `PropertiesChanged` for that the agent reads.
public enum LogindSessionProperty: Sendable, Hashable, CaseIterable {
    /// `Active`.
    case active
    /// `Class`.
    case sessionClass

    /// The property's D-Bus name.
    public var name: String {
        switch self {
        case .active: "Active"
        case .sessionClass: "Class"
        }
    }
}

/// A session's `Id`, `Active`, `State`, `Class`, `Type` and `Seat`.
public struct LogindSessionProperties: Sendable, Hashable {
    /// The session's ID.
    public var id: String
    /// Whether the session is in the foreground.
    public var active: Bool
    /// The session's state.
    public var state: LogindSessionState
    /// The session's class.
    public var sessionClass: LogindSessionClass
    /// The session's type.
    public var type: LogindSessionType
    /// The seat the session is attached to, as `seat0`; nil for a session on no seat, as one over SSH is.
    /// logind reports a seatless session as always active.
    public var seat: String?

    /// Properties of these values.
    public init(
        id: String, active: Bool, state: LogindSessionState, sessionClass: LogindSessionClass,
        type: LogindSessionType, seat: String?
    ) {
        self.id = id
        self.active = active
        self.state = state
        self.sessionClass = sessionClass
        self.type = type
        self.seat = seat
    }

    /// Whether the session runs a desktop someone logged in to: graphical, not a greeter's, and not
    /// `closing`, whose desktop has already ended.
    public var runsDesktop: Bool {
        [.x11, .wayland, .mir].contains(type) && sessionClass != .greeter && state != .closing
    }
}

/// What one `PropertiesChanged` says of `Active` and `Class`: the
/// new values it carries, and those it invalidated without a value, which a
/// reader rereads with `Logind.sessionProperties(_:)`.
public struct LogindSessionChange: Sendable, Hashable {
    /// The new `Active`, if it carries one.
    public var active: Bool?
    /// The new `Class`, if it carries one.
    public var sessionClass: LogindSessionClass?
    /// The properties changed without a value.
    public var invalidated: Set<LogindSessionProperty>

    var isEmpty: Bool { active == nil && sessionClass == nil && invalidated.isEmpty }

    /// The change in properties, each value a variant, and a list of
    /// invalidated names.
    init(changed properties: [String: DBusValue], invalidated names: [String]) throws(DBusServiceError) {
        func content(_ property: LogindSessionProperty) throws(DBusServiceError) -> DBusValue? {
            guard let value = properties[property.name] else { return nil }
            return try DBusServiceError.read { () throws(DBusValueMismatch) in try value.variantContent() }
        }
        active = try content(.active).map { value throws(DBusServiceError) in
            try DBusServiceError.read { () throws(DBusValueMismatch) in try value.boolean() }
        }
        sessionClass = try content(.sessionClass).map { value throws(DBusServiceError) in
            LogindSessionClass(
                rawValue: try DBusServiceError.read { () throws(DBusValueMismatch) in try value.string() })
        }
        invalidated = Set(LogindSessionProperty.allCases.filter { names.contains($0.name) })
    }
}
/// A session as logind refers to one from a user or a seat: its ID and object.
public struct LogindSessionReference: Sendable, Hashable {
    /// The session's ID.
    public var id: String
    /// The session's object.
    public var path: DBusObjectPath

    /// A reference to session `id` at `path`.
    public init(id: String, path: DBusObjectPath) {
        self.id = id
        self.path = path
    }

    /// The `(so)` logind holds in `Display` and `ActiveSession`; nil for the
    /// empty ID it holds when there is no such session.
    init?(_ value: DBusValue) throws(DBusServiceError) {
        let (id, path) = try DBusServiceError.read { () throws(DBusValueMismatch) in
            let fields = try value.structFields()
            guard fields.count == 2 else {
                throw DBusValueMismatch(expected: .struct([.string, .objectPath]), actual: value.type)
            }
            return (try fields[0].string(), try fields[1].objectPath())
        }
        guard !id.isEmpty else { return nil }
        self.init(id: id, path: path)
    }
}

/// What one `PropertiesChanged` on a user says of its `Display`.
public enum LogindUserChange: Sendable, Hashable {
    /// The user's display session is now this one, or none.
    case display(LogindSessionReference?)
    /// The property changed without a value; reread it with
    /// `Logind.displaySession(ofUser:)`.
    case displayInvalidated
}

/// What one `PropertiesChanged` on a seat says of its `ActiveSession`.
public enum LogindSeatChange: Sendable, Hashable {
    /// The seat's foreground session is now this one, or none.
    case activeSession(LogindSessionReference?)
    /// The property changed without a value; reread it with
    /// `Logind.activeSession(onSeat:)`.
    case activeSessionInvalidated
}
#endif
