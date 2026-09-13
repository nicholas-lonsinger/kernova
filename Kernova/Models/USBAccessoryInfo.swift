import Foundation

/// A host USB accessory macOS has assigned to Kernova.
///
/// Runtime-only, never persisted. ``registryID`` is the in-session handle —
/// what VZ is given and what every verb names this accessory by — and
/// ``identity`` is what survives the re-enumeration a detach causes.
struct USBAccessoryInfo: Sendable, Equatable, Identifiable {
    /// `AAUSBAccessory.registryID`.
    let registryID: UInt64
    let descriptor: USBDeviceDescriptor
    /// What names this unit across a re-enumeration, or `nil` when the
    /// IORegistry node answered nothing durable — in which case an accessory
    /// that goes away cannot be recognised when it comes back.
    let identity: USBAccessoryIdentity?
    /// What the menu, the overview and `kernova usb list` call this accessory.
    let displayName: String
    /// The receptacle in the words the hardware uses for it, for the one job
    /// the name cannot do alone: telling two identical devices apart.
    let receptacleLabel: String?

    var id: UInt64 { registryID }

    /// Describes the accessory `registryID` names.
    ///
    /// `node` is what the IORegistry reports about it, `nil` when no node
    /// answered. `held` is every accessory some unit already answers to —
    /// assigned to Kernova, or captured by a guest — and decides which keys are
    /// still free for this one, see
    /// ``USBAccessoryIdentity/make(descriptor:node:claimedBy:)``.
    static func make(
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

    /// The name each of `accessories` is listed under, qualified by its
    /// receptacle where two of them would otherwise read identically.
    ///
    /// Two units of one model are an ordinary thing to own, and a menu
    /// offering the same words twice says nothing about which is which. The
    /// qualifier is deliberately not part of ``displayName``: it is a fact
    /// about the list, not about the device.
    static func listingNames(for accessories: [USBAccessoryInfo]) -> [UInt64: String] {
        let counts = accessories.reduce(into: [String: Int]()) { $0[$1.displayName, default: 0] += 1 }
        return accessories.reduce(into: [UInt64: String]()) { names, accessory in
            guard counts[accessory.displayName, default: 0] > 1,
                let label = accessory.receptacleLabel
            else {
                names[accessory.registryID] = accessory.displayName
                return
            }
            names[accessory.registryID] = "\(accessory.displayName) (\(label))"
        }
    }
}

/// A passthrough device a running guest currently holds, and the accessory
/// behind it.
///
/// Runtime-only: the attachment lives no longer than the session, and nothing
/// re-creates it on restore.
struct AttachedUSBAccessory: Sendable, Equatable, Identifiable {
    /// The `VZUSBDevice.uuid` VZ minted for the attachment, and what a detach
    /// names.
    let deviceID: UUID
    let accessory: USBAccessoryInfo
    let attachedAt: Date

    var id: UUID { deviceID }

    init(deviceID: UUID, accessory: USBAccessoryInfo, attachedAt: Date = Date()) {
        self.deviceID = deviceID
        self.accessory = accessory
        self.attachedAt = attachedAt
    }
}
