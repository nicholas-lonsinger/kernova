import AppKit
import KernovaKit

/// One row of the status-item dropdown's VM section.
struct StatusMenuVMRow: Equatable {
    let instanceID: UUID
    let title: String
    /// The clipboard refusal line to show indented under the row, or `nil` when
    /// the VM has none outstanding.
    let noticeText: String?

    init(instanceID: UUID, title: String, noticeText: String? = nil) {
        self.instanceID = instanceID
        self.title = title
        self.noticeText = noticeText
    }
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
    /// The notice line under a row, keyed by VM id — present exactly for the rows
    /// whose model carries one.
    private var noticeItems: [UUID: NSMenuItem] = [:]
    /// The disabled placeholder, present exactly when `rowItems` is empty.
    private var placeholderItem: NSMenuItem?

    init(menu: NSMenu, rowTarget: AnyObject, rowAction: Selector) {
        self.menu = menu
        self.rowTarget = rowTarget
        self.rowAction = rowAction
    }

    /// The rows the section should show for `instances`, each carrying the
    /// clipboard refusal that VM's transfer report holds.
    ///
    /// The `isKeepingAppAlive` filter is what keeps a stopped VM off the
    /// dropdown, and with it that VM's report — the row is the only thing a
    /// notice line can hang under.
    static func rows(for instances: [VMInstance]) -> [StatusMenuVMRow] {
        instances.filter(\.isKeepingAppAlive).map { instance in
            StatusMenuVMRow(
                instanceID: instance.instanceID,
                title: "\(instance.name) — \(instance.statusDisplayName)",
                noticeText: Self.noticeText(for: instance))
        }
    }

    /// The compact refusal line under a VM's row, or `nil` when its report is
    /// running, idle, or a success.
    private static func noticeText(for instance: VMInstance) -> String? {
        guard case .finished(let finish) = instance.clipboardTransferReport else { return nil }
        return ClipboardTransferWording.wording(for: finish, vmName: instance.name)?.menuLine
    }

    /// Appends the section's items at the menu's current end, dropping any
    /// previously tracked items.
    func rebuild(rows: [StatusMenuVMRow]) {
        placeholderItem = nil
        noticeItems = [:]
        rowItems = rows.map(makeRowItem)
        guard !rowItems.isEmpty else {
            let placeholder = Self.makePlaceholderItem()
            menu.addItem(placeholder)
            placeholderItem = placeholder
            return
        }
        for (row, item) in zip(rows, rowItems) {
            menu.addItem(item)
            guard let noticeText = row.noticeText else { continue }
            let notice = Self.makeNoticeItem(noticeText)
            menu.addItem(notice)
            noticeItems[row.instanceID] = notice
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
        for (id, item) in noticeItems where !rows.contains(where: { $0.instanceID == id }) {
            menu.removeItem(item)
            noticeItems[id] = nil
        }
        if let placeholderItem, !rows.isEmpty {
            menu.removeItem(placeholderItem)
            self.placeholderItem = nil
        }

        var nextRowItems: [NSMenuItem] = []
        var target = start
        for row in rows {
            let item = surviving[row.instanceID] ?? makeRowItem(row)
            if item.title != row.title { item.title = row.title }
            place(item, at: target)
            target += 1
            nextRowItems.append(item)

            guard let noticeText = row.noticeText else {
                if let stale = noticeItems.removeValue(forKey: row.instanceID) {
                    menu.removeItem(stale)
                }
                continue
            }
            let notice = noticeItems[row.instanceID] ?? Self.makeNoticeItem(noticeText)
            if notice.title != noticeText { notice.title = noticeText }
            noticeItems[row.instanceID] = notice
            place(notice, at: target)
            target += 1
        }
        rowItems = nextRowItems

        if rowItems.isEmpty, placeholderItem == nil {
            let placeholder = Self.makePlaceholderItem()
            menu.insertItem(placeholder, at: start)
            placeholderItem = placeholder
        }
    }

    /// Puts `item` at `index`, inserting one the menu doesn't hold yet and moving
    /// one it holds elsewhere.
    ///
    /// Safe to call in ascending `index` order only: everything before `index` is
    /// already final, so the removal can only shift items the loop hasn't placed.
    private func place(_ item: NSMenuItem, at index: Int) {
        let current = menu.index(of: item)
        guard current != index else { return }
        if current >= 0 { menu.removeItem(item) }
        menu.insertItem(item, at: index)
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

    private static func makeNoticeItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem.statusMenuInfo(title: title)
        item.indentationLevel = 1
        return item
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
