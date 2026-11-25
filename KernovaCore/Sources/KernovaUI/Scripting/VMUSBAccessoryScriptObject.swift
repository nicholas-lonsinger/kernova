import Cocoa
import KernovaCommandModel
import KernovaCore
import KernovaLogging

/// One USB accessory a guest holds, as `detach` names it: the VM whose guest
/// holds it, and the attachment.
struct VMUSBAttachment: Sendable {
    let vm: UUID
    let device: UUID
}

/// One USB accessory macOS has assigned to Kernova, as the scripting
/// dictionary's `USB accessory`, each ``USBAccessorySummary`` field read by
/// the key ``key(carrying:)`` names: an element of the application while no
/// guest holds it, and of the VM whose guest does.
///
/// A copy of one read, like ``VMScriptObject``: its container lists them
/// afresh on every specifier evaluation. Every property is read only.
@MainActor
@objc(VMUSBAccessoryScriptObject)
package final class VMUSBAccessoryScriptObject: NSObject {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMUSBAccessoryScriptObject")

    /// Where an accessory is, which is which of the two verbs takes it.
    enum Place: Sendable {
        /// Held by no guest: `attach` takes it.
        case available
        /// Held by a guest: `detach` takes it back.
        case attached(VMUSBAttachment)
    }

    /// The read every property answers from.
    private let accessory: USBAccessorySummary
    let place: Place

    /// `accessory`, held by no guest.
    init(available accessory: USBAccessorySummary) {
        self.accessory = accessory
        place = .available
    }

    /// `accessory` as the guest of the VM `vm` identifies holds it, or `nil`
    /// for a listing that names no attachment, which the core gives every
    /// accessory a guest holds.
    init?(_ accessory: USBAccessorySummary, attachedTo vm: UUID) {
        guard let device = accessory.deviceID else {
            Self.logger.log(
                .fault,
                "USB accessory \(accessory.registryID, privacy: .public) listed as held by \(vm.uuidString, privacy: .public) has no attachment"
            )
            assertionFailure("USB accessory \(accessory.registryID) listed as held by \(vm) has no attachment")
            return nil
        }
        self.accessory = accessory
        place = .attached(VMUSBAttachment(vm: vm, device: device))
    }

    /// What an attach names the accessory by.
    nonisolated var registryID: UInt64 { accessory.registryID }

    // MARK: - Properties

    /// ``USBAccessorySummary/registryID``, as text: the number exceeds what an
    /// AppleScript integer holds.
    @objc var uniqueID: String { Self.identifier(of: accessory) }

    @objc var name: String { accessory.name }

    @objc var vendorID: Int { Int(accessory.vendorID) }

    @objc var productID: Int { Int(accessory.productID) }

    @objc var key: String? { accessory.key }

    /// The text `USB accessory id "…"` names `accessory` by.
    nonisolated static func identifier(of accessory: USBAccessorySummary) -> String {
        String(accessory.registryID)
    }

    /// The Cocoa key of the property the dictionary reads `field` by — the key
    /// `Kernova.sdef` gives that term, which `KernovaScriptingDefinitionTests`
    /// checks — or `nil` for a field no term reads.
    static func key(carrying field: USBAccessorySummary.Field) -> String? {
        switch field {
        case .registryID: #keyPath(VMUSBAccessoryScriptObject.uniqueID)
        case .name: #keyPath(VMUSBAccessoryScriptObject.name)
        case .vendorID: #keyPath(VMUSBAccessoryScriptObject.vendorID)
        case .productID: #keyPath(VMUSBAccessoryScriptObject.productID)
        case .key: #keyPath(VMUSBAccessoryScriptObject.key)
        // Names the attachment `detach` ends, which it reads off the guest's
        // own listing (``Place``).
        case .deviceID: nil
        }
    }

    // MARK: - Specifier

    /// How a script names this accessory back — `USB accessory id "…"` of the
    /// application while no guest holds it, and of `virtual machine id "…"`
    /// while that VM's guest does.
    package nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        let container: (description: NSScriptClassDescription?, specifier: NSScriptObjectSpecifier?)
        switch place {
        case .available:
            container = (NSScriptClassDescription(for: NSApplication.self), nil)
        case .attached(let attachment):
            container = (
                NSScriptClassDescription(for: VMScriptObject.self), VMScriptObject.specifier(for: attachment.vm)
            )
        }
        guard let description = container.description else {
            Self.logger.log(.fault, "The USB accessory's container has no scripting class description")
            assertionFailure("The USB accessory's container has no scripting class description")
            return nil
        }
        return NSUniqueIDSpecifier(
            containerClassDescription: description,
            containerSpecifier: container.specifier,
            key: VMScriptObject.usbAccessoriesKey,
            uniqueID: Self.identifier(of: accessory))
    }
}

/// One remembered USB accessory, as a verb a script runs names it: the VM
/// that takes it back, and the durable key it is remembered by, which names
/// one of that VM's.
struct VMRememberedUSBAccessoryAddress: Sendable {
    let vm: UUID
    let key: String
}

/// One USB accessory a VM takes back automatically, plugged in or not, as the
/// scripting dictionary's `remembered USB accessory`, each
/// ``USBPairingSummary`` field read by the key ``key(carrying:)`` names.
///
/// A copy of one read, like ``VMScriptObject``: the VM lists them afresh on
/// every specifier evaluation. Every property is read only.
@MainActor
@objc(VMRememberedUSBAccessoryScriptObject)
package final class VMRememberedUSBAccessoryScriptObject: NSObject {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMRememberedUSBAccessoryScriptObject")

    /// The read every property answers from.
    private let pairing: USBPairingSummary
    /// Which remembered accessory it is.
    let address: VMRememberedUSBAccessoryAddress

    init(_ pairing: USBPairingSummary, of vm: UUID) {
        self.pairing = pairing
        address = VMRememberedUSBAccessoryAddress(vm: vm, key: pairing.key)
    }

    // MARK: - Properties

    @objc var name: String { pairing.name }

    @objc var key: String { pairing.key }

    @objc var dateRemembered: Date { pairing.pairedAt }

    /// The Cocoa key of the property the dictionary reads `field` by — the key
    /// `Kernova.sdef` gives that term, which `KernovaScriptingDefinitionTests`
    /// checks — or `nil` for a field no term reads.
    static func key(carrying field: USBPairingSummary.Field) -> String? {
        switch field {
        case .name: #keyPath(VMRememberedUSBAccessoryScriptObject.name)
        case .key: #keyPath(VMRememberedUSBAccessoryScriptObject.key)
        case .pairedAt: #keyPath(VMRememberedUSBAccessoryScriptObject.dateRemembered)
        // The VM the read named, which is the element's container.
        case .vm: nil
        }
    }

    // MARK: - Specifier

    /// How a script names this accessory back — `remembered USB accessory
    /// "<key>"` of `virtual machine id "…"`: the key names one of the VM's
    /// (``VMScriptingGateway/rememberedUSBAccessory(named:of:)``).
    package nonisolated override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let virtualMachine = NSScriptClassDescription(for: VMScriptObject.self) else {
            Self.logger.log(.fault, "VMScriptObject has no scripting class description")
            assertionFailure("VMScriptObject has no scripting class description")
            return nil
        }
        return NSNameSpecifier(
            containerClassDescription: virtualMachine,
            containerSpecifier: VMScriptObject.specifier(for: address.vm),
            key: VMScriptObject.rememberedUSBAccessoriesKey,
            name: address.key)
    }
}
