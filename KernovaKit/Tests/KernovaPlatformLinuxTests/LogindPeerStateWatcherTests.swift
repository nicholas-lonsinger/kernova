#if os(Linux)
import Dispatch
import KernovaAgentCore
import KernovaDBus
import KernovaPlatformLinux
import Testing

@Suite("A peer's session state, followed in a fake org.freedesktop.login1")
struct LogindPeerStateTests {
    /// A watcher over a fake logind, with every delivery in `inbox`.
    final class Watch {
        let bus: PrivateBus
        let fake: FakeLogind
        let connection: DBusBusConnection
        let queue = DispatchQueue(label: "app.kernova.tests.logind-watch")
        let inbox = Inbox<Result<PeerSessionState?, LogindError>>()
        private let watcher: LogindPeerStateWatcher

        enum Role {
            case session(uid: UInt32)
            case system
        }

        init(_ role: Role, prepare: (FakeLogind.Recorder) -> Void = { _ in }) throws {
            bus = try PrivateBus()
            fake = try FakeLogind(on: bus)
            prepare(fake.recorder)
            connection = try bus.connect()
            let logind = Logind(connection: connection)
            let inbox = inbox
            switch role {
            case .session(let uid):
                watcher = try LogindPeerStateWatcher.sessionPeer(logind, uid: uid, on: queue) { inbox.put($0) }
            case .system:
                watcher = try LogindPeerStateWatcher.systemPeer(logind, on: queue) { inbox.put($0) }
            }
        }

        deinit {
            watcher.cancel()
        }

        /// The next state delivered.
        func next() throws -> PeerSessionState? {
            try inbox.next().get()
        }

        /// The next delivery, which must be a failure.
        func nextFailure() throws -> LogindError? {
            guard case .failure(let error) = try inbox.next() else { return nil }
            return error
        }

        /// Emits `PropertiesChanged` for the session interface on `session`.
        func sessionChanged(_ session: LogindSessionReference, _ changed: [(String, DBusValue)]) throws {
            try fake.emitChange(on: session.path, interface: Logind.sessionInterface, changed: changed, invalidated: [])
        }

        /// Emits the display user's `Display` change to what the fake now holds.
        func displayChanged() throws {
            let display = fake.recorder.display.withLock { $0 }
            try fake.emitChange(
                on: FakeLogind.displayUserPath, interface: Logind.userInterface,
                changed: [("Display", FakeLogind.reference(display))], invalidated: [])
        }

        /// Emits seat0's `ActiveSession` change to what the fake now holds.
        func activeSessionChanged() throws {
            let active = fake.recorder.activeSession.withLock { $0 }
            try fake.emitChange(
                on: FakeLogind.seatPath, interface: Logind.seatInterface,
                changed: [("ActiveSession", FakeLogind.reference(active))], invalidated: [])
        }

        /// Whether nothing more is delivered once every signal sent so far has run its reread.
        func isSettled() throws -> Bool {
            // The fake's signals reach the bus before its reply; the watcher's connection reads them before
            // its own reply, so every handler has queued its reread once both return.
            try sync(fake.connection)
            try sync(connection)
            queue.sync {}
            return inbox.isEmpty
        }
    }

    static let user = "user"

    @Test("The session peer starts from its user's display session, the console OFF while it is in the background")
    func sessionPeerInitial() throws {
        let watch = try Watch(.session(uid: FakeLogind.displayUID))
        #expect(try watch.next() == PeerSessionState(console: .off, sessionID: "2", userName: Self.user))
        #expect(try watch.isSettled())
    }

    @Test("The session peer follows Active and Class: ON while its session is a user's in front, OFF otherwise")
    func sessionPeerActiveFlips() throws {
        let watch = try Watch(.session(uid: FakeLogind.displayUID))
        let session = FakeLogind.userSession
        #expect(try watch.next()?.console == .off)

        // Logged in, or switched back to.
        watch.fake.recorder.userSessionActive.withLock { $0 = true }
        try watch.sessionChanged(session, [("Active", .boolean(true))])
        #expect(try watch.next() == PeerSessionState(console: .on, sessionID: "2", userName: Self.user))

        // A change that leaves the state as it was — the screen locking sets only LockedHint — is no update.
        try watch.sessionChanged(session, [("LockedHint", .boolean(true))])
        try watch.sessionChanged(session, [("Active", .boolean(true))])
        #expect(try watch.isSettled())

        // Switched out: another session took the seat.
        watch.fake.recorder.userSessionActive.withLock { $0 = false }
        try watch.sessionChanged(session, [("Active", .boolean(false))])
        #expect(try watch.next()?.console == .off)

        // In front, but not yet a full user session.
        watch.fake.recorder.userSessionClass.withLock { $0 = "user-incomplete" }
        watch.fake.recorder.userSessionActive.withLock { $0 = true }
        try watch.sessionChanged(session, [("Active", .boolean(true))])
        #expect(try watch.isSettled())
        watch.fake.recorder.userSessionClass.withLock { $0 = "user" }
        try watch.sessionChanged(session, [("Class", .string("user"))])
        #expect(try watch.next()?.console == .on)
    }

    @Test("The session peer follows Display to the user's next session, and a change to the one it left is none")
    func sessionPeerDisplayMoves() throws {
        let watch = try Watch(.session(uid: FakeLogind.displayUID))
        #expect(try watch.next()?.sessionID == "2")

        watch.fake.recorder.display.withLock { $0 = FakeLogind.nextUserSession }
        try watch.displayChanged()
        #expect(try watch.next() == PeerSessionState(console: .on, sessionID: "3", userName: Self.user))

        watch.fake.recorder.userSessionActive.withLock { $0 = true }
        try watch.sessionChanged(FakeLogind.userSession, [("Active", .boolean(true))])
        #expect(try watch.isSettled())
    }

    @Test("A logout re-elects Display before logind signals it: the old session's last change rereads it")
    func sessionPeerLogout() throws {
        let watch = try Watch(.session(uid: FakeLogind.displayUID)) { $0.userSessionActive.withLock { $0 = true } }
        #expect(try watch.next()?.console == .on)

        // The session stops: Display moves on with no signal, then the greeter takes the seat.
        watch.fake.recorder.display.withLock { $0 = nil }
        watch.fake.recorder.userSessionActive.withLock { $0 = false }
        try watch.sessionChanged(FakeLogind.userSession, [("Active", .boolean(false))])
        #expect(try watch.next() == nil)

        // Finalized: logind's Display signal, to what was already read.
        try watch.displayChanged()
        #expect(try watch.isSettled())

        // Logged back in.
        watch.fake.recorder.display.withLock { $0 = FakeLogind.nextUserSession }
        try watch.displayChanged()
        #expect(try watch.next()?.sessionID == "3")
    }

    static let unknownObject = LogindError.call(
        .remote(DBusRemoteError(name: "org.freedesktop.DBus.Error.UnknownObject", message: "Unknown object")))

    @Test("A read that fails delivers its error alone, keeps both subscriptions, and the next signal rereads")
    func failedReadKeepsWatching() throws {
        let watch = try Watch(.session(uid: FakeLogind.displayUID))
        #expect(try watch.next() == PeerSessionState(console: .off, sessionID: "2", userName: Self.user))

        // Display names a session whose properties are already gone.
        watch.fake.recorder.vanishedSessions.withLock { $0 = [FakeLogind.nextUserSession.path] }
        watch.fake.recorder.display.withLock { $0 = FakeLogind.nextUserSession }
        try watch.displayChanged()
        #expect(try watch.nextFailure() == Self.unknownObject)
        #expect(try watch.isSettled())

        // The session subscription it had still rereads...
        watch.fake.recorder.vanishedSessions.withLock { $0 = [] }
        try watch.sessionChanged(FakeLogind.userSession, [("Active", .boolean(false))])
        #expect(try watch.next() == PeerSessionState(console: .on, sessionID: "3", userName: Self.user))

        // ...and so does the user's.
        watch.fake.recorder.display.withLock { $0 = FakeLogind.userSession }
        try watch.displayChanged()
        #expect(try watch.next() == PeerSessionState(console: .off, sessionID: "2", userName: Self.user))
    }

    @Test("After a failed read, a state equal to the last one delivered is not delivered again")
    func failedReadKeepsLastState() throws {
        let watch = try Watch(.session(uid: FakeLogind.displayUID))
        #expect(try watch.next()?.console == .off)

        watch.fake.recorder.vanishedSessions.withLock { $0 = [FakeLogind.userSession.path] }
        try watch.sessionChanged(FakeLogind.userSession, [("Active", .boolean(false))])
        #expect(try watch.nextFailure() == Self.unknownObject)
        watch.fake.recorder.vanishedSessions.withLock { $0 = [] }
        try watch.sessionChanged(FakeLogind.userSession, [("Active", .boolean(false))])
        #expect(try watch.isSettled())

        watch.fake.recorder.userSessionActive.withLock { $0 = true }
        try watch.sessionChanged(FakeLogind.userSession, [("Active", .boolean(true))])
        #expect(try watch.next()?.console == .on)
    }

    @Test("A first read that fails delivers its error, and the next signal delivers the first state")
    func failedFirstRead() throws {
        let watch = try Watch(.session(uid: FakeLogind.displayUID)) { recorder in
            recorder.vanishedSessions.withLock { $0 = [FakeLogind.userSession.path] }
        }
        #expect(try watch.nextFailure() == Self.unknownObject)
        #expect(try watch.isSettled())
        watch.fake.recorder.vanishedSessions.withLock { $0 = [] }
        try watch.displayChanged()
        #expect(try watch.next() == PeerSessionState(console: .off, sessionID: "2", userName: Self.user))
    }

    @Test("A display session on no seat, which logind reports as always active, never holds the console")
    func seatless() throws {
        let watch = try Watch(.session(uid: FakeLogind.displayUID)) { recorder in
            recorder.userSessionActive.withLock { $0 = true }
            recorder.userSessionSeat.withLock { $0 = nil }
        }
        #expect(try watch.next() == PeerSessionState(console: .off, sessionID: "2", userName: Self.user))
    }

    @Test("A user with no display session has no session peer state")
    func sessionless() throws {
        let watch = try Watch(.session(uid: FakeLogind.sessionlessUID))
        #expect(try watch.next() == nil)
    }

    @Test("A user logind does not know cannot be followed")
    func unknownUser() throws {
        #expect(throws: LogindError.self) { _ = try Watch(.session(uid: 1002)) }
    }

    @Test("The system peer follows seat0: OFF at the greeter, ON naming a user's session, OFF again on a switch")
    func systemPeerFollows() throws {
        let watch = try Watch(.system)
        #expect(try watch.next() == PeerSessionState(console: .off))

        watch.fake.recorder.userSessionActive.withLock { $0 = true }
        watch.fake.recorder.activeSession.withLock { $0 = FakeLogind.userSession }
        try watch.activeSessionChanged()
        #expect(try watch.next() == PeerSessionState(console: .on, consoleSessionID: "2"))

        // A user switch: the greeter becomes active, then the next user's session.
        watch.fake.recorder.userSessionActive.withLock { $0 = false }
        watch.fake.recorder.activeSession.withLock { $0 = FakeLogind.greeterSession }
        try watch.activeSessionChanged()
        #expect(try watch.next() == PeerSessionState(console: .off))
        watch.fake.recorder.activeSession.withLock { $0 = FakeLogind.nextUserSession }
        try watch.activeSessionChanged()
        #expect(try watch.next() == PeerSessionState(console: .on, consoleSessionID: "3"))

        // No foreground session, as a headless guest's.
        watch.fake.recorder.activeSession.withLock { $0 = nil }
        try watch.activeSessionChanged()
        #expect(try watch.next() == PeerSessionState(console: .off))
    }

    @Test("The system peer follows the active session's Class, and stops hearing a session that left the seat")
    func systemPeerSessionChanges() throws {
        let watch = try Watch(.system) { recorder in
            recorder.userSessionActive.withLock { $0 = true }
            recorder.userSessionClass.withLock { $0 = "user-incomplete" }
            recorder.activeSession.withLock { $0 = FakeLogind.userSession }
        }
        #expect(try watch.next() == PeerSessionState(console: .off))
        watch.fake.recorder.userSessionClass.withLock { $0 = "user" }
        try watch.sessionChanged(FakeLogind.userSession, [("Class", .string("user"))])
        #expect(try watch.next() == PeerSessionState(console: .on, consoleSessionID: "2"))

        watch.fake.recorder.activeSession.withLock { $0 = FakeLogind.nextUserSession }
        try watch.activeSessionChanged()
        #expect(try watch.next() == PeerSessionState(console: .on, consoleSessionID: "3"))
        watch.fake.recorder.userSessionClass.withLock { $0 = "greeter" }
        try watch.sessionChanged(FakeLogind.userSession, [("Class", .string("greeter"))])
        #expect(try watch.isSettled())
    }

    @Test("A logind that answers NoSuchSeat for seat0 reads the console OFF")
    func noSuchSeat() throws {
        let bus = try PrivateBus()
        let fake = try NoSuchSeatLogind(on: bus)
        defer { withExtendedLifetime(fake) {} }
        let logind = Logind(connection: try bus.connect())
        let inbox = Inbox<Result<PeerSessionState?, LogindError>>()
        let watcher = try LogindPeerStateWatcher.systemPeer(logind, on: DispatchQueue(label: "test")) {
            inbox.put($0)
        }
        defer { watcher.cancel() }
        #expect(try inbox.next().get() == PeerSessionState(console: .off))
    }
}

/// A logind that answers every call `NoSuchSeat`.
private final class NoSuchSeatLogind: Sendable {
    let connection: DBusBusConnection

    init(on bus: PrivateBus) throws {
        connection = try bus.connect { call in
            .error(replyingTo: call, name: "org.freedesktop.login1.NoSuchSeat", message: "No seat 'seat0' known")
        }
        try requestName(Logind.busName, on: connection)
    }
}
#endif
