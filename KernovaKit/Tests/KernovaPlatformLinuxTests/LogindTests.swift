#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import KernovaDBus
import KernovaPlatformLinux
import Synchronization
import Testing

/// `org.freedesktop.login1` as the agent sees it, exported on a private bus:
/// the manager's calls the wrappers make, and one session.
final class FakeLogind: Sendable {
    static let sessionPath: DBusObjectPath = "/org/freedesktop/login1/session/_32"

    let connection: DBusBusConnection
    let recorder: Recorder

    /// What the fake was asked, and how it is told to answer.
    final class Recorder: Sendable {
        /// Each manager call received, as its member and arguments.
        let calls = Mutex<[(String, [DBusValue])]>([])
        /// The error PowerOff and Reboot answer with, when set.
        let refusal = Mutex<DBusRemoteError?>(nil)
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

    init(on bus: PrivateBus) throws {
        let recorder = Recorder()
        self.recorder = recorder
        connection = try bus.connect { call in FakeLogind.answer(call, recorder: recorder) }
        try requestName(Logind.busName, on: connection)
    }

    private static func answer(_ call: DBusReceivedMessage, recorder: Recorder) -> DBusMessage? {
        let body = (try? call.decodeBody()) ?? []
        let header = call.header
        if header.path == Logind.managerPath, header.interface == Logind.managerInterface, let member = header.member {
            recorder.calls.withLock { $0.append((member, body)) }
            switch (member, call.signature.description) {
            case ("PowerOff", "b"), ("Reboot", "b"):
                if let error = recorder.refusal.withLock({ $0 }) {
                    return .error(replyingTo: call, name: error.name, message: error.message)
                }
                return .methodReturn(replyingTo: call)
            case ("ListInhibitors", ""):
                return .methodReturn(
                    replyingTo: call,
                    body: [
                        .array(
                            elementType: .struct([.string, .string, .string, .string, .uint32, .uint32]), inhibitors)
                    ])
            case ("GetSessionByPID", "u"):
                guard body == [.uint32(UInt32(getpid()))] else {
                    return .error(
                        replyingTo: call, name: "org.freedesktop.login1.NoSessionForPID", message: "No session")
                }
                return .methodReturn(replyingTo: call, body: [.objectPath(sessionPath)])
            default:
                break
            }
        }
        if header.path == sessionPath, header.interface == "org.freedesktop.DBus.Properties",
            header.member == "GetAll", body == [.string(Logind.sessionInterface)]
        {
            return .methodReturn(
                replyingTo: call,
                body: [
                    .dictionary(
                        key: .string, value: .variant,
                        [
                            (.string("Id"), .variant(.string("32"))),
                            (.string("Active"), .variant(.boolean(true))),
                            (.string("State"), .variant(.string("active"))),
                            (.string("Class"), .variant(.string("user"))),
                        ])
                ])
        }
        return .error(replyingTo: call, name: "org.freedesktop.DBus.Error.UnknownMethod", message: "")
    }

    /// Emits `PropertiesChanged` for `interface` on the session.
    func emitChange(interface: String, changed: [(String, DBusValue)], invalidated: [String]) throws {
        try connection.send(
            .signal(
                path: Self.sessionPath, interface: "org.freedesktop.DBus.Properties", member: "PropertiesChanged",
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
            message: "Operation inhibited by \"GNOME Session\", reason is \"user session inhibited\".")
        fake.recorder.refusal.withLock { $0 = error }
        #expect(throws: LogindError.call(.remote(error))) { try logind.powerOff() }
    }

    @Test("ListInhibitors maps every field, and the blocking ones are those on shutdown that block this caller")
    func inhibitors() throws {
        let bus = try PrivateBus()
        _ = try FakeLogind(on: bus)
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

    @Test("GetSessionByPID finds this process's session and its Active, State and Class")
    func session() throws {
        let bus = try PrivateBus()
        _ = try FakeLogind(on: bus)
        let logind = Logind(connection: try bus.connect())
        let session = try logind.currentSession()
        #expect(session == FakeLogind.sessionPath)
        #expect(
            try logind.sessionProperties(session)
                == LogindSessionProperties(active: true, state: .active, sessionClass: .user))

        do {
            _ = try logind.session(ofProcess: 1)
            Issue.record("The call returned")
        } catch LogindError.call(.remote(let error)) {
            #expect(error.name == "org.freedesktop.login1.NoSessionForPID")
        }
    }

    @Test("Observing a session delivers its PropertiesChanged, and nothing for another interface")
    func observe() throws {
        let bus = try PrivateBus()
        let fake = try FakeLogind(on: bus)
        let logind = Logind(connection: try bus.connect())
        let inbox = Inbox<Result<LogindSessionChange, LogindError>>()
        let subscription = try logind.observeSession(FakeLogind.sessionPath) { inbox.put($0) }

        try fake.emitChange(
            interface: "org.freedesktop.login1.User", changed: [("State", .string("x"))], invalidated: [])
        try fake.emitChange(
            interface: Logind.sessionInterface, changed: [("IdleHint", .boolean(true))], invalidated: [])
        try fake.emitChange(
            interface: Logind.sessionInterface, changed: [("Active", .boolean(false)), ("State", .string("online"))],
            invalidated: ["Class", "IdleHint"])
        let change = try inbox.next().get()
        #expect(change.active == false)
        #expect(change.state == .online)
        #expect(change.sessionClass == nil)
        #expect(change.invalidated == [.sessionClass])

        try fake.emitChange(interface: Logind.sessionInterface, changed: [("Active", .string("yes"))], invalidated: [])
        #expect(throws: LogindError.valueMismatch(DBusValueMismatch(expected: .boolean, actual: .string))) {
            try inbox.next().get()
        }
        #expect(inbox.isEmpty)
        subscription.cancel()
    }
}
#endif
