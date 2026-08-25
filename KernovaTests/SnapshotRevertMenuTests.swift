import AppKit
import Testing

@testable import Kernova

@Suite("SnapshotRevertMenu Tests", .admissionGated)
@MainActor
struct SnapshotRevertMenuTests {
    /// Stands in for the menu's target; the action is never invoked here.
    private final class Target: NSObject {
        @objc func revert(_ sender: NSMenuItem) {}
    }

    private func makeInstance(status: VMStatus = .stopped) -> VMInstance {
        let config = VMConfiguration(name: "Revert VM", guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, status: status)
    }

    private func makeSnapshot(_ name: String, offsetSeconds: TimeInterval = 0) -> VMSnapshot {
        VMSnapshot(
            name: name, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + offsetSeconds))
    }

    private func rebuild(for instance: VMInstance?, isEnabled: Bool? = nil) -> NSMenu {
        let menu = NSMenu()
        SnapshotRevertMenu.rebuild(
            menu, for: instance, isEnabled: isEnabled ?? instance?.canRevertToSnapshot ?? false,
            target: Target(), action: #selector(Target.revert(_:)))
        return menu
    }

    @Test("No VM selected leaves a single disabled placeholder")
    func noInstanceShowsThePlaceholder() {
        let menu = rebuild(for: nil)
        #expect(menu.items.map(\.title) == [SnapshotRevertMenu.emptyTitle])
        #expect(menu.items.first?.isEnabled == false)
    }

    @Test("A VM with no snapshots shows the same placeholder")
    func noSnapshotsShowsThePlaceholder() {
        let menu = rebuild(for: makeInstance())
        #expect(menu.items.map(\.title) == [SnapshotRevertMenu.emptyTitle])
        #expect(menu.items.first?.isEnabled == false)
    }

    @Test("Items list the snapshots newest first")
    func itemsAreNewestFirst() {
        let instance = makeInstance()
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [
            makeSnapshot("Older"), makeSnapshot("Newer", offsetSeconds: 60),
        ])

        let menu = rebuild(for: instance)

        // Each item's rendered title is two lines, so it is matched by prefix.
        #expect(menu.items.count == 2)
        #expect(menu.items.first?.title.hasPrefix("Newer\u{2026}") == true)
        #expect(menu.items.last?.title.hasPrefix("Older\u{2026}") == true)
    }

    @Test("An item's rendered title carries the name and its capture date")
    func itemTitleCarriesNameAndDate() {
        let snapshot = makeSnapshot("Before the update")
        let rendered = SnapshotRevertMenu.itemTitle(for: snapshot).string
        #expect(rendered.hasPrefix("Before the update\u{2026}\n"))
        #expect(rendered.contains(SnapshotDateFormat.string(from: snapshot.createdAt)))
    }

    @Test("Each item names the VM and snapshot it would revert to")
    func itemsCarryTheirIdentity() {
        let instance = makeInstance()
        let snapshot = makeSnapshot("Only")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [snapshot])

        let ref = rebuild(for: instance).items.first?.representedObject as? SnapshotMenuRef

        #expect(ref?.instance === instance)
        #expect(ref?.snapshot == snapshot)
    }

    @Test("Items are disabled while the VM is mid-transition")
    func itemsDisabledWhileTransitioning() {
        let instance = makeInstance(status: .starting)
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [makeSnapshot("Only")])

        #expect(rebuild(for: instance).items.allSatisfy { !$0.isEnabled })
    }

    @Test("Items are enabled on a running VM, which the revert terminates")
    func itemsEnabledWhileRunning() {
        let instance = makeInstance(status: .running)
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [makeSnapshot("Only")])

        #expect(rebuild(for: instance).items.allSatisfy { $0.isEnabled })
    }

    @Test("The caller's gate decides, so a busy VM's items are disabled")
    func callerGateDisablesItems() {
        let instance = makeInstance(status: .running)
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [makeSnapshot("Only")])

        // `canRevertToSnapshot` alone reads `true` here: the VM is settled. The
        // menu still has to follow the caller, which folds in whether an
        // operation is unsettled.
        #expect(instance.canRevertToSnapshot)
        #expect(rebuild(for: instance, isEnabled: false).items.allSatisfy { !$0.isEnabled })
    }
}
