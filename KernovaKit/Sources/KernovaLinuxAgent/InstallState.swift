#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The slot metadata in `state.json`: which slot is in use, what each holds, the update switch not yet
/// confirmed, and the payload the install refuses.
///
/// While the agent runs, only it writes the file; the rollback check reads it and writes nothing but its own
/// markers (``SlotRoot``).
struct InstallState: Codable, Equatable {
    /// What one slot holds.
    struct Slot: Codable, Equatable {
        /// The payload's SHA-256, lowercase hex.
        var payloadSHA256: String
        /// The display version the payload reports.
        var versionLabel: String
    }

    /// An update's switch of `current` from one slot to another, unconfirmed while its marker exists.
    struct Switch: Codable, Equatable {
        /// The slot the switch left, which a rollback returns to.
        var from: String
        /// The slot the switch made current.
        var to: String
        /// The payload `to` holds, lowercase hex: what a rollback records as rejected.
        var payloadSHA256: String
    }

    /// The slot `current` points at.
    var active: String
    /// Each filled slot, by name.
    var slots: [String: Slot]
    /// The switch an update made and nothing has confirmed or reverted yet.
    var pendingSwitch: Switch?
    /// The payload this install will not update itself to, lowercase hex.
    var rejectedSHA256: String?

    private enum CodingKeys: String, CodingKey {
        case active, slots
        case pendingSwitch = "switch"
        case rejectedSHA256 = "rejectedPayloadSHA256"
    }

    /// The state after a fresh install of the payload hashing to `payloadSHA256` into slot `a`.
    static func fresh(payloadSHA256: String, versionLabel: String) -> InstallState {
        InstallState(active: "a", slots: ["a": Slot(payloadSHA256: payloadSHA256, versionLabel: versionLabel)])
    }

    /// The JSON written, keys sorted.
    func encoded() throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return Array(try encoder.encode(self)) + [0x0A]
    }

    /// The state `bytes` hold.
    static func decoded(_ bytes: [UInt8]) throws -> InstallState {
        try JSONDecoder().decode(InstallState.self, from: Data(bytes))
    }

    /// The slot that is not `slot`.
    static func spare(of slot: String) -> String {
        slot == "a" ? "b" : "a"
    }
}
