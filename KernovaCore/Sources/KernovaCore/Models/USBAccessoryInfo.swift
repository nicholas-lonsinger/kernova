import Foundation
import KernovaCommandModel
import KernovaKit

/// A host USB accessory macOS has assigned to Kernova.
///
/// Runtime-only, never persisted. ``registryID`` is the in-session handle —
/// what VZ is given and what every verb names this accessory by — and
/// ``identity`` is what survives the re-enumeration a detach causes.
package struct USBAccessoryInfo: Sendable, Equatable, Identifiable {
    /// `AAUSBAccessory.registryID`.
    package let registryID: UInt64
    let descriptor: USBDeviceDescriptor
    /// What names this unit across a re-enumeration, or `nil` when the
    /// IORegistry node answered nothing durable — in which case an accessory
    /// that goes away cannot be recognised when it comes back.
    package let identity: USBAccessoryIdentity?
    /// What the menu, the overview and `kernova usb list` call this accessory.
    package let displayName: String
    /// The receptacle in the words the hardware uses for it, for the one job
    /// the name cannot do alone: telling two identical devices apart.
    let receptacleLabel: String?

    package var id: UInt64 { registryID }

    /// Describes the accessory `registryID` names.
    ///
    /// `node` is what the IORegistry reports about it, `nil` when no node
    /// answered. `held` is every accessory some unit already answers to —
    /// assigned to Kernova, or captured by a guest — and decides which keys are
    /// still free for this one, see
    /// ``USBAccessoryIdentity/make(descriptor:node:claimedBy:)``.
    package static func make(
        registryID: UInt64,
        descriptor: USBDeviceDescriptor,
        configurationDescriptor: Data?,
        node: USBAccessoryNodeProperties?,
        claimedBy held: [USBAccessoryInfo] = []
    ) -> USBAccessoryInfo {
        USBAccessoryInfo(
            registryID: registryID,
            descriptor: descriptor,
            identity: node.flatMap {
                USBAccessoryIdentity.make(
                    descriptor: descriptor, node: $0,
                    claimedBy: keysClaimedAgainst(arrivalIn: $0.receptacleKey, by: held))
            },
            displayName: name(
                descriptor: descriptor, configurationDescriptor: configurationDescriptor,
                node: node),
            receptacleLabel: node?.receptacleLabel)
    }

    /// The keys `held` holds that an accessory arriving in `receptacle` may not
    /// take.
    ///
    /// A key held by a unit in that same receptacle is not among them:
    /// detaching a passthrough device resets it, and what macOS hands back
    /// about 700 ms later is the same stick in the same hole. It has to retake
    /// its key, or the record still naming it could never be reconciled and the
    /// accessory a warm capture ejected could never be found again. Every other
    /// key belongs to a unit somewhere else — a second one of a model whose
    /// vendor duplicated the serial, above all — and handing it the same key
    /// would make one indistinguishable from the other.
    private static func keysClaimedAgainst(
        arrivalIn receptacle: String?, by held: [USBAccessoryInfo]
    ) -> Set<String> {
        Set(
            held.compactMap { holder -> String? in
                guard let identity = holder.identity else { return nil }
                guard receptacle == nil || identity.receptacleKey != receptacle else { return nil }
                return identity.key
            })
    }

    /// Whether the durable key this accessory carries names it and no other
    /// unit among `known`, every accessory Kernova knows about — what decides
    /// whether a key may stand for this unit, for an automatic attach and for
    /// an accessory a shortcut picked alike.
    ///
    /// A key built on the serial number follows the unit. One built on a
    /// receptacle names whatever is in that port, so while another unit of the
    /// same model is connected, the one in the port may be either of them. An
    /// accessory with no key is named by nothing durable. An accessory `known`
    /// lists twice — captured by a guest, and not yet withdrawn by macOS — is
    /// one unit.
    func keyNamesItAlone(among known: [USBAccessoryInfo]) -> Bool {
        guard let identity else { return false }
        return identity.form == .serialNumber
            || !known.contains {
                $0.registryID != registryID && $0.descriptor.modelKey == descriptor.modelKey
            }
    }

    /// What to call this accessory.
    ///
    /// The device's own vendor and product strings first — "Samsung Type-C" is
    /// what is in the user's hand. Only a device that reports neither falls
    /// back to the identifiers, named by the class that means something: its
    /// own when it declares one, and otherwise its first interface's, because
    /// a flash drive reporting `bDeviceClass` 0 is mass storage and not
    /// "Composite".
    private static func name(
        descriptor: USBDeviceDescriptor, configurationDescriptor: Data?,
        node: USBAccessoryNodeProperties?
    ) -> String {
        let reported = [node?.vendorName, node?.productName]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !reported.isEmpty { return reported.joined(separator: " ") }

        let className =
            descriptor.className
            ?? configurationDescriptor
            .flatMap(USBConfigurationDescriptor.firstInterfaceClass(in:))
            .flatMap(USBClassCode.name)
        guard let className else { return descriptor.vendorProductID }
        return "\(descriptor.vendorProductID) · \(className)"
    }

    /// The name each accessory Kernova knows about is listed under — the
    /// `attached` ones guests hold and the `assigned` ones macOS has handed
    /// Kernova — each its own among them (``NameRule/listing(of:qualifiers:identifiers:)``):
    /// an accessory another reads like, or whose name is all digits as a
    /// registry ID is, is qualified by its receptacle, else its serial
    /// number, else its registry ID, whichever first tells it apart.
    ///
    /// Two units of one model are an ordinary thing to own, and a menu
    /// offering the same words twice says nothing about which is which. The
    /// qualifier is not part of ``displayName``: it is a fact about the
    /// list, not about the device. Computed across both sets at once, because
    /// a guest's accessories and the free ones are read side by side, and two
    /// identical devices have to be told apart across that boundary as
    /// readily as within it.
    ///
    /// Each accessory counts once. macOS withdraws an accessory a guest has
    /// captured, but not always before the guest's own record is read, and one
    /// counted twice would look like two of a kind and qualify itself.
    static func listingNames(
        attached: [USBAccessoryInfo], assigned: [USBAccessoryInfo]
    ) -> [UInt64: String] {
        let attachedIDs = Set(attached.map(\.registryID))
        let accessories = attached + assigned.filter { !attachedIDs.contains($0.registryID) }
        let names = NameRule.listing(
            of: accessories.map(\.displayName),
            qualifiers: accessories.map {
                [$0.receptacleLabel, $0.serialNumber].compactMap { $0 } + [String($0.registryID)]
            },
            identifiers: registryIDs)
        return Dictionary(zip(accessories.map(\.registryID), names), uniquingKeysWith: { first, _ in first })
    }

    /// Text a script reads as a registry ID: all decimal digits.
    static let registryIDs = NameRule.Identifiers { !$0.isEmpty && $0.allSatisfy { ("0"..."9").contains($0) } }

    /// The serial number its durable key is built on, `nil` when the key
    /// names its receptacle instead.
    private var serialNumber: String? {
        guard let identity, identity.form == .serialNumber else { return nil }
        return String(identity.key.dropFirst(descriptor.modelKey.count + 1))
    }
}

extension USBAccessorySummary {
    /// `accessory` under its name in `names`
    /// (``USBAccessoryInfo/listingNames(attached:assigned:)``), carrying the
    /// attachment `deviceID` while a guest holds it.
    init(_ accessory: USBAccessoryInfo, named names: [UInt64: String], deviceID: UUID? = nil) {
        self.init(
            registryID: accessory.registryID,
            name: names[accessory.registryID] ?? accessory.displayName,
            vendorID: accessory.descriptor.vendorID,
            productID: accessory.descriptor.productID,
            deviceID: deviceID,
            key: accessory.identity?.key)
    }
}

/// A passthrough device a running guest currently holds, and the accessory
/// behind it.
///
/// Runtime-only: the attachment lives no longer than the session, and nothing
/// re-creates it on restore.
package struct AttachedUSBAccessory: Sendable, Equatable, Identifiable {
    /// The `VZUSBDevice.uuid` VZ minted for the attachment, and what a detach
    /// names.
    package let deviceID: UUID
    package let accessory: USBAccessoryInfo
    let attachedAt: Date

    package var id: UUID { deviceID }

    package init(deviceID: UUID, accessory: USBAccessoryInfo, attachedAt: Date = Date()) {
        self.deviceID = deviceID
        self.accessory = accessory
        self.attachedAt = attachedAt
    }
}
