import Foundation

/// Which edit classes may write each stored field of one state file — the one
/// classification a commit checks every write against, whatever its caller
/// asked admission for.
///
/// A field's classes are the ones any *one* of which may write the move: an
/// ``VMEditPermit/Authority/edit(_:)`` permit writes a field only when its
/// classes meet the field's, and an empty set is a field no edit writes — only
/// the operation holding the VM.
struct VMStateFieldClasses<Root: Sendable>: Sendable {
    /// One stored field and the classes that may write a move of it.
    struct Field: Sendable {
        let name: String
        let keyPath: PartialKeyPath<Root> & Sendable
        /// The classes that may write the move from the first value to the
        /// second, or `nil` when the field did not move.
        let classes: @Sendable (Root, Root) -> VMEditClasses?

        /// A field these classes write, whatever the values.
        static func field<Value: Equatable>(
            _ name: String, _ keyPath: KeyPath<Root, Value> & Sendable, _ classes: VMEditClasses
        ) -> Field {
            field(name, keyPath) { _, _ in classes }
        }

        /// A field whose writers depend on what it moves from and to.
        static func field<Value: Equatable>(
            _ name: String, _ keyPath: KeyPath<Root, Value> & Sendable,
            byValue classes: @escaping @Sendable (_ old: Value, _ new: Value) -> VMEditClasses
        ) -> Field {
            Field(name: name, keyPath: keyPath) { old, new in
                let (from, to) = (old[keyPath: keyPath], new[keyPath: keyPath])
                return from == to ? nil : classes(from, to)
            }
        }
    }

    let fields: [Field]

    /// The fields that moved from `old` to `new` which `authority` may not
    /// write, by name.
    func refused(
        from old: Root, to new: Root, by authority: VMEditPermit.Authority
    ) -> [String] {
        fields.compactMap { field in
            guard let classes = field.classes(old, new), !authority.mayWrite(classes) else {
                return nil
            }
            return field.name
        }
    }
}

/// A write refused because it moved fields its permit's authority may not
/// write; the file is left as it was.
struct VMStateFieldRefusal: Error, Equatable {
    let fields: [String]
}

extension VMConfiguration {
    /// Every stored field of `config.json` and what may write it.
    static let fieldClasses = VMStateFieldClasses<VMConfiguration>(fields: [
        // Identity, and what creation and setup alone record.
        .field("id", \.id, []),
        .field("name", \.name, .rename),
        .field("guestOS", \.guestOS, []),
        .field("bootMode", \.bootMode, []),
        .field("diskSizeInGB", \.diskSizeInGB, []),
        .field("hardwareModelData", \.hardwareModelData, []),
        .field("machineIdentifierData", \.machineIdentifierData, []),
        .field("genericMachineIdentifierData", \.genericMachineIdentifierData, []),
        .field("installContext", \.installContext, []),
        .field("linuxInstallContext", \.linuxInstallContext, []),
        .field("installedImage", \.installedImage, []),
        .field("createdAt", \.createdAt, []),
        // Hardware the machine is built from.
        .field("cpuCount", \.cpuCount, .machineKeys),
        .field("memorySizeInGB", \.memorySizeInGB, .machineKeys),
        .field("displayWidth", \.displayWidth, .machineKeys),
        .field("displayHeight", \.displayHeight, .machineKeys),
        .field("displayPPI", \.displayPPI, .machineKeys),
        .field("displaySizesToWindow", \.displaySizesToWindow, .machineKeys),
        .field("displayHiDPI", \.displayHiDPI, .machineKeys),
        .field("audioInputEnabled", \.audioInputEnabled, .machineKeys),
        .field("audioOutputEnabled", \.audioOutputEnabled, .machineKeys),
        .field("inputDeviceMode", \.inputDeviceMode, .machineKeys),
        .field("kernelPath", \.kernelPath, .machineKeys),
        .field("initrdPath", \.initrdPath, .machineKeys),
        .field("kernelCommandLine", \.kernelCommandLine, .machineKeys),
        .field("kernelBookmark", \.kernelBookmark, .machineKeys),
        .field("initrdBookmark", \.initrdBookmark, .machineKeys),
        .field("storageDisks", \.storageDisks, .machineKeys),
        .field("sharedDirectories", \.sharedDirectories, .machineKeys),
        .field("removableMedia", \.removableMedia, .hotPlugMedia),
        // The network device: adding or removing it is hardware, and a mode
        // or interface change on the device it has is the live swap. A device
        // added with no address mints its first one.
        .field("networkEnabled", \.networkEnabled) { _, enabled in
            enabled ? [.machineKeys, .networkAttachment] : .machineKeys
        },
        .field("networkMode", \.networkMode, [.machineKeys, .networkAttachment]),
        .field(
            "bridgedInterfaceIdentifier", \.bridgedInterfaceIdentifier,
            [.machineKeys, .networkAttachment]),
        .field("macAddress", \.macAddress) { old, _ in
            old == nil ? [.machineKeys, .networkAttachment] : .machineKeys
        },
        // Settings read at moments other than boot.
        .field("displayAutoResizes", \.displayAutoResizes, .liveKeys),
        .field("clipboardSharingEnabled", \.clipboardSharingEnabled, .liveKeys),
        .field("clipboardPassthroughEnabled", \.clipboardPassthroughEnabled, .liveKeys),
        .field("dropFilesEnabled", \.dropFilesEnabled, .liveKeys),
        .field("serialSocketRelayEnabled", \.serialSocketRelayEnabled, .liveKeys),
        .field("systemKeyForwarding", \.systemKeyForwarding, .liveKeys),
        .field("agentLogForwardingEnabled", \.agentLogForwardingEnabled, .liveKeys),
        // An observation retracts the account once the boot that delivers it
        // has run; only the user's own choice skips it otherwise.
        .field("pendingGuestAccount", \.pendingGuestAccount) { _, account in
            account == nil ? [.liveKeys, .observations] : []
        },
        // What the guest reported.
        .field("lastSeenAgentVersion", \.lastSeenAgentVersion, .observations),
        .field("lastSeenGuestOSVersion", \.lastSeenGuestOSVersion, .observations),
    ])
}

extension VMHostState {
    /// Every stored field of `host-state.json` and what may write it.
    static let fieldClasses = VMStateFieldClasses<VMHostState>(fields: [
        .field("startsAutomaticallyOnLaunch", \.startsAutomaticallyOnLaunch, .liveKeys),
        .field("ephemeralModeEnabled", \.ephemeralModeEnabled, .liveKeys),
        .field("ephemeralBaselineSnapshotID", \.ephemeralBaselineSnapshotID, .liveKeys),
        .field("displayPreference", \.displayPreference, .liveKeys),
        .field("lastFullscreenDisplayID", \.lastFullscreenDisplayID, .hostPresentation),
        // An agent that never showed up is evidence against a silenced
        // install reminder, so an observation may turn it back on; only the
        // user silences it.
        .field("agentInstallNudgeDismissed", \.agentInstallNudgeDismissed) { _, dismissed in
            dismissed ? .liveKeys : [.liveKeys, .observations]
        },
    ])
}

extension VMSnapshotManifest {
    /// Every stored field of `Snapshots/manifest.json` and what may write it:
    /// which snapshot is current changes only with a capture or a revert.
    static let fieldClasses = VMStateFieldClasses<VMSnapshotManifest>(fields: [
        .field("snapshots", \.snapshots, .snapshotMetadata),
        .field("currentID", \.currentID, []),
    ])
}

extension USBAccessoryPairingSet {
    /// Every stored field of `usb-accessories.json` and what may write it.
    static let fieldClasses = VMStateFieldClasses<USBAccessoryPairingSet>(fields: [
        .field("pairings", \.pairings, .pairingRules)
    ])
}
