#if os(Linux)
import KernovaDBus
import KernovaPlatformLinux
import Synchronization
import Testing

/// `org.freedesktop.login1` as the agent sees it, exported on a private bus:
/// the manager calls the wrappers make, two users, seat0, and two sessions —
/// a user's graphical session and a greeter.
final class FakeLogind: Sendable {
    static let userSession = LogindSessionReference(id: "2", path: "/org/freedesktop/login1/session/_32")
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
        /// Each manager call received, as its member and arguments.
        let calls = Mutex<[(String, [DBusValue])]>([])
        /// The error PowerOff and Reboot answer with, when set.
        let refusal = Mutex<DBusRemoteError?>(nil)
        /// seat0's foreground session.
        let activeSession = Mutex<LogindSessionReference?>(FakeLogind.greeterSession)
        /// The display user's `Display`.
        let display = Mutex<LogindSessionReference?>(FakeLogind.userSession)
        /// The user session's `Active`.
        let userSessionActive = Mutex(false)
    }

    static let inhibitors: [DBusValue] = [
        inhibitor("shutdown", "GNOME Session", "user session inhibited", "block", 1000, 101),
        inhibitor("sleep", "Media", "playing", "block", 1000, 102),
        inhibitor("shutdown:sleep", "Updater", "installing", "delay", 0, 103),
        inhibitor("idle:shutdown", "Editor", "unsaved", "block-weak", 1000, 104),
    ]

    static func inhibitor(
        _ what: String, _ who: String, _ why: String, _ mode: String, _ uid: UInt32, _ pid: UInt32
    ) -> DBusValue {
        .struct([.string(what), .string(who), .string(why), .string(mode), .uint32(uid), .uint32(pid)])
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
            recorder.calls.withLock { $0.append((member, body)) }
            return manager(call, member: member, body: body, recorder: recorder) ?? unknown
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
                "State": .string("online"), "Class": .string("user"),
                "Type": .string("wayland"),
            ]
        case (greeterSession.path, .string(Logind.sessionInterface)?):
            ["Id": .string("c1"), "Active": .boolean(true), "State": .string("active"), "Class": .string("greeter")]
        default:
            nil
        }
    }

    private static func manager(
        _ call: DBusReceivedMessage, member: String, body: [DBusValue], recorder: Recorder
    ) -> DBusMessage? {
        switch (member, call.signature.description) {
        case ("PowerOff", "b"), ("Reboot", "b"):
            if let error = recorder.refusal.withLock({ $0 }) {
                return .error(replyingTo: call, name: error.name, message: error.message)
            }
            return .methodReturn(replyingTo: call)
        case ("ListInhibitors", ""):
            let element = DBusType.struct([.string, .string, .string, .string, .uint32, .uint32])
            return .methodReturn(replyingTo: call, body: [.array(elementType: element, inhibitors)])
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

    /// Emits the manager's `SessionNew` for `session`.
    func emitSessionNew(_ session: LogindSessionReference) throws {
        try connection.send(
            .signal(
                path: Logind.managerPath, interface: Logind.managerInterface, member: "SessionNew",
                body: [.string(session.id), .objectPath(session.path)]))
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
    @Test("PowerOff and Reboot send interactive false")
    func power() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        let logind = Logind(connection: try bus.connect())
        try logind.powerOff()
        try logind.reboot()
        let calls = fake.recorder.calls.withLock { $0 }
        #expect(calls.map(\.0) == ["PowerOff", "Reboot"])
        #expect(calls.map(\.1) == [[.boolean(false)], [.boolean(false)]])
    }

    @Test("A refused PowerOff throws logind's error")
    func powerRefused() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        let logind = Logind(connection: try bus.connect())
        let error = DBusRemoteError(
            name: "org.freedesktop.login1.BlockedByInhibitorLock",
            message: "Operation denied due to active block inhibitor")
        fake.recorder.refusal.withLock { $0 = error }
        #expect(throws: LogindError.call(.remote(error))) { try logind.powerOff() }
    }

    @Test("ListInhibitors maps every field, and the blocking ones are those on shutdown that block this caller")
    func inhibitors() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        defer { withExtendedLifetime(fake) {} }
        let logind = Logind(connection: try bus.connect())
        let all = try logind.inhibitors()
        #expect(all.count == 4)
        #expect(
            all[0]
                == LogindInhibitor(
                    what: ["shutdown"], who: "GNOME Session", why: "user session inhibited", mode: .block, uid: 1000,
                    pid: 101))
        #expect(all[2].what == ["shutdown", "sleep"])
        #expect(all[3].mode == .blockWeak)

        #expect(try logind.shutdownBlockers(forCallerUID: 1000).map(\.who) == ["GNOME Session"])
        #expect(try logind.shutdownBlockers(forCallerUID: 1001).map(\.who) == ["GNOME Session", "Editor"])
        #expect(try logind.shutdownBlockers(forCallerUID: 0).map(\.who) == ["GNOME Session"])
    }

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
                == LogindSessionProperties(id: "2", active: false, state: .online, sessionClass: .user))
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
                == LogindSessionProperties(id: "c1", active: true, state: .active, sessionClass: .greeter))

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
