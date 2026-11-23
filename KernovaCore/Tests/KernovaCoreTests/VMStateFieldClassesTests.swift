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
