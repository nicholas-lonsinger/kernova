#if os(Linux)
import KernovaDBus
import KernovaPlatformLinux
import Testing

/// `org.freedesktop.systemd1` as the rollback check reads it, exported on a private bus: one loaded service.
final class FakeSystemd: Sendable {
    static let unit = "kernova-agent.service"
    static let unitPath: DBusObjectPath = "/org/freedesktop/systemd1/unit/kernova_2dagent_2eservice"

    let connection: DBusBusConnection

    init(on bus: PrivateBus, mainPID: UInt32) throws {
        connection = try bus.connect { call in FakeSystemd.answer(call, mainPID: mainPID) }
        try requestName(SystemdManager.busName, on: connection)
    }

    private static func answer(_ call: DBusReceivedMessage, mainPID: UInt32) -> DBusMessage? {
        let body = (try? call.decodeBody()) ?? []
        let header = call.header
        if header.path == SystemdManager.managerPath, header.interface == SystemdManager.managerInterface,
            header.member == "GetUnit"
        {
            guard body == [.string(unit)] else {
                return .error(replyingTo: call, name: SystemdManager.noSuchUnit, message: "Unit not loaded.")
            }
            return .methodReturn(replyingTo: call, body: [.objectPath(unitPath)])
        }
        if header.path == unitPath, header.interface == "org.freedesktop.DBus.Properties", header.member == "Get",
            body == [.string(SystemdManager.serviceInterface), .string("MainPID")]
        {
            return .methodReturn(replyingTo: call, body: [.variant(.uint32(mainPID))])
        }
        return .error(replyingTo: call, name: "org.freedesktop.DBus.Error.UnknownMethod", message: "")
    }
}

@Suite("systemd's manager API")
struct SystemdManagerTests {
    @Test("A loaded service's MainPID is read through its unit object")
    func mainPID() throws {
        let bus = try PrivateBus()
        let systemd = try FakeSystemd(on: bus, mainPID: 4242)
        let manager = SystemdManager(connection: try bus.connect())
        #expect(try manager.mainPID(ofService: FakeSystemd.unit) == 4242)
        _ = systemd
    }

    @Test("A unit the manager has not loaded has no main process")
    func unloaded() throws {
        let bus = try PrivateBus()
        let systemd = try FakeSystemd(on: bus, mainPID: 4242)
        let manager = SystemdManager(connection: try bus.connect())
        #expect(try manager.mainPID(ofService: "other.service") == 0)
        _ = systemd
    }
}
#endif
