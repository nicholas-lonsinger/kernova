import AppKit

/// Identifies which VM and snapshot a "Revert to Snapshot" item names, carried
/// as the item's `representedObject`.
@MainActor
final class SnapshotMenuRef: NSObject {
    let instance: VMInstance
    let snapshot: VMSnapshot

    init(instance: VMInstance, snapshot: VMSnapshot) {
        self.instance = instance
        self.snapshot = snapshot
    }
}

/// The "Revert to Snapshot" submenu, shared by the Virtual Machine menu and the
/// sidebar's context menu.
@MainActor
enum SnapshotRevertMenu {
    static let title = "Revert to Snapshot"

    /// Shown in place of the list when the VM has no snapshots, so the submenu
    /// is never empty and its parent reads as unavailable rather than broken.
    static let emptyTitle = "No Snapshots"

    /// Fills `menu` with one item per snapshot, newest first.
    ///
    /// Each item's title carries the trailing ellipsis of a command that opens a
    /// confirmation, over the capture date in secondary type. `isEnabled` is the
    /// caller's revert gate — the same one the settings pane's Revert buttons
    /// take, so a revert is never offered where it would only error.
    static func rebuild(
        _ menu: NSMenu, for instance: VMInstance?, isEnabled: Bool, target: AnyObject,
        action: Selector
    ) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let snapshots = instance?.snapshotManifest.ordered ?? []
        guard let instance, !snapshots.isEmpty else {
            let empty = NSMenuItem(title: emptyTitle, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        let enabled = isEnabled
        for snapshot in snapshots {
            let item = NSMenuItem(title: snapshot.name, action: action, keyEquivalent: "")
            item.attributedTitle = itemTitle(for: snapshot)
            item.target = target
            item.representedObject = SnapshotMenuRef(instance: instance, snapshot: snapshot)
            item.isEnabled = enabled
            menu.addItem(item)
        }
    }

    /// Two lines: the snapshot's name, then its capture date in secondary type.
    static func itemTitle(for snapshot: VMSnapshot) -> NSAttributedString {
        let title = NSMutableAttributedString(
            string: "\(snapshot.name)\u{2026}\n",
            attributes: [.font: NSFont.menuFont(ofSize: 0)])
        title.append(
            NSAttributedString(
                string: SnapshotDateFormat.string(from: snapshot.createdAt),
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
        return title
    }
}
