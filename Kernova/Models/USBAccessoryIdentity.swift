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
/// It also outlives the process: ``USBAccessoryPairing`` stores ``key`` and
/// ``form`` in the VM bundle, which is what lets a device the user placed on a
/// guest go back to it after a stop, a quit, or a replug. ``receptacleKey`` is
/// the one part that stays in memory — it says where the unit was *this* time,
/// which is a fact about the session and not about the unit.
struct USBAccessoryIdentity: Sendable, Equatable, Hashable {
    /// How much the key can be trusted to name one *unit* rather than one
    /// model in one place.
    ///
    /// Stored alongside the key wherever a key is, rather than parsed back out
    /// of it: a serial may legally contain `@`, so the two spellings are not
    /// separable after the fact.
    enum Form: String, Sendable, Equatable, Hashable, Codable {
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
    /// The receptacle the unit was in when this was composed, `nil` when the
    /// node named none.
    ///
    /// Compared alongside ``key``, so two accessories are equal only when they
    /// are the same unit in the same place. The echo of a detach comes back in
    /// the receptacle it left; a second unit of a model whose vendor duplicated
    /// the serial arrives in a different one, and a key alone cannot tell those
    /// apart.
    let receptacleKey: String?

    /// The identity of the accessory `descriptor` describes on the node
    /// `node` describes, or `nil` when nothing durable is left to name it —
    /// neither a serial nor a receptacle is readable, or both keys it could
    /// compose are already spoken for.
    ///
    /// `claimed` is the key of every accessory another unit already answers to.
    /// A serial one of them holds cannot name this unit as well — vendors ship
    /// duplicates, and the USB 2.0 spec makes the serial optional in the first
    /// place — so the newcomer falls back to its receptacle, and gives up
    /// rather than take a key that would match the wrong device.
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
        let receptacle = node.receptacleKey
        if let serial = node.serialNumber, !serial.isEmpty {
            let key = "\(model):\(serial)"
            if !claimed.contains(key) {
                return USBAccessoryIdentity(
                    key: key, form: .serialNumber, receptacleKey: receptacle)
            }
        }
        guard let receptacle else { return nil }
        let key = "\(model)@\(receptacle)"
        guard !claimed.contains(key) else { return nil }
        return USBAccessoryIdentity(key: key, form: .receptacle, receptacleKey: receptacle)
    }
}
