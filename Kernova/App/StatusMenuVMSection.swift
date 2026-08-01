import AppKit

/// One row of the status-item dropdown's VM section.
struct StatusMenuVMRow: Equatable {
    let instanceID: UUID
    let title: String
}

/// Owns the VM section of the status-item dropdown: one row per VM keeping the
/// app alive, or a disabled placeholder when none is.
///
/// `menuNeedsUpdate` re-populates the section with ``rebuild(rows:)`` while the
/// dropdown is rebuilt from scratch; state changes while it is on screen go
/// through ``sync(to:)``, which edits the open menu in place — retitling,
/// inserting, and removing individual items — so rows never vanish and reappear
/// under the cursor.
@MainActor
final class StatusMenuVMSection {
    private let menu: NSMenu
    private weak var rowTarget: AnyObject?
    private let rowAction: Selector

    /// Live row items in display order; each `representedObject` is the VM's id.
    private var rowItems: [NSMenuItem] = []
    /// The disabled placeholder, present exactly when `rowItems` is empty.
    private var placeholderItem: NSMenuItem?

    init(menu: NSMenu, rowTarget: AnyObject, rowAction: Selector) {
        self.menu = menu
        self.rowTarget = rowTarget
        self.rowAction = rowAction
    }

    /// The rows the section should show for `instances`.
    static func rows(for instances: [VMInstance]) -> [StatusMenuVMRow] {
        instances.filter(\.isKeepingAppAlive).map {
            StatusMenuVMRow(
                instanceID: $0.instanceID, title: "\($0.name) — \($0.statusDisplayName)")
        }
    }

    /// Appends the section's items at the menu's current end, dropping any
    /// previously tracked items.
    func rebuild(rows: [StatusMenuVMRow]) {
        placeholderItem = nil
        rowItems = rows.map(makeRowItem)
        if rowItems.isEmpty {
            let placeholder = Self.makePlaceholderItem()
            menu.addItem(placeholder)
            placeholderItem = placeholder
        } else {
            for item in rowItems { menu.addItem(item) }
        }
    }

    /// Edits the section in place to match `rows`.
    ///
    /// A no-op until ``rebuild(rows:)`` has put the section's items in the menu:
    /// the section locates itself by its own items, so it has no anchor before
    /// then (or after `removeAllItems()` clears a closed menu for rebuild).
    func sync(to rows: [StatusMenuVMRow]) {
        guard let start = sectionStart() else { return }

        var surviving: [UUID: NSMenuItem] = [:]
        for item in rowItems {
            guard let id = item.representedObject as? UUID else { continue }
            if rows.contains(where: { $0.instanceID == id }) {
                surviving[id] = item
            } else {
                menu.removeItem(item)
            }
        }
        if let placeholderItem, !rows.isEmpty {
            menu.removeItem(placeholderItem)
            self.placeholderItem = nil
        }

        rowItems = rows.enumerated().map { offset, row in
            let target = start + offset
            guard let existing = surviving[row.instanceID] else {
                let item = makeRowItem(row)
                menu.insertItem(item, at: target)
                return item
            }
            if existing.title != row.title { existing.title = row.title }
            if menu.index(of: existing) != target {
                menu.removeItem(existing)
                menu.insertItem(existing, at: target)
            }
            return existing
        }

        if rowItems.isEmpty, placeholderItem == nil {
            let placeholder = Self.makePlaceholderItem()
            menu.insertItem(placeholder, at: start)
            placeholderItem = placeholder
        }
    }

    /// The index the section's first item occupies, or `nil` when none of its
    /// items are in the menu.
    private func sectionStart() -> Int? {
        guard let first = placeholderItem ?? rowItems.first else { return nil }
        let index = menu.index(of: first)
        return index >= 0 ? index : nil
    }

    private func makeRowItem(_ row: StatusMenuVMRow) -> NSMenuItem {
        let item = NSMenuItem(title: row.title, action: rowAction, keyEquivalent: "")
        item.target = rowTarget
        item.representedObject = row.instanceID
        return item
    }

    private static func makePlaceholderItem() -> NSMenuItem {
        .statusMenuInfo(title: "No virtual machines running")
    }
}

extension NSMenuItem {
    /// A disabled informational row for the status-item dropdown.
    static func statusMenuInfo(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
