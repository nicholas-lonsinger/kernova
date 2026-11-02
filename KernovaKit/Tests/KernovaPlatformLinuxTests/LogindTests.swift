#if os(Linux)
import KernovaDBus
import KernovaPlatformLinux
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
            return manager(call, member: member, body: body, recorder: recorder) ?? unknown
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

    private static func manager(
        _ call: DBusReceivedMessage, member: String, body: [DBusValue], recorder: Recorder
    ) -> DBusMessage? {
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
        try connection.send(
            .signal(
                path: path, interface: "org.freedesktop.DBus.Properties", member: "PropertiesChanged",
                body: [
                    .string(interface),
                    .dictionary(key: .string, value: .variant, changed.map { (.string($0.0), .variant($0.1)) }),
                    .array(elementType: .string, invalidated.map { .string($0) }),
                ]))
    }
}

@Suite("Logind against a fake org.freedesktop.login1")
struct LogindTests {
    @Test("A user's display session is found from its uid, with the session's Id, Active, State and Class")
    func displaySession() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        defer { withExtendedLifetime(fake) {} }
        let logind = Logind(connection: try bus.connect())
        let user = try logind.user(FakeLogind.displayUID)
        #expect(user == FakeLogind.displayUserPath)
        let session = try #require(try logind.displaySession(ofUser: user))
        #expect(session == FakeLogind.userSession)
        #expect(
            try logind.sessionProperties(session.path)
                == LogindSessionProperties(id: "2", active: false, state: .online, sessionClass: .user, seat: "seat0"))
    }

    @Test("A user in no graphical session has no display session, and a user not logged in is an error")
    func noSession() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        defer { withExtendedLifetime(fake) {} }
        let logind = Logind(connection: try bus.connect())
        #expect(try logind.displaySession(ofUser: logind.user(FakeLogind.sessionlessUID)) == nil)
        do {
            _ = try logind.user(1002)
            Issue.record("The call returned")
        } catch LogindError.call(.remote(let error)) {
            #expect(error.name == "org.freedesktop.login1.NoSuchUser")
        }
    }

    @Test("seat0's active session names who holds the console: a greeter, a user, or nobody")
    func console() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        let logind = Logind(connection: try bus.connect())
        let seat = try logind.seat("seat0")
        #expect(seat == FakeLogind.seatPath)

        let greeter = try #require(try logind.activeSession(onSeat: seat))
        #expect(greeter == FakeLogind.greeterSession)
        #expect(
            try logind.sessionProperties(greeter.path)
                == LogindSessionProperties(
                    id: "c1", active: true, state: .active, sessionClass: .greeter, seat: "seat0"))

        fake.recorder.activeSession.withLock { $0 = FakeLogind.userSession }
        #expect(try logind.activeSession(onSeat: seat) == FakeLogind.userSession)
        fake.recorder.activeSession.withLock { $0 = nil }
        #expect(try logind.activeSession(onSeat: seat) == nil)

        #expect(throws: LogindError.self) { try logind.seat("seat1") }
    }

    @Test("Observing seat0 delivers each change of its active session")
    func observeSeat() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        let logind = Logind(connection: try bus.connect())
        let seat = try logind.seat("seat0")
        let inbox = Inbox<Result<LogindSeatChange, LogindError>>()
        let subscription = try logind.observeSeat(seat) { inbox.put($0) }

        let interface = Logind.seatInterface
        try fake.emitChange(on: seat, interface: interface, changed: [("CanTTY", .boolean(true))], invalidated: [])
        let toUser = [("ActiveSession", FakeLogind.reference(FakeLogind.userSession))]
        try fake.emitChange(on: seat, interface: interface, changed: toUser, invalidated: [])
        #expect(try inbox.next().get() == .activeSession(FakeLogind.userSession))
        let toNobody = [("ActiveSession", FakeLogind.reference(nil))]
        try fake.emitChange(on: seat, interface: interface, changed: toNobody, invalidated: [])
        #expect(try inbox.next().get() == .activeSession(nil))
        try fake.emitChange(on: seat, interface: interface, changed: [], invalidated: ["ActiveSession"])
        #expect(try inbox.next().get() == .activeSessionInvalidated)
        #expect(inbox.isEmpty)
        subscription.cancel()
    }

    @Test("Observing a user delivers each change of its display session")
    func observeUser() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        let logind = Logind(connection: try bus.connect())
        let user = try logind.user(FakeLogind.displayUID)
        let inbox = Inbox<Result<LogindUserChange, LogindError>>()
        let subscription = try logind.observeUser(user) { inbox.put($0) }

        let interface = Logind.userInterface
        try fake.emitChange(on: user, interface: interface, changed: [("IdleHint", .boolean(true))], invalidated: [])
        try fake.emitChange(
            on: user, interface: Logind.sessionInterface,
            changed: [("Display", FakeLogind.reference(FakeLogind.nextUserSession))], invalidated: [])
        let toNext = [("Display", FakeLogind.reference(FakeLogind.nextUserSession))]
        try fake.emitChange(on: user, interface: interface, changed: toNext, invalidated: [])
        #expect(try inbox.next().get() == .display(FakeLogind.nextUserSession))
        try fake.emitChange(
            on: user, interface: interface, changed: [("Display", FakeLogind.reference(nil))], invalidated: [])
        #expect(try inbox.next().get() == .display(nil))
        try fake.emitChange(on: user, interface: interface, changed: [], invalidated: ["Display"])
        #expect(try inbox.next().get() == .displayInvalidated)
        #expect(inbox.isEmpty)
        subscription.cancel()
    }

    @Test("Observing a session delivers changes to Active and Class, and nothing for State or another interface")
    func observeSession() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        let logind = Logind(connection: try bus.connect())
        let path = FakeLogind.userSession.path
        let inbox = Inbox<Result<LogindSessionChange, LogindError>>()
        let subscription = try logind.observeSession(path) { inbox.put($0) }

        let interface = Logind.sessionInterface
        try fake.emitChange(
            on: path, interface: Logind.userInterface, changed: [("Active", .boolean(true))], invalidated: [])
        try fake.emitChange(on: path, interface: interface, changed: [("IdleHint", .boolean(true))], invalidated: [])
        // State is not observed: logind emits no PropertiesChanged for it.
        try fake.emitChange(on: path, interface: interface, changed: [("State", .string("closing"))], invalidated: [])
        try fake.emitChange(
            on: path, interface: interface, changed: [("Active", .boolean(true)), ("State", .string("active"))],
            invalidated: ["Class", "IdleHint", "State"])
        let change = try inbox.next().get()
        #expect(change.active == true)
        #expect(change.sessionClass == nil)
        #expect(change.invalidated == [.sessionClass])

        try fake.emitChange(on: path, interface: interface, changed: [("Class", .string("user"))], invalidated: [])
        #expect(try inbox.next().get().sessionClass == .user)

        try fake.emitChange(on: path, interface: interface, changed: [("Active", .string("yes"))], invalidated: [])
        #expect(throws: LogindError.valueMismatch(DBusValueMismatch(expected: .boolean, actual: .string))) {
            try inbox.next().get()
        }
        #expect(inbox.isEmpty)
        subscription.cancel()
    }
}
#endif
