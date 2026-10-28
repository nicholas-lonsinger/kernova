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

    /// `GetSessionByPID(pid)`: the session `pid` belongs to. logind answers
    /// with an ERROR for a process in no session.
    public func session(ofProcess pid: UInt32) throws(LogindError) -> DBusObjectPath {
        let body = try call(Self.managerPath, Self.managerInterface, "GetSessionByPID", [.uint32(pid)], expecting: "o")
        return try Self.read { () throws(DBusValueMismatch) in try body[0].objectPath() }
    }

    /// The session this process belongs to.
    public func currentSession() throws(LogindError) -> DBusObjectPath {
        try session(ofProcess: UInt32(getpid()))
    }

    /// The session's `Active`, `State` and `Class`.
    public func sessionProperties(_ session: DBusObjectPath) throws(LogindError) -> LogindSessionProperties {
        let body = try call(
            session, Self.propertiesInterface, "GetAll", [.string(Self.sessionInterface)], expecting: "a{sv}")
        let change = try LogindSessionChange(changed: body[0], invalidated: [])
        guard let active = change.active else { throw .missingProperty(LogindSessionProperty.active.name) }
        guard let state = change.state else { throw .missingProperty(LogindSessionProperty.state.name) }
        guard let sessionClass = change.sessionClass else {
            throw .missingProperty(LogindSessionProperty.sessionClass.name)
        }
        return LogindSessionProperties(active: active, state: state, sessionClass: sessionClass)
    }

    /// Calls `onChange` for each `PropertiesChanged` logind emits for the
    /// session's interface that touches `Active`, `State` or `Class`, until the
    /// subscription is cancelled.
    ///
    /// Subscribe before reading `sessionProperties(_:)`, so no change falls
    /// between the read and the first notification. `onChange` runs on the
    /// connection's reader thread.
    public func observeSession(
        _ session: DBusObjectPath, onChange: @escaping @Sendable (Result<LogindSessionChange, LogindError>) -> Void
    ) throws(LogindError) -> DBusSubscription {
        let rule = DBusMatchRule(
            sender: Self.busName, path: session, interface: Self.propertiesInterface, member: "PropertiesChanged",
            arg0: Self.sessionInterface)
        do throws(DBusCallError) {
            return try connection.subscribe(rule) { signal in
                let result = Result { () throws(LogindError) -> LogindSessionChange? in
                    let body: [DBusValue]
                    do throws(DBusProtocolError) {
                        body = try signal.decodeBody(expecting: "sa{sv}as")
                    } catch {
                        throw .unexpectedReply(error)
                    }
                    let invalidated = try Self.read { () throws(DBusValueMismatch) in
                        try body[2].arrayElements().map { name throws(DBusValueMismatch) in try name.string() }
                    }
                    let change = try LogindSessionChange(changed: body[1], invalidated: invalidated)
                    return change.isEmpty ? nil : change
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

/// A session's `Active`, `State` and `Class`.
public struct LogindSessionProperties: Sendable, Hashable {
    /// Whether the session is in the foreground.
    public var active: Bool
    /// The session's state.
    public var state: LogindSessionState
    /// The session's class.
    public var sessionClass: LogindSessionClass
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

    /// The change in a `a{sv}` of properties and a list of invalidated names.
    init(changed: DBusValue, invalidated names: [String]) throws(LogindError) {
        let properties = try Logind.read { () throws(DBusValueMismatch) in try changed.stringKeyedEntries() }
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
#endif
