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
    /// answered. `claimed` is the identity key of every accessory Kernova
    /// already holds — see ``USBAccessoryIdentity/make(descriptor:node:claimedBy:)``.
    static func make(
        registryID: UInt64,
        descriptor: USBDeviceDescriptor,
        configurationDescriptor: Data?,
        node: USBAccessoryNodeProperties?,
        claimedBy claimed: Set<String> = []
    ) -> USBAccessoryInfo {
        USBAccessoryInfo(
            registryID: registryID,
            descriptor: descriptor,
            identity: node.flatMap {
                USBAccessoryIdentity.make(descriptor: descriptor, node: $0, claimedBy: claimed)
            },
            displayName: name(
                descriptor: descriptor, configurationDescriptor: configurationDescriptor,
                node: node),
            receptacleLabel: node?.receptacleLabel)
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
