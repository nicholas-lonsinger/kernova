import AppKit
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

@Suite("SnapshotRevertMenu Tests", .caseScoped)
@MainActor
struct SnapshotRevertMenuTests {
    /// Stands in for the menu's target; the action is never invoked here.
    private final class Target: NSObject {
        @objc func revert(_: NSMenuItem) {}
    }

    private func makeInstance(phase: VMLifecyclePhase = .stopped) -> VMInstance {
        VMInstanceFixture.make(name: "Revert VM", phase: phase)
    }

    private func makeSnapshot(_ name: String, offsetSeconds: TimeInterval = 0) -> VMSnapshot {
        VMSnapshot(
            name: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + offsetSeconds), macAddress: nil)
    }

    /// Whether the VM's own state admits a revert right now.
    private func admitsRevert(_ instance: VMInstance) -> Bool {
        instance.activity.admits(
            .operation(.bringUp(.reverting(snapshotID: UUID(), resumesAfter: false))))
    }

    private func rebuild(for instance: VMInstance?, isEnabled: Bool? = nil) -> NSMenu {
        let menu = NSMenu()
        SnapshotRevertMenu.rebuild(
            menu, for: instance, isEnabled: isEnabled ?? instance.map(admitsRevert) ?? false,
            target: Target(), action: #selector(Target.revert(_:)))
        return menu
    }

    @Test("Each item names the VM and snapshot it would revert to")
    func itemsCarryTheirIdentity() {
        let instance = makeInstance()
        let snapshot = makeSnapshot("Only")
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))

        let ref = rebuild(for: instance).items.first?.representedObject as? SnapshotMenuRef

        #expect(ref?.instance === instance)
        #expect(ref?.snapshot == snapshot)
    }
}
