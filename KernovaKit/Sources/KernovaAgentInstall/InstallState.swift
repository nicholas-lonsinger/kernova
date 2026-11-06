#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// The slot metadata in `state.json`: which slot is in use, what each holds, the update switch not yet
/// confirmed, and the payload the install refuses.
///
/// While the agent runs, only it writes the file; the rollback check reads it and writes nothing but its own
/// markers (``SlotRoot``).
struct InstallState: Codable, Equatable, Sendable {
    /// What one slot holds.
    struct Slot: Codable, Equatable, Sendable {
        /// The payload's SHA-256, lowercase hex.
        var payloadSHA256: String
        /// The display version the payload reports.
        var versionLabel: String
    }

    /// An update's switch of `current` from one slot to another, unconfirmed while its marker exists.
    struct Switch: Codable, Equatable, Sendable {
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
    /// The payload this install will not update itself to.
    var rejected: Rejection?

    /// A payload the install will not update itself to, and why.
    struct Rejection: Equatable, Sendable {
        /// The payload's SHA-256, lowercase hex.
        var payloadSHA256: String
        /// The code the installer's refusal of it reported; nil when none was recorded, as for a rollback.
        var code: ErrorCode?
    }

    private enum CodingKeys: String, CodingKey {
        case active, slots
        case pendingSwitch = "switch"
        case rejectedSHA256 = "rejectedPayloadSHA256"
        case rejectedCode = "rejectedPayloadCode"
    }

    init(active: String, slots: [String: Slot], pendingSwitch: Switch? = nil, rejected: Rejection? = nil) {
        self.active = active
        self.slots = slots
        self.pendingSwitch = pendingSwitch
        self.rejected = rejected
    }

    /// The rejection's code is written beside its hash, and read only with one.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        active = try container.decode(String.self, forKey: .active)
        slots = try container.decode([String: Slot].self, forKey: .slots)
        pendingSwitch = try container.decodeIfPresent(Switch.self, forKey: .pendingSwitch)
        if let hash = try container.decodeIfPresent(String.self, forKey: .rejectedSHA256) {
            let code = try container.decodeIfPresent(Int.self, forKey: .rejectedCode)
            rejected = Rejection(payloadSHA256: hash, code: code.flatMap { ErrorCode(rawValue: $0) })
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(active, forKey: .active)
        try container.encode(slots, forKey: .slots)
        try container.encodeIfPresent(pendingSwitch, forKey: .pendingSwitch)
        try container.encodeIfPresent(rejected?.payloadSHA256, forKey: .rejectedSHA256)
        try container.encodeIfPresent(rejected?.code?.rawValue, forKey: .rejectedCode)
    }

    /// The state after a fresh install of the payload hashing to `payloadSHA256` into `slot`.
    static func fresh(slot: String, payloadSHA256: String, versionLabel: String) -> InstallState {
        InstallState(active: slot, slots: [slot: Slot(payloadSHA256: payloadSHA256, versionLabel: versionLabel)])
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
