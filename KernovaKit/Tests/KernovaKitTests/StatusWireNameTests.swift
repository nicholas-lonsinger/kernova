import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

/// The names a VM's status and a guest agent's cross the wire by — what
/// `kernova list` and `kernova info --format json` print and AppleScript's
/// `agent status` reads, which scripts compare against.
@Suite("Status wire names", .caseScoped)
struct StatusWireNameTests {
    @Test("Every status a VM or a guest agent reports crosses as the name scripts compare against, and reads back")
    func everyStatusCrossesAsItsName() {
        let statuses: [(VMReportedStatus, String)] = [
            (.runtime(.stopped), "stopped"), (.runtime(.starting), "starting"), (.runtime(.running), "running"),
            (.runtime(.paused), "paused"), (.runtime(.suspended), "suspended"), (.runtime(.saving), "saving"),
            (.runtime(.snapshotting), "snapshotting"), (.runtime(.cloning), "cloning"),
            (.runtime(.restoring), "restoring"), (.runtime(.installing), "installing"),
            (.runtime(.forceStopping), "forceStopping"), (.runtime(.initialBoot), "initialBoot"),
            (.runtime(.error), "error"), (.preparing, "preparing"),
        ]
        let agents: [(VMAgentStatus, String)] = [
            (.waiting, "waiting"), (.agent(.current), "current"), (.agent(.connected), "connected"),
            (.agent(.outdated), "outdated"), (.agent(.reinstallNeeded), "reinstallNeeded"),
            (.agent(.updating), "updating"), (.agent(.unresponsive), "unresponsive"),
            (.agent(.expectedMissing), "expectedMissing"), (.agent(.connecting), "connecting"),
            (.agent(.disconnected), "disconnected"),
        ]

        for (status, name) in statuses {
            expectCrossing(status, as: name)
        }
        for (status, name) in agents {
            expectCrossing(status, as: name)
        }
    }

    /// Expects `value` to encode as the bare JSON string `name`, and that
    /// string to decode as `value`.
    private func expectCrossing<Value: Codable & Equatable>(_ value: Value, as name: String) {
        let json = "[\"\(name)\"]"
        let encoded = (try? JSONEncoder().encode([value])).map { String(decoding: $0, as: UTF8.self) }
        #expect(encoded == json)
        let decoded = try? JSONDecoder().decode([Value].self, from: Data(json.utf8))
        #expect(decoded == [value])
    }
}
