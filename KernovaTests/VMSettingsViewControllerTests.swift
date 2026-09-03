import AVFoundation
import AppKit
import Testing
import Virtualization

@testable import Kernova

@Suite("VMSettingsViewController Tests", .serialized, .admissionGated)
@MainActor
struct VMSettingsViewControllerTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    ///
    /// Selection/order persistence never touches the real `.standard` domain.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.vmsettings")

    private func makeController(
        guestOS: VMGuestOS, isReadOnly: Bool, category: VMSettingsCategory? = nil
    ) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
        makeSettingsController(
            guestOS: guestOS, isReadOnly: isReadOnly, category: category,
            preferences: preferences)
    }

    // MARK: - Column and identity header

    @Test("A wide detail pane holds the form at the capped column width")
    func formTakesTheCappedColumn() throws {
        let (vc, _, _) = makeController(guestOS: .macOS, isReadOnly: false)
        vc.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        vc.view.layoutSubtreeIfNeeded()

        let scrollView = try #require(firstSubview(NSScrollView.self, in: vc.view))
        let form = try #require(scrollView.documentView?.subviews.first)
        #expect(form.frame.width == GroupedFormStyle.columnWidth)
        // The pinned header takes its own height and the form scrolls under it.
        #expect(scrollView.frame.height > 0)
        #expect(scrollView.frame.height < vc.view.frame.height)
    }

    @Test("The identity header leads the form, naming the VM")
    func identityHeaderLeadsTheForm() throws {
        let (vc, instance, _) = makeController(guestOS: .macOS, isReadOnly: false)

        let header = try #require(firstSubview(VMIdentityHeaderView.self, in: vc.view))
        #expect(findLabel(withText: instance.name, in: header) != nil)
    }

    // MARK: - Read-only lock behavior

    @Test("Read-only disables lockable controls but not hot-toggleable ones")
    func readOnlyDisablesLockableControls() {
        let (network, _, _) = makeController(guestOS: .macOS, isReadOnly: true, category: .network)
        // The network Mode picker is lockable → disabled while read-only.
        #expect(settingsNetworkModePopUp(in: network.view)?.isEnabled == false)

        let (sharing, _, _) = makeController(guestOS: .macOS, isReadOnly: true, category: .sharing)
        // Clipboard is hot-toggleable → stays enabled.
        #expect(firstSwitch(action: "clipboardToggled", in: sharing.view)?.isEnabled == true)
    }

    @Test("Lockable controls are enabled when editable")
    func editableEnablesLockableControls() {
        let (vc, _, _) = makeController(guestOS: .macOS, isReadOnly: false, category: .network)
        #expect(settingsNetworkModePopUp(in: vc.view)?.isEnabled == true)
    }

    @Test("Section lock hints are visible only while read-only")
    func lockHintVisibilityTracksReadOnly() throws {
        let (readOnlyVC, _, _) = makeController(guestOS: .macOS, isReadOnly: true, category: .system)
        let readOnlyPanel = try #require(readOnlyVC.panelForTesting(.system))
        let shown = settingsLockHints(in: readOnlyPanel)
        #expect(!shown.isEmpty)
        #expect(shown.allSatisfy { !$0.isHidden })

        let (editableVC, _, _) = makeController(guestOS: .macOS, isReadOnly: false, category: .system)
        let editablePanel = try #require(editableVC.panelForTesting(.system))
        let hidden = settingsLockHints(in: editablePanel)
        #expect(!hidden.isEmpty)
        #expect(hidden.allSatisfy { $0.isHidden })
    }

    @Test("No page-level lock banner in either state")
    func noLockBannerInEitherState() {
        for isReadOnly in [true, false] {
            let (vc, _, _) = makeController(guestOS: .macOS, isReadOnly: isReadOnly)
            #expect(
                findLabel(
                    containing: "locked while the VM is running", in: vc.view) == nil)
        }
    }

    @Test("A locked row dims while read-only and is undimmed when editable")
    func lockedRowDimsWhileReadOnly() throws {
        let (readOnlyVC, _, _) = makeController(guestOS: .macOS, isReadOnly: true, category: .system)
        let readOnlyPanel = try #require(readOnlyVC.panelForTesting(.system))
        let locked = try #require(settingsRow(labeled: "CPU cores", in: readOnlyPanel))
        #expect(locked.alphaValue == Alpha.disabled)

        let (editableVC, _, _) = makeController(guestOS: .macOS, isReadOnly: false, category: .system)
        let editablePanel = try #require(editableVC.panelForTesting(.system))
        let editable = try #require(settingsRow(labeled: "CPU cores", in: editablePanel))
        #expect(editable.alphaValue == 1)
    }

    @Test("The auto-resize row stays undimmed inside a locked Display card")
    func hotToggleableRowStaysUndimmed() throws {
        for isReadOnly in [true, false] {
            let (vc, _, _) = makeController(guestOS: .macOS, isReadOnly: isReadOnly, category: .system)
            let panel = try #require(vc.panelForTesting(.system))
            let autoResize = try #require(
                settingsRow(labeled: "Automatically resize with window", in: panel))
            #expect(autoResize.alphaValue == 1)
        }
    }

    // MARK: - Config write-back

    @Test("Toggling Clipboard Sharing writes back to the configuration")
    func clipboardToggleWritesConfig() {
        let (vc, instance, _) = makeController(
            guestOS: .linux, isReadOnly: false, category: .sharing)
        #expect(instance.configuration.clipboardSharingEnabled == false)

        guard let clipboard = firstSwitch(action: "clipboardToggled", in: vc.view) else {
            Issue.record("Expected a clipboard switch")
            return
        }
        clipboard.state = .on
        clipboard.sendAction(clipboard.action, to: clipboard.target)

        #expect(instance.configuration.clipboardSharingEnabled == true)
    }
}
