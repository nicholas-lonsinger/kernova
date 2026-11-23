import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

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
            over: VMConfiguration(
                name: "VM", guestOS: .macOS, bootMode: .macOS, cpuCount: VMGuestOS.macOS.hostCPUCount,
                memorySizeInGB: VMGuestOS.macOS.hostMemorySize))
        Self.expectExhaustive(VMHostState.fieldClasses, over: VMHostState())
        Self.expectExhaustive(VMSnapshotManifest.fieldClasses, over: VMSnapshotManifest())
        Self.expectExhaustive(USBAccessoryPairingSet.fieldClasses, over: USBAccessoryPairingSet())
    }

    /// Values some key takes, or refuses, covering every key's spelling.
    private static let candidateValues = [
        "true", "false", "0", "1", "2", "4", "8", "16", "1280", "800",
        VMConfigurationKeyRegistry.noNetworkValue, "nat", "bridged", "hostOnly", "inline", "popOut",
        "fullscreen", "automatic", "mac", "usb", "never", "fullscreenOnly", "always", "en0", "",
        "02:11:22:33:44:55", "Baseline",
    ]

    @Test("Every key's permit may write every field its write moves")
    func everyKeysClassesWriteWhatItMoves() {
        let snapshot = VMSnapshot(name: "Baseline", macAddress: nil)
        let context = VMConfigurationWriteContext(
            snapshots: VMSnapshotManifest(snapshots: [snapshot]), entitlements: .entitled, networks: .listed([]),
            resourceLimits: FakeVirtualizationHost.resourceLimits,
            agentInstallReminder: AgentInstallReminder(isOffForAllVMs: false))
        var networked = VMConfiguration(
            name: "VM", guestOS: .macOS, bootMode: .macOS, cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
        networked.applyNetworkMode(.nat)
        var unaddressed = networked
        unaddressed.macAddress = nil
        var offline = VMConfiguration(
            name: "VM", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
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
                            key.editClasses(writing: value))
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
                        key.editClasses(writing: value))
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
}
