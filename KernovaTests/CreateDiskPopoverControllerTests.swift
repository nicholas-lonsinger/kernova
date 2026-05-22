import AppKit
import Foundation
import Testing
@testable import Kernova

/// Wire-up tests for ``CreateDiskPopoverController``: cancel + create
/// callbacks fire on the right buttons; create reports the popup-selected
/// size.
@Suite("CreateDiskPopoverController")
@MainActor
struct CreateDiskPopoverControllerTests {
    private func findButton(named title: String, in view: NSView) -> NSButton? {
        for sub in view.subviews {
            if let button = sub as? NSButton, button.title == title { return button }
            if let nested = findButton(named: title, in: sub) { return nested }
        }
        return nil
    }

    private func findPopUp(in view: NSView) -> NSPopUpButton? {
        for sub in view.subviews {
            if let popup = sub as? NSPopUpButton { return popup }
            if let nested = findPopUp(in: sub) { return nested }
        }
        return nil
    }

    @Test("Cancel button invokes onCancel")
    func cancelInvokesCallback() {
        var fired = false
        let vc = CreateDiskPopoverController(
            isRemovable: false,
            initialSize: VMGuestOS.defaultDiskSizeInGB,
            onCancel: { fired = true },
            onCreate: { _ in }
        )
        _ = vc.view
        findButton(named: "Cancel", in: vc.view)?.performClick(nil)
        #expect(fired == true)
    }

    @Test("Create button invokes onCreate with the initial size")
    func createInvokesWithInitialSize() {
        var observed: Int?
        let vc = CreateDiskPopoverController(
            isRemovable: false,
            initialSize: VMGuestOS.defaultDiskSizeInGB,
            onCancel: {},
            onCreate: { observed = $0 }
        )
        _ = vc.view
        findButton(named: "Create", in: vc.view)?.performClick(nil)
        #expect(observed == VMGuestOS.defaultDiskSizeInGB)
    }

    @Test("Changing the size popup updates the value reported by onCreate")
    func createReportsUpdatedSize() throws {
        var observed: Int?
        let vc = CreateDiskPopoverController(
            isRemovable: true,
            initialSize: VMGuestOS.defaultDiskSizeInGB,
            onCancel: {},
            onCreate: { observed = $0 }
        )
        _ = vc.view
        let popup = try #require(findPopUp(in: vc.view))
        // Find a size in the menu that differs from the initial selection.
        let differentSize = try #require(
            VMGuestOS.allDiskSizes.first(where: { $0 != VMGuestOS.defaultDiskSizeInGB }))
        let menuIndex = try #require(VMGuestOS.allDiskSizes.firstIndex(of: differentSize))
        popup.selectItem(at: menuIndex)
        // selectItem(at:) doesn't fire the popup's action — invoke it
        // explicitly so the controller records the new size.
        _ = popup.target?.perform(popup.action, with: popup)
        findButton(named: "Create", in: vc.view)?.performClick(nil)
        #expect(observed == differentSize)
    }

    @Test("Title reflects isRemovable flag")
    func titleReflectsIsRemovable() throws {
        let storage = CreateDiskPopoverController(
            isRemovable: false, initialSize: VMGuestOS.defaultDiskSizeInGB,
            onCancel: {}, onCreate: { _ in })
        _ = storage.view
        let removable = CreateDiskPopoverController(
            isRemovable: true, initialSize: VMGuestOS.defaultDiskSizeInGB,
            onCancel: {}, onCreate: { _ in })
        _ = removable.view

        // The headline NSTextField is the first label-style field in the
        // stack; locate it by string content rather than identifier.
        #expect(findLabel(matching: "Create New Disk", in: storage.view) != nil)
        #expect(findLabel(matching: "Create New Removable Disk", in: removable.view) != nil)
    }

    private func findLabel(matching text: String, in view: NSView) -> NSTextField? {
        for sub in view.subviews {
            if let field = sub as? NSTextField, field.stringValue == text { return field }
            if let nested = findLabel(matching: text, in: sub) { return nested }
        }
        return nil
    }
}
