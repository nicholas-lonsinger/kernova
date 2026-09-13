import Foundation

/// What makes one physical USB accessory the same unit across a
/// re-enumeration.
///
/// `registryID` is the handle VZ and every Kernova surface name an accessory
/// by, and `IOKitLib.h` says of it: "The ID is valid only until the machine
/// reboots." In practice it is shorter-lived still — detaching a passthrough
/// device resets it, which mints a new IORegistry node and a new ID for the
/// same stick in the same port. This is the key that outlives that.
///
/// Runtime-only, like everything else about an accessory: it is what lets one
/// assignment be recognised as the echo of another inside a session, not
/// something written to a bundle.
struct USBAccessoryIdentity: Sendable, Equatable, Hashable {
    /// How much the key can be trusted to name one *unit* rather than one
    /// model in one place.
    enum Form: Sendable, Equatable, Hashable {
        /// Built on the serial number the device reports, which follows it to
        /// any port.
        case serialNumber
        /// Built on the receptacle the device is in, because it reports no
        /// serial or reports one another assigned accessory already answers
        /// to. It names whatever is in that port, so it must not be taken to
        /// follow the device anywhere else.
        case receptacle
    }

    /// The key itself — `vid:pid:bcdDevice:serial`, or
    /// `vid:pid:bcdDevice@receptacle`.
    let key: String
    /// Which of the two `key` is, so a caller can tell a claim about a unit
    /// from a claim about a port.
    let form: Form

    /// The identity of the accessory `descriptor` describes on the node
    /// `node` describes, or `nil` when neither a serial nor a receptacle is
    /// readable and nothing durable names it.
    ///
    /// `claimed` is the key of every accessory Kernova already holds. A serial
    /// one of them already answers to cannot name this unit as well — vendors
    /// ship duplicates, and the USB 2.0 spec makes the serial optional in the
    /// first place — so the newcomer falls back to its receptacle rather than
    /// claiming a key that would match the wrong device.
    ///
    /// Composed once, at assignment, and never recomposed: a key already
    /// handed out has to keep naming the same unit for as long as Kernova
    /// holds it.
    static func make(
        descriptor: USBDeviceDescriptor,
        node: USBAccessoryNodeProperties,
        claimedBy claimed: Set<String>
    ) -> USBAccessoryIdentity? {
        let model = descriptor.modelKey
        if let serial = node.serialNumber, !serial.isEmpty {
            let key = "\(model):\(serial)"
            if !claimed.contains(key) { return USBAccessoryIdentity(key: key, form: .serialNumber) }
        }
        guard let receptacle = node.receptacleKey else { return nil }
        return USBAccessoryIdentity(key: "\(model)@\(receptacle)", form: .receptacle)
    }
}
