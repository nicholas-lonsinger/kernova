#if os(Linux)
import Dispatch
import KernovaAgentCore
import KernovaDBus
import KernovaPlatformLinux
import Testing

@Suite("A peer's session state, read from a fake org.freedesktop.login1")
struct LogindPeerStateTests {
    @Test("The session peer names its user's display session and login name, the console ON only while it is active")
    func sessionPeer() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        let logind = Logind(connection: try bus.connect())
        let uid = FakeLogind.displayUID
        #expect(
            try LogindPeerState.sessionPeer(logind, uid: uid)
                == PeerSessionState(console: .off, sessionID: "2", userName: "user"))
        fake.recorder.userSessionActive.withLock { $0 = true }
        #expect(
            try LogindPeerState.sessionPeer(logind, uid: uid)
                == PeerSessionState(console: .on, sessionID: "2", userName: "user"))
    }

    @Test("A display session on no seat, which logind reports as always active, never holds the console")
    func seatless() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        let logind = Logind(connection: try bus.connect())
        fake.recorder.userSessionActive.withLock { $0 = true }
        fake.recorder.userSessionSeat.withLock { $0 = nil }
        #expect(
            try LogindPeerState.sessionPeer(logind, uid: FakeLogind.displayUID)
                == PeerSessionState(console: .off, sessionID: "2", userName: "user"))
    }

    @Test("A user with no display session has no session peer state")
    func sessionless() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        defer { withExtendedLifetime(fake) {} }
        let logind = Logind(connection: try bus.connect())
        #expect(try LogindPeerState.sessionPeer(logind, uid: FakeLogind.sessionlessUID) == nil)
    }

    @Test("The session peer's wait delivers at once when the user has a display session")
    func awaitImmediate() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        defer { withExtendedLifetime(fake) {} }
        let logind = Logind(connection: try bus.connect())
        let inbox = Inbox<Result<PeerSessionState, LogindError>>()
        LogindPeerState.awaitSessionPeer(
            logind, uid: FakeLogind.displayUID, on: DispatchQueue(label: "test")
        ) { inbox.put($0) }
        #expect(try inbox.next().get().sessionID == "2")
    }

    @Test("The session peer waits through a session that is not its display until one is, then delivers once")
    func awaitDisplay() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        let logind = Logind(connection: try bus.connect())
        let queue = DispatchQueue(label: "test")
        fake.recorder.display.withLock { $0 = nil }
        let inbox = Inbox<Result<PeerSessionState, LogindError>>()
        LogindPeerState.awaitSessionPeer(logind, uid: FakeLogind.displayUID, on: queue) { inbox.put($0) }
        // The subscription and the first read, which finds no display session, run in one turn of `queue`.
        queue.sync {}
        #expect(inbox.isEmpty)
        try fake.emitSessionNew(FakeLogind.greeterSession)
        fake.recorder.display.withLock { $0 = FakeLogind.userSession }
        try fake.emitSessionNew(FakeLogind.userSession)
        #expect(try inbox.next().get() == PeerSessionState(console: .off, sessionID: "2", userName: "user"))
        try fake.emitSessionNew(FakeLogind.userSession)
        try sync(fake.connection)
        queue.sync {}
        #expect(inbox.isEmpty)
    }

    @Test("The system peer reports the console OFF at the greeter and with no foreground session, as headless")
    func systemPeerOff() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        let logind = Logind(connection: try bus.connect())
        #expect(try LogindPeerState.systemPeer(logind) == PeerSessionState(console: .off))
        fake.recorder.activeSession.withLock { $0 = nil }
        #expect(try LogindPeerState.systemPeer(logind) == PeerSessionState(console: .off))
    }

    @Test("The system peer reports the console ON, naming the session, while a user's session is in front")
    func systemPeerOn() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        let logind = Logind(connection: try bus.connect())
        fake.recorder.activeSession.withLock { $0 = FakeLogind.userSession }
        fake.recorder.userSessionActive.withLock { $0 = true }
        #expect(try LogindPeerState.systemPeer(logind) == PeerSessionState(console: .on, consoleSessionID: "2"))
    }

    @Test("A logind that answers NoSuchSeat for seat0 reads the console OFF")
    func noSuchSeat() throws {
        let bus = try PrivateBus()
        let fake = try NoSuchSeatLogind(on: bus)
        defer { withExtendedLifetime(fake) {} }
        let logind = Logind(connection: try bus.connect())
        #expect(try LogindPeerState.systemPeer(logind) == PeerSessionState(console: .off))
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
