import AppKit

/// Owns one status-item dropdown line reporting a count of alerts held for
/// want of a window — present exactly while the count is non-zero — whose
/// action opens the library, so each alert is shown.
///
/// `menuNeedsUpdate` re-populates it with ``rebuild(count:)`` while the dropdown
/// is rebuilt from scratch; a count that changes while it is on screen goes
/// through ``sync(to:after:)``, which edits the open menu in place so the line
/// appears under the cursor without the menu collapsing around it.
@MainActor
final class StatusMenuCountLine {
    private let menu: NSMenu
    private weak var target: AnyObject?
    private let action: Selector
    private let title: (Int) -> String?

    /// The line while the menu holds it — absent exactly when nothing is waiting.
    private(set) var item: NSMenuItem?

    /// `title` words the line for a count, or answers `nil` for none.
    init(menu: NSMenu, target: AnyObject, action: Selector, title: @escaping (Int) -> String?) {
        self.menu = menu
        self.target = target
        self.action = action
        self.title = title
    }

    /// The undone-start line's title for `count` VMs that did not start, or
    /// `nil` when there are none.
    ///
    /// Ellipsis-terminated: the click opens a window that raises an alert.
    nonisolated static func undoneStartTitle(count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 VM Didn\u{2019}t Start…"
        default: "\(count) VMs Didn\u{2019}t Start…"
        }
    }

    /// The waiting-alert line's title for `count` other held alerts, or `nil`
    /// when there are none.
    nonisolated static func waitingAlertTitle(count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 Alert Waiting…"
        default: "\(count) Alerts Waiting…"
        }
    }

    /// Appends the line at the menu's current end, dropping any previously
    /// tracked item.
    func rebuild(count: Int) {
        item = nil
        guard let title = title(count) else { return }
        let line = makeItem(title)
        menu.addItem(line)
        item = line
    }

    /// Edits the line in place to match `count`, inserting it directly below
    /// `anchor` when it first appears.
    ///
    /// `anchor` is what gives an absent line somewhere to land: it holds no slot
    /// of its own while there is nothing to report, so it cannot locate itself
    /// the way a section with a placeholder can.
    func sync(to count: Int, after anchor: NSMenuItem) {
        guard let title = title(count) else {
            if let item, menu.index(of: item) >= 0 { menu.removeItem(item) }
            item = nil
            return
        }
        if let item {
            if item.title != title { item.title = title }
            return
        }
        let anchorIndex = menu.index(of: anchor)
        guard anchorIndex >= 0 else { return }
        let line = makeItem(title)
        menu.insertItem(line, at: anchorIndex + 1)
        item = line
    }

    private func makeItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }
}
