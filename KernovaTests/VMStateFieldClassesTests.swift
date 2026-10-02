import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// The one classification of which edit classes may write each stored field
/// of a VM's state files.
@Suite("VMStateFieldClasses Tests", .caseScoped)
struct VMStateFieldClassesTests {
    /// Fails for a stored property of `value`'s type the classification does
    /// not name, for a name it holds that is no stored property, and for an
    /// entry whose key path reaches no stored property or repeats another's.
    private static func expectExhaustive<Root>(
        _ classification: VMStateFieldClasses<Root>, over value: Root,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let stored = Mirror(reflecting: value).children.compactMap(\.label)
        let classified = classification.fields.map(\.name)
        #expect(
            Set(stored).subtracting(classified).sorted() == [],
            "stored fields with no classification", sourceLocation: sourceLocation)
        #expect(
            Set(classified).subtracting(stored).sorted() == [],
            "classified names that are no stored field", sourceLocation: sourceLocation)
        #expect(classified.count == Set(classified).count, sourceLocation: sourceLocation)
        let keyPaths = classification.fields.map { $0.keyPath as AnyKeyPath }
        #expect(keyPaths.count == Set(keyPaths).count, sourceLocation: sourceLocation)
        for field in classification.fields {
            #expect(
                MemoryLayout<Root>.offset(of: field.keyPath) != nil,
                "\(field.name) reaches no stored property", sourceLocation: sourceLocation)
        }
    }

    @Test("Every stored field of every state file has a classification")
    func everyStoredFieldIsClassified() {
        Self.expectExhaustive(
            VMConfiguration.fieldClasses,
            over: VMConfiguration(name: "VM", guestOS: .macOS, bootMode: .macOS))
        Self.expectExhaustive(VMHostState.fieldClasses, over: VMHostState())
        Self.expectExhaustive(VMSnapshotManifest.fieldClasses, over: VMSnapshotManifest())
        Self.expectExhaustive(USBAccessoryPairingSet.fieldClasses, over: USBAccessoryPairingSet())
    }

    @Test("A field is refused only when it moved and no class of the edit may write it")
    func refusalMeetsTheFieldsClasses() {
        let old = VMConfiguration(name: "VM", guestOS: .linux, bootMode: .efi)
        var new = old
        new.name = "Renamed"
        new.memorySizeInGB = new.memorySizeInGB.adding(gibibytes: 2)
        let classes = VMConfiguration.fieldClasses
        #expect(classes.refused(from: old, to: new, by: .edit(.rename)) == ["memorySizeInGB"])
        #expect(classes.refused(from: old, to: new, by: .edit([.rename, .machineKeys])) == [])
        #expect(classes.refused(from: old, to: new, by: .operation(.deletingSnapshot)) == [])
        #expect(classes.refused(from: old, to: old, by: .edit([])) == [])
        // A field no edit writes.
        var moved = old
        moved.id = UUID()
        #expect(classes.refused(from: old, to: moved, by: .edit(.all)) == ["id"])
    }

    @Test("The network fields' writers depend on what they move from and to")
    func networkFieldsAreClassifiedByValue() {
        var off = VMConfiguration(name: "VM", guestOS: .linux, bootMode: .efi)
        off.networkEnabled = false
        off.macAddress = nil
        var on = off
        on.applyNetworkMode(.shared)
        let classes = VMConfiguration.fieldClasses
        // Adding the device mints its address, both part of the swap.
        #expect(classes.refused(from: off, to: on, by: .edit(.networkAttachment)) == [])
        // Taking it away is hardware alone, and keeps the address.
        var removed = on
        removed.applyNetworkMode(nil)
        #expect(
            classes.refused(from: on, to: removed, by: .edit(.networkAttachment)) == ["networkEnabled"])
        #expect(classes.refused(from: on, to: removed, by: .edit(.machineKeys)) == [])
        // Replacing an address is not part of any swap.
        var readdressed = on
        readdressed.macAddress = "02:11:22:33:44:55"
        #expect(
            classes.refused(from: on, to: readdressed, by: .edit(.networkAttachment)) == ["macAddress"])
    }

    @Test("A membership edit writes the membership and no other network field")
    func membershipEditWritesMembershipAlone() {
        var common = VMConfiguration(name: "VM", guestOS: .linux, bootMode: .efi)
        common.applyNetworkMode(.shared)
        var isolated = common
        isolated.networkMembership = .isolated
        let classes = VMConfiguration.fieldClasses
        #expect(classes.refused(from: common, to: isolated, by: .edit(.networkMembership)) == [])
        var moved = isolated
        moved.networkMode = .hostOnly
        #expect(
            classes.refused(from: common, to: moved, by: .edit(.networkMembership)) == ["networkMode"])
        var readdressed = common
        readdressed.macAddress = "02:11:22:33:44:55"
        #expect(
            classes.refused(from: common, to: readdressed, by: .edit(.networkMembership))
                == ["macAddress"])
    }

    @Test("Clipboard sharing is hardware on a Linux guest and a live setting on a macOS one")
    func clipboardSharingIsClassifiedByGuest() {
        let classes = VMConfiguration.fieldClasses
        for (guestOS, bootMode) in [(VMGuestOS.linux, VMBootMode.efi), (.macOS, .macOS)] {
            let old = VMConfiguration(name: "VM", guestOS: guestOS, bootMode: bootMode)
            var new = old
            new.clipboardSharingEnabled.toggle()
            let live = classes.refused(from: old, to: new, by: .edit(.liveKeys))
            #expect(
                live == (guestOS == .linux ? ["clipboardSharingEnabled"] : []), "\(guestOS)")
            #expect(
                classes.refused(from: old, to: new, by: .edit(.machineKeys))
                    == (guestOS == .linux ? [] : ["clipboardSharingEnabled"]), "\(guestOS)")
        }
    }

    /// Values some key takes, or refuses, covering every key's spelling.
    private static let candidateValues = [
        "true", "false", "0", "1", "2", "4", "8", "16", "1280", "800",
        VMConfigurationKeyRegistry.noNetworkValue, "shared", "bridged", "hostOnly", "inline", "popOut",
        "fullscreen", "automatic", "mac", "usb", "never", "fullscreenOnly", "always", "en0", "",
        "02:11:22:33:44:55", "Baseline",
    ]

    @Test("Every key's permit may write every field its write moves")
    func everyKeysClassesWriteWhatItMoves() {
        let snapshot = VMSnapshot(name: "Baseline", macAddress: nil)
        let context = VMConfigurationWriteContext(
            snapshots: VMSnapshotManifest(snapshots: [snapshot]), entitlements: .entitled)
        var networked = VMConfiguration(name: "VM", guestOS: .macOS, bootMode: .macOS)
        networked.applyNetworkMode(.shared)
        var unaddressed = networked
        unaddressed.macAddress = nil
        var offline = VMConfiguration(name: "VM", guestOS: .linux, bootMode: .efi)
        offline.applyNetworkMode(nil)
        offline.macAddress = nil
        let hostStates = [
            VMHostState(),
            VMHostState(
                startsAutomaticallyOnLaunch: true, ephemeralModeEnabled: true,
                ephemeralBaselineSnapshotID: snapshot.id, displayPreference: .fullscreen,
                agentInstallNudgeDismissed: true),
        ]

        for key in VMConfigurationKeyRegistry.keys {
            for value in Self.candidateValues {
                switch key.field {
                case .configuration(let field):
                    for base in [networked, unaddressed, offline] where key.applies(base) {
                        let authority = VMEditPermit.Authority.edit(
                            key.editClasses(writing: value, for: base.guestOS))
                        var written = base
                        guard (try? field.write(value, &written, context)) != nil else { continue }
                        #expect(
                            VMConfiguration.fieldClasses.refused(
                                from: base, to: written, by: authority) == [],
                            "\(key.name)=\(value)")
                    }
                case .hostState(let field):
                    guard let change = try? field.change(value, context) else { continue }
                    let authority = VMEditPermit.Authority.edit(
                        key.editClasses(writing: value, for: .macOS))
                    for base in hostStates {
                        var written = base
                        change(&written)
                        #expect(
                            VMHostState.fieldClasses.refused(from: base, to: written, by: authority)
                                == [],
                            "\(key.name)=\(value)")
                    }
                }
            }
        }
    }

    /// The share verbs take their capability from a rule compiled into
    /// ``SharedDirectoryListEdit``; this pins it to the field classes, both
    /// ways, over every edit of a list of up to three shares.
    @Test("Every share-list edit's capability may write what it moves, and is live exactly when the move is a swap")
    func sharedDirectoryListEditsAgreeWithTheFieldClasses() throws {
        for guestOS in VMGuestOS.allCases {
            for live in [false, true] {
                for edit in SharedDirectoryListEdit.allCases {
                    for count in 0...3 {
                        let shares = (0..<count).map {
                            SharedDirectory(path: "/Users/Shared/share\($0)")
                        }
                        var old = VMConfiguration(
                            name: "VM", guestOS: guestOS,
                            bootMode: guestOS == .macOS ? .macOS : .efi)
                        old.sharedDirectories = shares.isEmpty ? nil : shares
                        var edited = shares
                        switch edit {
                        case .add:
                            edited.append(SharedDirectory(path: "/Users/Shared/added"))
                        case .remove:
                            guard !edited.isEmpty else { continue }
                            edited.removeLast()
                        case .change:
                            guard !edited.isEmpty else { continue }
                            edited[0].readOnly.toggle()
                        }
                        var new = old
                        new.sharedDirectories = edited.isEmpty ? nil : edited
                        let label = "\(guestOS) live=\(live) \(edit) of \(count)"

                        let capability = edit.capability(
                            onListOf: count, guestOS: guestOS, live: live)
                        let classes = try #require(capability.editClasses, "\(label)")
                        #expect(
                            VMConfiguration.fieldClasses.refused(
                                from: old, to: new, by: .edit(classes)) == [],
                            "\(label)")
                        guard live else { continue }
                        let swaps =
                            VMConfiguration.fieldClasses.refused(
                                from: old, to: new, by: .edit(.liveShares)) == []
                        #expect((capability == .editLiveSharedDirectories) == swaps, "\(label)")
                    }
                }
            }
        }
    }
}
