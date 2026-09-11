import AppKit
import KernovaKit

/// Identifies which VM and accessory a USB Device item names, carried as the
/// item's `representedObject`.
///
/// `deviceID` is the attachment's UUID when the item detaches a device the
/// guest holds, and `nil` when it attaches one the guest does not.
@MainActor
final class USBAccessoryMenuRef: NSObject {
    let instance: VMInstance
    let registryID: UInt64
    let deviceID: UUID?

    init(instance: VMInstance, registryID: UInt64, deviceID: UUID?) {
        self.instance = instance
        self.registryID = registryID
        self.deviceID = deviceID
    }
}

/// The "USB Device" submenu: the accessories this guest holds, then the ones
/// available to attach.
///
/// The list is only ever what macOS assigned to Kernova, so nothing here can
/// offer a device Kernova cannot actually reach.
@MainActor
enum USBAccessoryMenu {
    static let title = "USB Device"

    /// Shown in place of the list when there is nothing on either side, so the
    /// submenu is never empty and its parent reads as unavailable rather than
    /// broken.
    static let emptyTitle = "No USB Accessories"

    /// Fills `menu` with one item per attached accessory, then one per
    /// available accessory.
    ///
    /// `isEnabled` is the caller's edit gate, so an attach is never offered on a
    /// VM that could not take one. A `nil` `target` leaves the items nil-target,
    /// dispatching the actions down the responder chain.
    static func rebuild(
        _ menu: NSMenu, for instance: VMInstance?, attached: [USBAccessorySummary],
        available: [USBAccessorySummary],
        isEnabled: Bool, target: AnyObject?, attachAction: Selector, detachAction: Selector
    ) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        guard let instance, !attached.isEmpty || !available.isEmpty else {
            let empty = NSMenuItem(title: emptyTitle, action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        for item in attached {
            let menuItem = NSMenuItem(
                title: item.name, action: detachAction, keyEquivalent: "")
            menuItem.target = target
            menuItem.representedObject = USBAccessoryMenuRef(
                instance: instance, registryID: item.registryID, deviceID: item.deviceID)
            // A checkmark is what says "in this guest" without a second column
            // of copy, and detaching is what clicking a checked row does.
            menuItem.state = .on
            menuItem.isEnabled = isEnabled
            menu.addItem(menuItem)
        }

        if !attached.isEmpty && !available.isEmpty {
            menu.addItem(.separator())
        }

        for accessory in available {
            let menuItem = NSMenuItem(
                title: accessory.name, action: attachAction, keyEquivalent: "")
            menuItem.target = target
            menuItem.representedObject = USBAccessoryMenuRef(
                instance: instance, registryID: accessory.registryID, deviceID: nil)
            menuItem.state = .off
            menuItem.isEnabled = isEnabled
            menu.addItem(menuItem)
        }
    }
}
