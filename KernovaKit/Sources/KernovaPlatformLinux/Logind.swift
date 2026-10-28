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
    /// authorization. logind refuses with an ERROR while an inhibitor blocks
    /// it.
    public func powerOff() throws(LogindError) {
        _ = try call(Self.managerPath, Self.managerInterface, "PowerOff", [.boolean(false)], expecting: .empty)
    }

    /// `Reboot(false)`, as `powerOff()`.
    public func reboot() throws(LogindError) {
        _ = try call(Self.managerPath, Self.managerInterface, "Reboot", [.boolean(false)], expecting: .empty)
    }

    /// `ListInhibitors()`: every inhibitor lock held now.
    public func inhibitors() throws(LogindError) -> [LogindInhibitor] {
        let body = try call(Self.managerPath, Self.managerInterface, "ListInhibitors", [], expecting: "a(ssssuu)")
        return try Self.read { () throws(DBusValueMismatch) in
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

    /// The inhibitors that block a power-off or reboot `uid` requests.
    public func shutdownBlockers(forCallerUID uid: UInt32) throws(LogindError) -> [LogindInhibitor] {
        try inhibitors().filter { $0.blocksShutdown(forCallerUID: uid) }
    }

    /// `GetUser(uid)`: the user's object. logind answers with an ERROR for a
    /// user with no login.
    ///
    /// The peers run as services — a user service in `user@UID.service`, a
    /// system service — so they belong to no session of their own; their
    /// user's or their seat's is what names the session they serve.
    public func user(_ uid: UInt32) throws(LogindError) -> DBusObjectPath {
        let body = try call(Self.managerPath, Self.managerInterface, "GetUser", [.uint32(uid)], expecting: "o")
        return try Self.read { () throws(DBusValueMismatch) in try body[0].objectPath() }
    }

    /// The user's `Display`: the graphical session logind names the user's
    /// primary display; nil when it names none.
    public func displaySession(ofUser user: DBusObjectPath) throws(LogindError) -> LogindSessionReference? {
        try LogindSessionReference(try property("Display", of: user, Self.userInterface))
    }

    /// `GetSeat(id)`: the seat's object, as `seat0` for the console. logind
    /// answers with an ERROR for a seat that does not exist.
    public func seat(_ id: String) throws(LogindError) -> DBusObjectPath {
        let body = try call(Self.managerPath, Self.managerInterface, "GetSeat", [.string(id)], expecting: "o")
        return try Self.read { () throws(DBusValueMismatch) in try body[0].objectPath() }
    }

    /// The seat's `ActiveSession`: the session in its foreground, a greeter's
    /// or a user's; nil when it has none.
    public func activeSession(onSeat seat: DBusObjectPath) throws(LogindError) -> LogindSessionReference? {
        try LogindSessionReference(try property("ActiveSession", of: seat, Self.seatInterface))
    }

    /// The session's `Id`, `Active`, `State` and `Class`.
    public func sessionProperties(_ session: DBusObjectPath) throws(LogindError) -> LogindSessionProperties {
        let body = try call(
            session, Self.propertiesInterface, "GetAll", [.string(Self.sessionInterface)], expecting: "a{sv}")
        let properties = try Self.read { () throws(DBusValueMismatch) in try body[0].stringKeyedEntries() }
        let change = try LogindSessionChange(changed: properties, invalidated: [])
        guard let id = properties["Id"] else { throw .missingProperty("Id") }
        guard let active = change.active else { throw .missingProperty(LogindSessionProperty.active.name) }
        guard let state = change.state else { throw .missingProperty(LogindSessionProperty.state.name) }
        guard let sessionClass = change.sessionClass else {
            throw .missingProperty(LogindSessionProperty.sessionClass.name)
        }
        return LogindSessionProperties(
            id: try Self.read { () throws(DBusValueMismatch) in try id.variantContent().string() },
            active: active, state: state, sessionClass: sessionClass)
    }

    /// Calls `onChange` for each `PropertiesChanged` logind emits for the
    /// session that touches `Active`, `State` or `Class`, until the
    /// subscription is cancelled.
    ///
    /// Subscribe before reading `sessionProperties(_:)`, so no change falls
    /// between the read and the first notification. `onChange` runs on the
    /// connection's reader thread.
    public func observeSession(
        _ session: DBusObjectPath, onChange: @escaping @Sendable (Result<LogindSessionChange, LogindError>) -> Void
    ) throws(LogindError) -> DBusSubscription {
        try observeProperties(of: session, Self.sessionInterface, onChange: onChange) {
            changed, invalidated throws(LogindError) in
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
        _ seat: DBusObjectPath, onChange: @escaping @Sendable (Result<LogindSeatChange, LogindError>) -> Void
    ) throws(LogindError) -> DBusSubscription {
        try observeProperties(of: seat, Self.seatInterface, onChange: onChange) {
            changed, invalidated throws(LogindError) in
            if let value = changed["ActiveSession"] {
                let content = try Self.read { () throws(DBusValueMismatch) in try value.variantContent() }
                return .activeSession(try LogindSessionReference(content))
            }
            return invalidated.contains("ActiveSession") ? .activeSessionInvalidated : nil
        }
    }

    /// Subscribes to `PropertiesChanged` for `interface` on `path`, handing
    /// `onChange` what `parse` makes of each, when it makes anything.
    private func observeProperties<Change: Sendable>(
        of path: DBusObjectPath, _ interface: String,
        onChange: @escaping @Sendable (Result<Change, LogindError>) -> Void,
        parse: @escaping @Sendable ([String: DBusValue], [String]) throws(LogindError) -> Change?
    ) throws(LogindError) -> DBusSubscription {
        let rule = DBusMatchRule(
            sender: Self.busName, path: path, interface: Self.propertiesInterface, member: "PropertiesChanged",
            arg0: interface)
        do throws(DBusCallError) {
            return try connection.subscribe(rule) { signal in
                let result = Result { () throws(LogindError) -> Change? in
                    let body: [DBusValue]
                    do throws(DBusProtocolError) {
                        body = try signal.decodeBody(expecting: "sa{sv}as")
                    } catch {
                        throw .unexpectedReply(error)
                    }
                    let (changed, invalidated) = try Self.read { () throws(DBusValueMismatch) in
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
    private func property(_ name: String, of path: DBusObjectPath, _ interface: String) throws(LogindError)
        -> DBusValue
    {
        let body = try call(path, Self.propertiesInterface, "Get", [.string(interface), .string(name)], expecting: "v")
        return try Self.read { () throws(DBusValueMismatch) in try body[0].variantContent() }
    }

    private func call(
        _ path: DBusObjectPath, _ interface: String, _ member: String, _ body: [DBusValue],
        expecting signature: DBusSignature
    ) throws(LogindError) -> [DBusValue] {
        let message = DBusMessage.methodCall(
            destination: Self.busName, path: path, interface: interface, member: member, body: body)
        let reply: DBusReceivedMessage
        do throws(DBusCallError) {
            reply = try connection.call(message)
        } catch {
            throw .call(error)
        }
        do throws(DBusProtocolError) {
            return try reply.decodeBody(expecting: signature)
        } catch {
            throw .unexpectedReply(error)
        }
    }

    /// Runs typed reads of a body whose signature was already checked, so a
    /// mismatch is a value of the wrong type inside a variant.
    fileprivate static func read<T>(_ body: () throws(DBusValueMismatch) -> T) throws(LogindError) -> T {
        do throws(DBusValueMismatch) {
            return try body()
        } catch {
            throw .valueMismatch(error)
        }
    }
}

/// Why a logind call failed.
public enum LogindError: Error, Hashable, Sendable {
    /// The call returned no reply, or logind answered with an ERROR.
    case call(DBusCallError)
    /// The reply or signal's body is not the signature logind documents.
    case unexpectedReply(DBusProtocolError)
    /// A property or field holds a value of another type than logind
    /// documents.
    case valueMismatch(DBusValueMismatch)
    /// `GetAll` left out a property logind documents.
    case missingProperty(String)
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

    /// Whether it blocks a power-off or reboot `uid` requests: a `block` lock
    /// on `shutdown` blocks every caller, and a `block-weak` one every
    /// unprivileged caller but the lock's own user (org.freedesktop.login1(5),
    /// systemd 257 and later). A `delay` lock only delays.
    public func blocksShutdown(forCallerUID callerUID: UInt32) -> Bool {
        guard what.contains("shutdown") else { return false }
        switch mode {
        case .block: return true
        case .blockWeak: return callerUID != 0 && callerUID != uid
        default: return false
        }
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

/// The session properties the agent reads.
public enum LogindSessionProperty: Sendable, Hashable, CaseIterable {
    /// `Active`.
    case active
    /// `State`.
    case state
    /// `Class`.
    case sessionClass

    /// The property's D-Bus name.
    public var name: String {
        switch self {
        case .active: "Active"
        case .state: "State"
        case .sessionClass: "Class"
        }
    }
}

/// A session's `Id`, `Active`, `State` and `Class`.
public struct LogindSessionProperties: Sendable, Hashable {
    /// The session's ID.
    public var id: String
    /// Whether the session is in the foreground.
    public var active: Bool
    /// The session's state.
    public var state: LogindSessionState
    /// The session's class.
    public var sessionClass: LogindSessionClass

    /// Properties of these values.
    public init(id: String, active: Bool, state: LogindSessionState, sessionClass: LogindSessionClass) {
        self.id = id
        self.active = active
        self.state = state
        self.sessionClass = sessionClass
    }
}

/// What one `PropertiesChanged` says of `Active`, `State` and `Class`: the
/// new values it carries, and those it invalidated without a value, which a
/// reader rereads with `Logind.sessionProperties(_:)`.
public struct LogindSessionChange: Sendable, Hashable {
    /// The new `Active`, if it carries one.
    public var active: Bool?
    /// The new `State`, if it carries one.
    public var state: LogindSessionState?
    /// The new `Class`, if it carries one.
    public var sessionClass: LogindSessionClass?
    /// The properties changed without a value.
    public var invalidated: Set<LogindSessionProperty>

    var isEmpty: Bool { active == nil && state == nil && sessionClass == nil && invalidated.isEmpty }

    /// The change in properties, each value a variant, and a list of
    /// invalidated names.
    init(changed properties: [String: DBusValue], invalidated names: [String]) throws(LogindError) {
        func content(_ property: LogindSessionProperty) throws(LogindError) -> DBusValue? {
            guard let value = properties[property.name] else { return nil }
            return try Logind.read { () throws(DBusValueMismatch) in try value.variantContent() }
        }
        active = try content(.active).map { value throws(LogindError) in
            try Logind.read { () throws(DBusValueMismatch) in try value.boolean() }
        }
        state = try content(.state).map { value throws(LogindError) in
            LogindSessionState(rawValue: try Logind.read { () throws(DBusValueMismatch) in try value.string() })
        }
        sessionClass = try content(.sessionClass).map { value throws(LogindError) in
            LogindSessionClass(rawValue: try Logind.read { () throws(DBusValueMismatch) in try value.string() })
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
    init?(_ value: DBusValue) throws(LogindError) {
        let (id, path) = try Logind.read { () throws(DBusValueMismatch) in
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

/// What one `PropertiesChanged` on a seat says of its `ActiveSession`.
public enum LogindSeatChange: Sendable, Hashable {
    /// The seat's foreground session is now this one, or none.
    case activeSession(LogindSessionReference?)
    /// The property changed without a value; reread it with
    /// `Logind.activeSession(onSeat:)`.
    case activeSessionInvalidated
}
#endif
