import AppKit
import Foundation
import Testing
@testable import Kernova

/// Wire-up tests for ``AttachmentRowView``.
///
/// Verifies that toggling the "Read Only" `NSSwitch` and clicking the
/// trash button dispatch through the supplied closures with the correct
/// values.
@Suite("AttachmentRowView")
@MainActor
struct AttachmentRowViewTests {
    private func findSwitch(in view: NSView) -> NSSwitch? {
        for sub in view.subviews {
            if let toggle = sub as? NSSwitch { return toggle }
            if let nested = findSwitch(in: sub) { return nested }
        }
        return nil
    }

    private func findRemoveButton(in view: NSView) -> NSButton? {
        // The trash button is the only NSButton in the row; the toggle's
        // associated "Read Only" label is an NSTextField.
        for sub in view.subviews {
            if let button = sub as? NSButton { return button }
            if let nested = findRemoveButton(in: sub) { return nested }
        }
        return nil
    }

    private func makeRow(
        readOnly: Bool = false,
        isReadOnlyEnabled: Bool = true,
        isRemoveEnabled: Bool = true,
        onToggleReadOnly: @escaping (Bool) -> Void = { _ in },
        onRemove: @escaping () -> Void = {}
    ) -> AttachmentRowView {
        AttachmentRowView(
            icon: NSView(),
            title: "Demo Disk",
            subtitle: NSTextField(labelWithString: "/path"),
            readOnly: readOnly,
            isReadOnlyEnabled: isReadOnlyEnabled,
            isRemoveEnabled: isRemoveEnabled,
            onToggleReadOnly: onToggleReadOnly,
            onRemove: onRemove
        )
    }

    @Test("Toggle reflects initial readOnly state")
    func toggleReflectsInitialState() {
        let onRow = makeRow(readOnly: true)
        let offRow = makeRow(readOnly: false)
        #expect(findSwitch(in: onRow)?.state == .on)
        #expect(findSwitch(in: offRow)?.state == .off)
    }

    @Test("Toggling the switch invokes onToggleReadOnly with new state")
    func toggleDispatchesNewState() {
        var observed: Bool?
        let row = makeRow(readOnly: false) { newValue in
            observed = newValue
        }
        let toggle = findSwitch(in: row)
        // Initial state .off; performClick toggles to .on and fires action.
        toggle?.performClick(nil)
        #expect(observed == true)
        observed = nil
        // Click again toggles back to .off.
        toggle?.performClick(nil)
        #expect(observed == false)
    }

    @Test("Trash button click invokes onRemove")
    func removeDispatches() {
        var fired = false
        let row = makeRow(onRemove: { fired = true })
        let removeButton = findRemoveButton(in: row)
        removeButton?.performClick(nil)
        #expect(fired == true)
    }

    @Test("isReadOnlyEnabled = false disables the toggle")
    func toggleDisabledWhenLocked() {
        let row = makeRow(isReadOnlyEnabled: false)
        #expect(findSwitch(in: row)?.isEnabled == false)
    }

    @Test("isRemoveEnabled = false disables the trash button")
    func removeDisabledWhenLocked() {
        let row = makeRow(isRemoveEnabled: false)
        #expect(findRemoveButton(in: row)?.isEnabled == false)
    }
}
