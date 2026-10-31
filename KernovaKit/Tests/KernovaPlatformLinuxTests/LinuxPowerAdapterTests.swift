#if os(Linux)
import Foundation
import KernovaAgentCore
@testable import KernovaAgentRuntime
import KernovaDBus
import KernovaPlatformLinux
import KernovaWire
import Synchronization
import Testing

/// polkit's authority, exported on a private bus: yes for the actions in `authorized`, no for the rest, and
/// told to hold its answers when a test needs a request caught before logind is asked.
final class FakePolkit: Sendable {
    let connection: DBusBusConnection
    let state: State

    final class State: Sendable {
        let authorized = Mutex<Set<String>>(["org.freedesktop.login1.power-off", "org.freedesktop.login1.reboot"])
        /// The bus name of each subject asked about.
        let subjectNames = Mutex<[String]>([])
        let hold = Mutex<(holding: Bool, held: [DBusReceivedMessage])>((false, []))
        /// The action of each call held, as it is held.
        let heldCalls = Inbox<String>()
    }

    init(on bus: PrivateBus) throws {
        let state = State()
        self.state = state
        connection = try bus.connect { call in FakePolkit.answer(call, state: state) }
        try requestName(PolkitAuthority.busName, on: connection)
    }

    /// Answers every call from now until `release()` only then.
    func holdAnswers() {
        state.hold.withLock { $0.holding = true }
    }

    /// Answers the held calls, and every later call at once.
    func release() throws {
        let held = state.hold.withLock { hold in
            defer { hold = (false, []) }
            return hold.held
        }
        for call in held {
            try connection.send(Self.reply(call, state: state))
        }
    }

    /// Emits `Changed`.
    func emitChanged() throws {
        try connection.send(
            .signal(path: PolkitAuthority.path, interface: PolkitAuthority.interface, member: "Changed"))
    }

    private static func answer(_ call: DBusReceivedMessage, state: State) -> DBusMessage? {
        guard call.header.path == PolkitAuthority.path, call.header.interface == PolkitAuthority.interface,
            call.header.member == "CheckAuthorization",
            let body = try? call.decodeBody(expecting: "(sa{sv})sa{ss}us"), case .string(let actionID) = body[1]
        else {
            return .error(replyingTo: call, name: "org.freedesktop.DBus.Error.UnknownMethod", message: "")
        }
        if let fields = try? body[0].structFields(), fields.count == 2,
            let entries = try? fields[1].stringKeyedEntries(),
            let name = try? entries["name"]?.variantContent().string()
        {
            state.subjectNames.withLock { $0.append(name) }
        }
        let held = state.hold.withLock { hold in
            if hold.holding { hold.held.append(call) }
            return hold.holding
        }
        if held {
            state.heldCalls.put(actionID)
            return nil
        }
        return reply(call, state: state)
    }

    private static func reply(_ call: DBusReceivedMessage, state: State) -> DBusMessage {
        var authorized = false
        if case .string(let actionID)? = (try? call.decodeBody())?[1] {
            authorized = state.authorized.withLock { $0.contains(actionID) }
        }
        return .methodReturn(
            replyingTo: call,
            body: [.struct([.boolean(authorized), .boolean(false), .dictionary(key: .string, value: .string, [])])])
    }
}

/// gnome-session on a private bus, with two inhibitors: an editor holding logout, a player holding suspend.
final class FakeGnomeSession: Sendable {
    static let editorPath: DBusObjectPath = "/org/gnome/SessionManager/Inhibitor1"
    static let playerPath: DBusObjectPath = "/org/gnome/SessionManager/Inhibitor2"
    static let editorID = "org.example.Editor"

    let connection: DBusBusConnection

    init(on bus: PrivateBus) throws {
        connection = try bus.connect { call in FakeGnomeSession.answer(call) }
        try requestName(GnomeSessionInhibitors.busName, on: connection)
    }

    private static func answer(_ call: DBusReceivedMessage) -> DBusMessage? {
        let value: DBusValue
        switch (call.header.path, call.header.member) {
        case (GnomeSessionInhibitors.path?, "GetInhibitors"?):
            value = .array(elementType: .objectPath, [.objectPath(editorPath), .objectPath(playerPath)])
        case (editorPath?, "GetFlags"?): value = .uint32(1)
        case (editorPath?, "GetAppId"?): value = .string(editorID)
        case (playerPath?, "GetFlags"?): value = .uint32(4)
        case (playerPath?, "GetAppId"?): value = .string("org.example.Player")
        default:
            return .error(replyingTo: call, name: "org.freedesktop.DBus.Error.UnknownMethod", message: "")
        }
        return .methodReturn(replyingTo: call, body: [value])
    }
}

/// An adapter over fake logind, polkit and gnome-session on one private bus, which serves as both the
/// system and the session bus, with every report in `reports`.
final class PowerHarness {
    static let offer = PowerInput.availability(.available(PowerOffer(actions: [.shutdown, .restart])))
    static let editor = AppValue(displayName: "Example Editor", identifier: FakeGnomeSession.editorID)

    let bus: PrivateBus
    let logind: FakeLogind
    let polkit: FakePolkit?
    let gnomeSession: FakeGnomeSession
    let systemBus: DBusBusConnection
    let adapter: LinuxPowerAdapter
    let reports = Inbox<PowerInput>()

    init(
        _ role: PeerRole, onConsole: Bool = true, withPolkit: Bool = true, powerCallTimeout: Duration = .seconds(8),
        prepare: (FakeLogind.Recorder, FakePolkit.State?) -> Void = { _, _ in }
    ) throws {
        let bus = try PrivateBus()
        let logind = try FakeLogind(on: bus)
        let polkit = try withPolkit ? FakePolkit(on: bus) : nil
        prepare(logind.recorder, polkit?.state)
        let desktopFile = "/applications/\(FakeGnomeSession.editorID).desktop"
        let desktopEntry =
            "[Desktop Entry]\nType=Application\nName[de]=Bearbeiter\nName = Example Editor\nExec=editor\n"
        let systemBus = try bus.connect()
        let address = bus.address
        self.bus = bus
        self.logind = logind
        self.polkit = polkit
        self.systemBus = systemBus
        gnomeSession = try FakeGnomeSession(on: bus)
        adapter = LinuxPowerAdapter(
            role: role, systemBus: systemBus,
            gnomeSession: GnomeSessionInhibitors(
                applicationDirectories: ["/applications"], readFile: { $0 == desktopFile ? desktopEntry : nil }
            ) { () throws(DBusConnectError) in try DBusBusConnection(address: address) },
            powerCallTimeout: powerCallTimeout)
        adapter.setPeerState(PeerSessionState(console: onConsole ? .on : .off, sessionID: "2", userName: "user"))
        let reports = reports
        adapter.start(reporter: PowerReporter { reports.put($0) })
    }

    func next() throws -> PowerInput {
        try reports.next()
    }

    /// The code of the next report, which must be `id`'s refusal.
    func nextRefusal(_ id: PowerRequestID) throws -> ErrorCode? {
        guard case .refused(id, let error) = try next() else { return nil }
        return error.code
    }

    /// The reason of the next report, which must be an absence.
    func nextAbsence() throws -> AbsenceReason? {
        guard case .availability(.absent(let reason, _)) = try next() else { return nil }
        return reason
    }
}

@Suite("The Linux power adapter against fake logind, polkit and gnome-session")
struct LinuxPowerAdapterTests {
    static func request(_ number: UInt64) -> PowerRequestID {
        PowerRequestID(generation: ConnectionGeneration(rawValue: 1), rawValue: number)
    }

    @Test("A blocker the pre-check finds reports accepted, then blocked by the app gnome-session names")
    func preCheckBlocked() throws {
        let harness = try PowerHarness(.sessionPeer)
        #expect(try harness.next() == PowerHarness.offer)
        let id = Self.request(1)
        harness.adapter.perform(id, .shutdown)
        #expect(try harness.next() == .accepted(id))
        #expect(try harness.next() == .blocked(id, [PowerHarness.editor]))
        #expect(harness.logind.callCount("PowerOff") == 0)
        let subjects = try #require(harness.polkit).state.subjectNames.withLock { $0 }
        #expect(!subjects.isEmpty && subjects.allSatisfy { $0 == harness.systemBus.uniqueName })
    }

    @Test("logind's BlockedByInhibitorLock reports accepted, then blocked")
    func blockedByLogind() throws {
        let harness = try PowerHarness(.sessionPeer) { recorder, _ in
            recorder.inhibitors.withLock { $0 = [] }
            recorder.refusal.withLock {
                $0 = DBusRemoteError(
                    name: "org.freedesktop.login1.BlockedByInhibitorLock",
                    message: "Operation denied due to active block inhibitor")
            }
        }
        #expect(try harness.next() == PowerHarness.offer)
        let id = Self.request(1)
        harness.adapter.perform(id, .shutdown)
        #expect(try harness.next() == .accepted(id))
        #expect(try harness.next() == .blocked(id, [PowerHarness.editor]))
        #expect(harness.logind.callCount("PowerOff") == 1)
    }

    @Test("logind's AccessDenied reports refused POWER_NOT_PERMITTED, and another error POWER_OS_FAILED")
    func refused() throws {
        let harness = try PowerHarness(.systemPeer) { recorder, _ in
            recorder.inhibitors.withLock { $0 = [] }
            recorder.refusal.withLock {
                $0 = DBusRemoteError(name: "org.freedesktop.DBus.Error.AccessDenied", message: "Access denied")
            }
        }
        #expect(try harness.next() == PowerHarness.offer)
        let denied = Self.request(1)
        harness.adapter.perform(denied, .shutdown)
        #expect(try harness.nextRefusal(denied) == .powerNotPermitted)

        harness.logind.recorder.refusal.withLock {
            $0 = DBusRemoteError(name: "org.freedesktop.systemd1.UnitMasked", message: "Unit is masked")
        }
        let failed = Self.request(2)
        harness.adapter.perform(failed, .shutdown)
        #expect(try harness.nextRefusal(failed) == .powerOsFailed)
    }

    @Test("logind taking the request reports accepted, then handed off")
    func handedOff() throws {
        let harness = try PowerHarness(.systemPeer) { recorder, _ in recorder.inhibitors.withLock { $0 = [] } }
        #expect(try harness.next() == PowerHarness.offer)
        let id = Self.request(1)
        harness.adapter.perform(id, .restart)
        #expect(try harness.next() == .accepted(id))
        #expect(try harness.next() == .handedOff(id))
        let calls = harness.logind.recorder.calls.withLock { $0 }
        #expect(calls.filter { $0.0 == "Reboot" }.map(\.1) == [[.boolean(false)]])
        #expect(harness.logind.callCount("PowerOff") == 0)
    }

    @Test("A power call logind never answers reports unconfirmed, and the next request reaches logind")
    func unanswered() throws {
        let harness = try PowerHarness(.systemPeer, powerCallTimeout: .milliseconds(200)) { recorder, _ in
            recorder.inhibitors.withLock { $0 = [] }
            recorder.answersPower.withLock { $0 = false }
        }
        #expect(try harness.next() == PowerHarness.offer)
        let lost = Self.request(1)
        harness.adapter.perform(lost, .shutdown)
        #expect(try harness.next() == .unconfirmed(lost))

        harness.logind.recorder.answersPower.withLock { $0 = true }
        let next = Self.request(2)
        harness.adapter.perform(next, .shutdown)
        #expect(try harness.next() == .accepted(next))
        #expect(try harness.next() == .handedOff(next))
        #expect(harness.logind.callCount("PowerOff") == 2)
    }

    @Test("polkit's no makes power absent NOT_PERMITTED and refuses a request; its Changed and a yes offer it")
    func polkitChanges() throws {
        let harness = try PowerHarness(.systemPeer) { _, polkit in polkit?.authorized.withLock { $0 = [] } }
        #expect(try harness.nextAbsence() == .notPermitted)
        let id = Self.request(1)
        harness.adapter.perform(id, .shutdown)
        #expect(try harness.nextRefusal(id) == .powerNotPermitted)

        let polkit = try #require(harness.polkit)
        polkit.state.authorized.withLock { $0 = ["org.freedesktop.login1.reboot"] }
        try polkit.emitChanged()
        #expect(try harness.next() == .availability(.available(PowerOffer(actions: [.restart]))))
        polkit.state.authorized.withLock { $0 = ["org.freedesktop.login1.power-off", "org.freedesktop.login1.reboot"] }
        try polkit.emitChanged()
        #expect(try harness.next() == PowerHarness.offer)
    }

    @Test("A guest with no polkit on the bus has power absent MISSING_OS_COMPONENT")
    func noPolkit() throws {
        let harness = try PowerHarness(.systemPeer, withPolkit: false)
        #expect(try harness.nextAbsence() == .missingOsComponent)
    }

    @Test("A session peer offers power only while its session holds the console")
    func notOnConsole() throws {
        let harness = try PowerHarness(.sessionPeer, onConsole: false)
        #expect(try harness.nextAbsence() == .notOnConsole)
        harness.adapter.setPeerState(PeerSessionState(console: .on, sessionID: "2", userName: "user"))
        #expect(try harness.next() == PowerHarness.offer)
        harness.adapter.setPeerState(nil)
        #expect(try harness.nextAbsence() == .notOnConsole)
    }

    @Test("A cancel before logind is asked reports cancelled at once, and logind is never asked")
    func cancelled() throws {
        let harness = try PowerHarness(.systemPeer) { recorder, _ in recorder.inhibitors.withLock { $0 = [] } }
        #expect(try harness.next() == PowerHarness.offer)
        let polkit = try #require(harness.polkit)
        polkit.holdAnswers()
        let id = Self.request(1)
        harness.adapter.perform(id, .shutdown)
        _ = try polkit.state.heldCalls.next()
        harness.adapter.cancel(id)
        #expect(try harness.next() == .cancelled(id))
        try polkit.release()

        // The adapter's queue runs one request at a time, so this one starts once the cancelled one is done.
        let next = Self.request(2)
        harness.adapter.perform(next, .shutdown)
        #expect(try harness.next() == .accepted(next))
        #expect(try harness.next() == .handedOff(next))
        #expect(harness.logind.callCount("PowerOff") == 1)
    }

    @Test("The system peer names logind's holders, by who and pid, even where gnome-session runs")
    func systemPeerNamesLogindHolders() throws {
        let harness = try PowerHarness(.systemPeer)
        #expect(try harness.next() == PowerHarness.offer)
        let id = Self.request(1)
        harness.adapter.perform(id, .shutdown)
        #expect(try harness.next() == .accepted(id))
        guard case .blocked(id, let apps) = try harness.next() else {
            Issue.record("The request was not blocked")
            return
        }
        #expect(apps.map(\.displayName) == ["GNOME Session", "Editor"])
        #expect(apps.map(\.processID) == [101, 104])
    }
}

@Suite("gnome-session's app names")
struct GnomeSessionInhibitorsTests {
    @Test("A desktop entry's name is its first unlocalized Name in [Desktop Entry]")
    func desktopEntryName() {
        let text = """
            # A comment
            [Desktop Entry]
            Name[fr]=Éditeur
            Name = Text Editor\t
            Name=Second
            [Desktop Action new-window]
            Name=New Window
            """
        #expect(GnomeSessionInhibitors.desktopEntryName(parsing: text) == "Text Editor")
        #expect(GnomeSessionInhibitors.desktopEntryName(parsing: "[Desktop Action x]\nName=Action\n") == nil)
    }

    @Test("The application directories follow XDG's variables and defaults, then Flatpak's exports")
    func applicationDirectories() {
        #expect(
            GnomeSessionInhibitors.applicationDirectories(environment: ["HOME": "/home/user"]) == [
                "/home/user/.local/share/applications", "/usr/local/share/applications", "/usr/share/applications",
                "/var/lib/flatpak/exports/share/applications",
            ])
        #expect(
            GnomeSessionInhibitors.applicationDirectories(environment: [
                "HOME": "/home/user", "XDG_DATA_HOME": "/data", "XDG_DATA_DIRS": "/a:relative:/b",
            ]) == [
                "/data/applications", "/a/applications", "/b/applications",
                "/var/lib/flatpak/exports/share/applications",
            ])
    }
}
#endif
