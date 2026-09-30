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
        new.memorySizeInGB += 2
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

    @Test("A change's writers name each field it moved, with that field's classes, and nothing else")
    func writersNameEachMovedField() {
        let old = VMConfiguration(name: "VM", guestOS: .macOS, bootMode: .macOS)
        var new = old
        new.name = "Renamed"
        new.memorySizeInGB += 2
        new.displayAutoResizes.toggle()
        let writers = VMConfiguration.fieldClasses.writers(from: old, to: new)
        #expect(writers.map(\.name) == ["name", "memorySizeInGB", "displayAutoResizes"])
        #expect(writers.map(\.classes) == [.rename, .machineKeys, .liveKeys])
        #expect(VMConfiguration.fieldClasses.writers(from: old, to: old).isEmpty)
    }
}
