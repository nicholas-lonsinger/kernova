import AppKit
import Testing

@testable import Kernova

/// The shared inline-edit state machine every editable name and note runs on.
@Suite("Inline Editable Label Tests", .serialized, .admissionGated)
@MainActor
struct InlineEditableLabelTests {
    private func makeLabel(
        text: String = "Original", controlsEnabled: Bool = true,
        clickHandling: InlineEditableLabel.ClickHandling = .owned
    ) -> InlineEditableLabel {
        InlineEditableLabel(
            text: text, font: Typography.body, textColor: .labelColor, placeholder: "Name",
            controlsEnabled: controlsEnabled, clickHandling: clickHandling)
    }

    /// Puts `labels` in a window, left to right, the way a row lays them out.
    ///
    /// Keep the returned window alive for the length of the test: an editing
    /// label's first responder lives on it.
    private func host(_ labels: [InlineEditableLabel]) -> NSWindow {
        let window = makeTestWindow(styleMask: [.titled])
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        var previous: NSLayoutXAxisAnchor = container.leadingAnchor
        for label in labels {
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: previous),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            previous = label.trailingAnchor
        }
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        return window
    }

    /// Sends the field editor's cancel command, the way Escape reaches a label.
    private func escape(_ label: InlineEditableLabel) {
        _ = label.control(
            NSControl(), textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
    }

    /// Types `text` into a live edit, mirroring what the field editor holds and
    /// what a resign would validate back into the field.
    private func type(_ text: String, into label: InlineEditableLabel) {
        label.currentEditor()?.string = text
        label.stringValue = text
    }

    /// A name two editing surfaces share, so a commit on one is visible to the
    /// other's ``InlineEditableLabel/currentText``.
    @MainActor
    private final class SharedName {
        var value: String
        init(_ value: String) { self.value = value }
    }

    // MARK: - Handoff re-seed

    /// The cross-surface handoff: arming the second surface resigns the first,
    /// which commits its typed text synchronously — so the seed the second one
    /// opened with is already stale by the time the user can type into it.
    @Test("Taking focus re-seeds the box from the authoritative text")
    func reseedsFromCurrentTextAfterTakingFocus() {
        let name = SharedName("Original")
        let first = makeLabel(text: name.value)
        first.onEditCommitted = { text, _ in name.value = text }
        let second = makeLabel(text: name.value)
        second.currentText = { name.value }
        let window = host([first, second])
        defer { window.close() }

        first.beginEditing()
        type("Handed off", into: first)
        second.beginEditing()

        // The first surface committed as focus moved, and the second picked the
        // new name up rather than showing the name it was built with.
        #expect(name.value == "Handed off")
        #expect(second.stringValue == "Handed off")
        #expect(second.currentEditor()?.string == "Handed off")

        // Escape reverts to the handed-off name, not to the stale seed.
        type("Half-typed", into: second)
        escape(second)
        #expect(second.stringValue == "Handed off")
    }

    @Test("A label with no current-text source keeps the text it opened with")
    func withoutCurrentTextTheSeedStands() {
        let label = makeLabel(text: "Original")
        let window = host([label])
        defer { window.close() }

        label.beginEditing()

        #expect(label.stringValue == "Original")
        #expect(label.currentEditor()?.string == "Original")
    }

    // MARK: - Ending an edit

    @Test("endEditing commits the in-flight text exactly once")
    func endEditingCommitsOnce() {
        var commits: [String] = []
        let label = makeLabel()
        label.onEditCommitted = { text, _ in commits.append(text) }
        let window = host([label])
        defer { window.close() }

        label.beginEditing()
        type("Typed", into: label)
        label.endEditing()
        label.endEditing()

        #expect(commits == ["Typed"])
        #expect(!label.isEditing)
        #expect(!label.isEditable)
    }

    @Test("endEditing on a label that is not editing fires nothing")
    func endEditingIdleFiresNothing() {
        var commits = 0
        var cancels = 0
        let label = makeLabel()
        label.onEditCommitted = { _, _ in commits += 1 }
        label.onEditCancelled = { cancels += 1 }
        let window = host([label])
        defer { window.close() }

        label.endEditing()

        #expect(commits == 0)
        #expect(cancels == 0)
        #expect(!label.isEditing)
    }

    /// A recycled row's typed text belongs to a VM the cell no longer shows, so
    /// tearing the edit down must not commit it.
    @Test("abandonEditing drops the text silently and restores the display state")
    func abandonEditingFiresNothing() {
        var commits = 0
        var cancels = 0
        let label = makeLabel(text: "Original")
        label.onEditCommitted = { _, _ in commits += 1 }
        label.onEditCancelled = { cancels += 1 }
        let window = host([label])
        defer { window.close() }

        label.beginEditing()
        type("Half-typed", into: label)
        label.abandonEditing()

        #expect(commits == 0)
        #expect(cancels == 0)
        #expect(!label.isEditing)
        #expect(!label.isEditable)
        #expect(!label.isBezeled)
        #expect(label.stringValue == "Original")
    }

    @Test("Escape reverts the text and reports the cancel")
    func escapeCancels() {
        var commits = 0
        var cancels = 0
        let label = makeLabel(text: "Original")
        label.onEditCommitted = { _, _ in commits += 1 }
        label.onEditCancelled = { cancels += 1 }
        let window = host([label])
        defer { window.close() }

        label.beginEditing()
        type("Half-typed", into: label)
        escape(label)

        #expect(commits == 0)
        #expect(cancels == 1)
        #expect(label.stringValue == "Original")
        #expect(!label.isEditing)
    }

    // MARK: - Editing armed before the label has a window

    /// A sidebar cell is configured — and its rename armed — during
    /// `reloadData`, before the cell joins the outline view's window.
    @Test("An edit armed off-window takes focus once the label joins one")
    func armedBeforeWindowTakesFocusOnJoin() {
        let label = makeLabel(text: "Original")
        label.beginEditing()

        #expect(label.isEditing)
        #expect(label.isEditable)
        #expect(label.currentEditor() == nil)

        let window = host([label])
        defer { window.close() }

        #expect(label.currentEditor() != nil)
        #expect(label.isEditing)
    }

    @Test("A label whose edit is armed off-window still re-seeds when it joins one")
    func armedBeforeWindowReseedsOnJoin() {
        let name = SharedName("Original")
        let label = makeLabel(text: name.value)
        label.currentText = { name.value }
        label.beginEditing()
        name.value = "Renamed elsewhere"

        let window = host([label])
        defer { window.close() }

        #expect(label.stringValue == "Renamed elsewhere")
        #expect(label.currentEditor()?.string == "Renamed elsewhere")
    }

    // MARK: - Click ownership

    @Test("A label that owns its clicks arms a click recognizer")
    func ownedClickHandlingInstallsARecognizer() {
        let label = makeLabel()
        #expect(label.gestureRecognizers.contains { $0 is NSClickGestureRecognizer })
    }

    /// The sidebar's clicks belong to the enclosing outline view, which does its
    /// own selection and drag tracking.
    @Test("A label that delegates its clicks installs no recognizer")
    func delegatedClickHandlingInstallsNoRecognizer() {
        let label = makeLabel(clickHandling: .delegatedToEnclosingView)
        #expect(label.gestureRecognizers.isEmpty)
    }

    // MARK: - Arming gate

    @Test("A label whose controls are disabled refuses to begin editing")
    func disabledControlsRefuseToEdit() {
        let label = makeLabel(controlsEnabled: false)
        let window = host([label])
        defer { window.close() }

        label.beginEditing()

        #expect(!label.isEditing)
        #expect(!label.isEditable)
    }
}
