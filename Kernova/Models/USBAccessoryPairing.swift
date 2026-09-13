import Foundation

/// One USB accessory a VM takes back automatically: the durable key the unit
/// answers to, and enough of its description to name it in a list while the
/// device itself is in a drawer.
///
/// A preference about what to attach, never part of the VM's configuration — a
/// saved state restored into a configuration naming hardware that is no longer
/// present fails, and both save paths detach first for that reason.
struct USBAccessoryPairing: Codable, Sendable, Equatable, Identifiable {
    /// ``USBAccessoryIdentity/key``.
    let key: String
    /// Which claim ``key`` makes — about one unit, or about one port.
    let form: USBAccessoryIdentity.Form
    /// What a list calls this accessory while nothing is plugged in to ask.
    let displayName: String
    /// The receptacle in the hardware's own words, for the one job the name
    /// cannot do alone: telling two identical units apart. `nil` when the node
    /// named none.
    let receptacleLabel: String?
    let pairedAt: Date

    var id: String { key }

    init(
        key: String, form: USBAccessoryIdentity.Form, displayName: String,
        receptacleLabel: String?, pairedAt: Date = Date()
    ) {
        self.key = key
        self.form = form
        self.displayName = displayName
        self.receptacleLabel = receptacleLabel
        self.pairedAt = pairedAt
    }

    /// The pairing that would name `accessory`, or `nil` when nothing durable
    /// identifies it.
    static func make(for accessory: USBAccessoryInfo, at pairedAt: Date = Date())
        -> USBAccessoryPairing?
    {
        guard let identity = accessory.identity else { return nil }
        return USBAccessoryPairing(
            key: identity.key, form: identity.form, displayName: accessory.displayName,
            receptacleLabel: accessory.receptacleLabel, pairedAt: pairedAt)
    }
}

/// The `usb-accessories.json` payload: every accessory one VM takes back.
struct USBAccessoryPairingSet: Codable, Sendable, Equatable {
    /// Storage order is the order the pairings were made.
    var pairings: [USBAccessoryPairing]

    init(pairings: [USBAccessoryPairing] = []) {
        self.pairings = pairings
    }

    // Custom `init(from:)` so a file holding an object with no `pairings` key
    // reads as "this VM takes nothing back" rather than failing the whole
    // decode, the way a `decode` of a non-optional field would.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pairings =
            try container.decodeIfPresent([USBAccessoryPairing].self, forKey: .pairings) ?? []
    }

    var isEmpty: Bool { pairings.isEmpty }

    /// The pairing `identity` answers to, or `nil` when this VM claims it not.
    ///
    /// Key and form only — deliberately *not* the receptacle, unlike the full
    /// identity equality reconciliation uses. A serial-form key follows the unit
    /// to any port, so narrowing it by receptacle would break the case it exists
    /// for; a receptacle-form key already spells the port into the key itself,
    /// so key equality pins the port without any help.
    func pairing(matching identity: USBAccessoryIdentity) -> USBAccessoryPairing? {
        pairings.first { $0.key == identity.key && $0.form == identity.form }
    }

    /// Records `pairing`, replacing any this VM already held for the same key.
    mutating func upsert(_ pairing: USBAccessoryPairing) {
        if let index = pairings.firstIndex(where: { $0.key == pairing.key }) {
            pairings[index] = pairing
        } else {
            pairings.append(pairing)
        }
    }

    /// Drops the pairing for `key`, if this VM held one.
    mutating func remove(key: String) {
        pairings.removeAll { $0.key == key }
    }
}
