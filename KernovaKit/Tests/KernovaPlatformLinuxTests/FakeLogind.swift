#if os(Linux)
import KernovaDBus
import KernovaPlatformLinux
import KernovaPortableTestSupport
import Synchronization
import Testing

/// `org.freedesktop.login1` as the agent sees it, exported on a private bus:
/// the manager calls the wrappers make, two users, seat0, and three sessions —
/// a user's graphical session, the same user's next one, and a greeter.
final class FakeLogind: Sendable {
    static let userSession = LogindSessionReference(id: "2", path: "/org/freedesktop/login1/session/_32")
    /// The display user's next graphical session: active, of class `user`, on seat0.
    static let nextUserSession = LogindSessionReference(id: "3", path: "/org/freedesktop/login1/session/_33")
    static let greeterSession = LogindSessionReference(id: "c1", path: "/org/freedesktop/login1/session/c1")
    static let seatPath: DBusObjectPath = "/org/freedesktop/login1/seat/seat0"
    /// Logged in with a graphical session.
    static let displayUID: UInt32 = 1000
    static let displayUserPath: DBusObjectPath = "/org/freedesktop/login1/user/_1000"
    /// Logged in with no graphical session: lingering, or reached over SSH.
    static let sessionlessUID: UInt32 = 1001
    static let sessionlessUserPath: DBusObjectPath = "/org/freedesktop/login1/user/_1001"

    let connection: DBusBusConnection
    let recorder: Recorder

    /// What the fake was asked, and how it is told to answer.
    final class Recorder: Sendable {
        /// seat0's foreground session.
        let activeSession = Mutex<LogindSessionReference?>(FakeLogind.greeterSession)
        /// The display user's `Display`.
        let display = Mutex<LogindSessionReference?>(FakeLogind.userSession)
        /// The user session's `Active`.
        let userSessionActive = Mutex(false)
        /// The user session's `Class`.
        let userSessionClass = Mutex("user")
        /// Sessions whose properties answer `UnknownObject`, as a session logind has just finalized does.
        let vanishedSessions = Mutex<Set<DBusObjectPath>>([])
        /// The user session's `Seat` ID; nil for a session on no seat.
        let userSessionSeat = Mutex<String?>("seat0")
    }

    /// A `(so)` reference to seat `seat`, which the fake keeps at seat0's object; `("", "/")` for none.
    static func seatReference(_ seat: String?) -> DBusValue {
        .struct([.string(seat ?? ""), .objectPath(seat == nil ? .root : seatPath)])
    }

    /// A `(so)` session reference; `("", "/")` for none, as logind holds it.
    static func reference(_ session: LogindSessionReference?) -> DBusValue {
        .struct([.string(session?.id ?? ""), .objectPath(session?.path ?? .root)])
    }

    init(on bus: PrivateBus) throws {
        let recorder = Recorder()
        self.recorder = recorder
        connection = try bus.connect { call in FakeLogind.answer(call, recorder: recorder) }
        try requestName(Logind.busName, on: connection)
    }

    private static func answer(_ call: DBusReceivedMessage, recorder: Recorder) -> DBusMessage? {
        let body = (try? call.decodeBody()) ?? []
        let header = call.header
        let unknown = DBusMessage.error(
            replyingTo: call, name: "org.freedesktop.DBus.Error.UnknownMethod", message: "")
        if header.path == Logind.managerPath, header.interface == Logind.managerInterface, let member = header.member {
            return manager(call, member: member, body: body) ?? unknown
        }
        if let path = header.path, recorder.vanishedSessions.withLock({ $0.contains(path) }) {
            return .error(
                replyingTo: call, name: "org.freedesktop.DBus.Error.UnknownObject",
                message: "Unknown object")
        }
        guard header.interface == "org.freedesktop.DBus.Properties", let path = header.path,
            let properties = properties(of: path, interface: body.first, recorder: recorder)
        else { return unknown }
        switch (header.member, body.count > 1 ? body[1] : nil) {
        case ("Get", .string(let name)?):
            guard let value = properties[name] else { return unknown }
            return .methodReturn(replyingTo: call, body: [.variant(value)])
        case ("GetAll", nil):
            let entries = properties.map { (DBusValue.string($0.key), DBusValue.variant($0.value)) }
            return .methodReturn(replyingTo: call, body: [.dictionary(key: .string, value: .variant, entries)])
        default:
            return unknown
        }
    }

    private static func properties(
        of path: DBusObjectPath, interface: DBusValue?, recorder: Recorder
    ) -> [String: DBusValue]? {
        switch (path, interface) {
        case (displayUserPath, .string(Logind.userInterface)?):
            ["Display": reference(recorder.display.withLock { $0 }), "Name": .string("user")]
        case (sessionlessUserPath, .string(Logind.userInterface)?):
            ["Display": reference(nil), "Name": .string("lingering")]
        case (seatPath, .string(Logind.seatInterface)?):
            ["ActiveSession": reference(recorder.activeSession.withLock { $0 }), "Id": .string("seat0")]
        case (userSession.path, .string(Logind.sessionInterface)?):
            [
                "Id": .string("2"), "Active": .boolean(recorder.userSessionActive.withLock { $0 }),
                "State": .string("online"), "Class": .string(recorder.userSessionClass.withLock { $0 }),
                "Seat": seatReference(recorder.userSessionSeat.withLock { $0 }),
                "Type": .string("wayland"),
            ]
        case (nextUserSession.path, .string(Logind.sessionInterface)?):
            [
                "Id": .string("3"), "Active": .boolean(true), "State": .string("active"),
                "Class": .string("user"), "Seat": seatReference("seat0"),
            ]
        case (greeterSession.path, .string(Logind.sessionInterface)?):
            [
                "Id": .string("c1"), "Active": .boolean(true), "State": .string("active"),
                "Class": .string("greeter"), "Seat": seatReference("seat0"),
            ]
        default:
            nil
        }
    }

    private static func manager(_ call: DBusReceivedMessage, member: String, body: [DBusValue]) -> DBusMessage? {
        switch (member, call.signature.description) {
        case ("GetUser", "u"):
            switch body[0] {
            case .uint32(displayUID): return .methodReturn(replyingTo: call, body: [.objectPath(displayUserPath)])
            case .uint32(sessionlessUID):
                return .methodReturn(replyingTo: call, body: [.objectPath(sessionlessUserPath)])
            default:
                return .error(replyingTo: call, name: "org.freedesktop.login1.NoSuchUser", message: "Not logged in")
            }
        case ("GetSeat", "s"):
            guard body == [.string("seat0")] else {
                return .error(replyingTo: call, name: "org.freedesktop.login1.NoSuchSeat", message: "No seat")
            }
            return .methodReturn(replyingTo: call, body: [.objectPath(seatPath)])
        default:
            return nil
        }
    }

    /// Emits `PropertiesChanged` for `interface` on `path`.
    func emitChange(
        on path: DBusObjectPath, interface: String, changed: [(String, DBusValue)], invalidated: [String]
    ) throws {
        try connection.sendForTesting(
            .signal(
                path: path, interface: "org.freedesktop.DBus.Properties", member: "PropertiesChanged",
                body: [
                    .string(interface),
                    .dictionary(key: .string, value: .variant, changed.map { (.string($0.0), .variant($0.1)) }),
                    .array(elementType: .string, invalidated.map { .string($0) }),
                ]))
    }
}
#endif
