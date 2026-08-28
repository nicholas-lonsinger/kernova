import AVFoundation
import AppKit
import Testing
import Virtualization

@testable import Kernova

/// The System panel's own behavior, drilled into through the shell.
@Suite("VM Settings System Panel Tests", .serialized, .admissionGated)
@MainActor
struct VMSettingsSystemPanelTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    ///
    /// Selection/order persistence never touches the real `.standard` domain.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.vmsettings.system")

    private func makeViewModel() -> VMLibraryViewModel {
        makeSettingsViewModel(preferences: preferences)
    }

    private func makeInstance(guestOS: VMGuestOS) -> VMInstance {
        makeSettingsInstance(guestOS: guestOS)
    }

    private func makeController(
        guestOS: VMGuestOS, isReadOnly: Bool, category: VMSettingsCategory? = nil
    ) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
        makeSettingsController(
            guestOS: guestOS, isReadOnly: isReadOnly, category: category,
            preferences: preferences)
    }

    // MARK: - Display section

    /// Builds a controller over a config with explicit display settings.
    ///
    /// `hiDPI` defaults to the intent matching `ppi` — the self-consistent
    /// pairing manual mode maintains. Pass it to model a match-mode config whose
    /// stored trio is a previous boot's artifact.
    private func makeDisplayController(
        guestOS: VMGuestOS = .macOS,
        isReadOnly: Bool = false,
        sizesToWindow: Bool = false,
        width: Int = 1920,
        height: Int = 1200,
        ppi: Int = 144,
        hiDPI: Bool? = nil
    ) -> (VMSettingsViewController, VMInstance) {
        let viewModel = makeViewModel()
        let config = VMConfiguration(
            name: "Test VM", guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi,
            displayWidth: width, displayHeight: height, displayPPI: ppi,
            displaySizesToWindow: sizesToWindow,
            displayHiDPI: hiDPI ?? DisplayBootSizing.isHiDPI(ppi: ppi))
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL)
        let vc = VMSettingsViewController(
            instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.system)
        return (vc, instance)
    }

    @Test("The Display section is present for both guest OSes")
    func displaySectionPresentForBothOSes() {
        for guestOS in [VMGuestOS.macOS, .linux] {
            let (vc, _) = makeDisplayController(guestOS: guestOS)
            #expect(containsLabel("Display", in: vc.view))
            #expect(containsLabel("Size display to fit window at startup", in: vc.view))
            #expect(containsLabel("Resolution", in: vc.view))
            #expect(firstPopUp(action: "displayResolutionChanged", in: vc.view) != nil)
        }
    }

    @Test("The HiDPI row is macOS-only, the auto-resize row is not")
    func hiDPIIsMacOSOnlyButAutoResizeIsNot() {
        let (macVC, _) = makeDisplayController(guestOS: .macOS)
        #expect(containsLabel("HiDPI (Retina)", in: macVC.view))
        #expect(containsLabel("Automatically resize with window", in: macVC.view))

        // Linux gets no HiDPI row — virtio scanouts carry no density.
        let (linuxVC, _) = makeDisplayController(guestOS: .linux)
        #expect(!containsLabel("HiDPI (Retina)", in: linuxVC.view))
        #expect(containsLabel("Automatically resize with window", in: linuxVC.view))
    }

    @Test("Match-window writes the flag and disables the manual controls")
    func matchWindowToggleWritesAndDisables() {
        let (vc, instance) = makeDisplayController()
        guard let match = firstSwitch(action: "displayMatchWindowToggled", in: vc.view),
            let popUp = firstPopUp(action: "displayResolutionChanged", in: vc.view)
        else {
            Issue.record("Expected the match-window switch and the resolution popup")
            return
        }
        #expect(popUp.isEnabled)

        match.state = .on
        match.sendAction(match.action, to: match.target)

        #expect(instance.configuration.displaySizesToWindow == true)
        #expect(!popUp.isEnabled)
        #expect(editableField("Width", in: vc.view)?.isEnabled == false)
        // Neither HiDPI nor auto-resize is a size control, so match mode leaves
        // both usable.
        #expect(firstSwitch(action: "displayHiDPIToggled", in: vc.view)?.isEnabled == true)
        #expect(firstSwitch(action: "displayAutoResizeToggled", in: vc.view)?.isEnabled == true)
    }

    @Test("A VM already in match-window mode builds with the size controls disabled")
    func matchWindowOnDisablesFromBuild() {
        let (vc, _) = makeDisplayController(sizesToWindow: true)

        #expect(firstPopUp(action: "displayResolutionChanged", in: vc.view)?.isEnabled == false)
        #expect(editableField("Width", in: vc.view)?.isEnabled == false)
        #expect(editableField("Height", in: vc.view)?.isEnabled == false)
        // HiDPI picks the scale the computed size is measured at, so it stays
        // usable — as does the mode switch, so the user can turn match off.
        #expect(firstSwitch(action: "displayHiDPIToggled", in: vc.view)?.isEnabled == true)
        #expect(firstSwitch(action: "displayMatchWindowToggled", in: vc.view)?.isEnabled == true)
    }

    @Test("Choosing a preset writes it and fills the size fields")
    func presetWritesResolution() {
        let (vc, instance) = makeDisplayController()
        guard let popUp = firstPopUp(action: "displayResolutionChanged", in: vc.view) else {
            Issue.record("Expected the resolution popup")
            return
        }
        popUp.selectItem(withTitle: "1440 × 900")
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.configuration.displayWidth == 1440)
        #expect(instance.configuration.displayHeight == 900)
        #expect(editableField("Width", in: vc.view)?.integerValue == 1440)
        #expect(editableField("Height", in: vc.view)?.integerValue == 900)
    }

    @Test("A typed size below the floor clamps and flips the popup to Custom")
    func typedSizeClampsAndSelectsCustom() {
        let (vc, instance) = makeDisplayController()
        guard let width = editableField("Width", in: vc.view),
            let height = editableField("Height", in: vc.view),
            let popUp = firstPopUp(action: "displayResolutionChanged", in: vc.view)
        else {
            Issue.record("Expected the width, height, and resolution controls")
            return
        }
        width.integerValue = 640
        height.integerValue = 401
        commitEdit(width)

        #expect(instance.configuration.displayWidth == 800)
        #expect(instance.configuration.displayHeight == 600)
        #expect(popUp.titleOfSelectedItem == "Custom")
    }

    @Test("In manual mode HiDPI rewrites the stored trio in both directions")
    func hiDPIRewritesResolution() {
        let (vc, instance) = makeDisplayController(width: 1280, height: 800, ppi: 144)
        guard let hiDPI = firstSwitch(action: "displayHiDPIToggled", in: vc.view) else {
            Issue.record("Expected the HiDPI switch")
            return
        }
        #expect(hiDPI.state == .off)

        hiDPI.state = .on
        hiDPI.sendAction(hiDPI.action, to: hiDPI.target)

        #expect(instance.configuration.displayHiDPI == true)
        #expect(instance.configuration.displayWidth == 2560)
        #expect(instance.configuration.displayHeight == 1600)
        #expect(instance.configuration.displayPPI == DisplayBootSizing.hiDPIPixelsPerInch)
        // The fields keep showing the "looks like" size.
        #expect(editableField("Width", in: vc.view)?.integerValue == 1280)

        hiDPI.state = .off
        hiDPI.sendAction(hiDPI.action, to: hiDPI.target)

        #expect(instance.configuration.displayHiDPI == false)
        #expect(instance.configuration.displayWidth == 1280)
        #expect(instance.configuration.displayHeight == 800)
        #expect(instance.configuration.displayPPI == DisplayBootSizing.standardPixelsPerInch)
    }

    @Test("In match mode HiDPI writes only the flag")
    func hiDPIInMatchModeLeavesTheTrioAlone() {
        let (vc, instance) = makeDisplayController(
            sizesToWindow: true, width: 2800, height: 1760, ppi: 220)
        guard let hiDPI = firstSwitch(action: "displayHiDPIToggled", in: vc.view) else {
            Issue.record("Expected the HiDPI switch")
            return
        }

        hiDPI.state = .off
        hiDPI.sendAction(hiDPI.action, to: hiDPI.target)

        #expect(instance.configuration.displayHiDPI == false)
        // The trio is the last boot's artifact until the next start recomputes it.
        #expect(instance.configuration.displayWidth == 2800)
        #expect(instance.configuration.displayHeight == 1760)
        #expect(instance.configuration.displayPPI == 220)
    }

    @Test("The HiDPI switch shows the stored intent, the fields the stored size")
    func hiDPISwitchShowsIntentNotDensity() {
        let (retinaVC, _) = makeDisplayController(width: 2560, height: 1600, ppi: 220)
        #expect(firstSwitch(action: "displayHiDPIToggled", in: retinaVC.view)?.state == .on)
        // The fields show the halved "looks like" size.
        #expect(editableField("Width", in: retinaVC.view)?.integerValue == 1280)

        let (standardVC, _) = makeDisplayController(width: 1920, height: 1200, ppi: 144)
        #expect(firstSwitch(action: "displayHiDPIToggled", in: standardVC.view)?.state == .off)
        #expect(editableField("Width", in: standardVC.view)?.integerValue == 1920)

        // Match mode on a 1× host: the intent is on while the trio it last
        // booted at is not, and each control shows its own.
        let (divergentVC, _) = makeDisplayController(
            sizesToWindow: true, width: 1400, height: 880, ppi: 144, hiDPI: true)
        #expect(firstSwitch(action: "displayHiDPIToggled", in: divergentVC.view)?.state == .on)
        #expect(editableField("Width", in: divergentVC.view)?.integerValue == 1400)
    }

    @Test("Turning match-window off reconciles the trio to the HiDPI intent")
    func matchWindowOffReconcilesTrioToIntent() {
        let (vc, instance) = makeDisplayController(
            sizesToWindow: true, width: 1400, height: 880, ppi: 144, hiDPI: true)
        guard let match = firstSwitch(action: "displayMatchWindowToggled", in: vc.view) else {
            Issue.record("Expected the match-window switch")
            return
        }

        match.state = .off
        match.sendAction(match.action, to: match.target)

        // Manual mode boots at the trio, so it has to carry the intent.
        #expect(instance.configuration.displaySizesToWindow == false)
        #expect(instance.configuration.displayWidth == 2800)
        #expect(instance.configuration.displayHeight == 1760)
        #expect(instance.configuration.displayPPI == DisplayBootSizing.hiDPIPixelsPerInch)
        #expect(editableField("Width", in: vc.view)?.integerValue == 1400)
    }

    @Test("Turning match-window off leaves an already-matching trio alone")
    func matchWindowOffKeepsAConsistentTrio() {
        let (vc, instance) = makeDisplayController(
            sizesToWindow: true, width: 2800, height: 1760, ppi: 220, hiDPI: true)
        guard let match = firstSwitch(action: "displayMatchWindowToggled", in: vc.view) else {
            Issue.record("Expected the match-window switch")
            return
        }

        match.state = .off
        match.sendAction(match.action, to: match.target)

        #expect(instance.configuration.displayWidth == 2800)
        #expect(instance.configuration.displayHeight == 1760)
        #expect(instance.configuration.displayPPI == 220)
    }

    @Test("A Linux VM leaving match-window mode keeps its resolution")
    func matchWindowOffIgnoresHiDPIForLinux() {
        // The flag defaults on and Linux has no HiDPI row: reconciliation must
        // not double a resolution VZ will report without any density.
        let (vc, instance) = makeDisplayController(
            guestOS: .linux, sizesToWindow: true, width: 1400, height: 880, ppi: 144, hiDPI: true)
        guard let match = firstSwitch(action: "displayMatchWindowToggled", in: vc.view) else {
            Issue.record("Expected the match-window switch")
            return
        }

        match.state = .off
        match.sendAction(match.action, to: match.target)

        #expect(instance.configuration.displayWidth == 1400)
        #expect(instance.configuration.displayHeight == 880)
        #expect(instance.configuration.displayPPI == 144)
    }

    @Test("Read-only disables the display lockables but not auto-resize")
    func readOnlyDisablesDisplayLockables() {
        for guestOS in [VMGuestOS.macOS, .linux] {
            let (vc, _) = makeDisplayController(guestOS: guestOS, isReadOnly: true)

            #expect(
                firstSwitch(action: "displayMatchWindowToggled", in: vc.view)?.isEnabled == false)
            #expect(firstPopUp(action: "displayResolutionChanged", in: vc.view)?.isEnabled == false)
            #expect(editableField("Width", in: vc.view)?.isEnabled == false)
            #expect(firstSwitch(action: "displayAutoResizeToggled", in: vc.view)?.isEnabled == true)
            if guestOS == .macOS {
                #expect(firstSwitch(action: "displayHiDPIToggled", in: vc.view)?.isEnabled == false)
            }
        }
    }

    @Test("Toggling auto-resize writes back to the configuration")
    func autoResizeToggleWritesConfig() {
        for guestOS in [VMGuestOS.macOS, .linux] {
            let (vc, instance) = makeDisplayController(guestOS: guestOS, isReadOnly: true)
            guard let toggle = firstSwitch(action: "displayAutoResizeToggled", in: vc.view) else {
                Issue.record("Expected the auto-resize switch")
                return
            }
            #expect(instance.configuration.displayAutoResizes == true)

            toggle.state = .off
            toggle.sendAction(toggle.action, to: toggle.target)

            #expect(instance.configuration.displayAutoResizes == false)
        }
    }

    @Test("A refresh leaves a size field the user is still typing in alone")
    func refreshKeepsAnInProgressSizeEdit() {
        let (vc, _) = makeDisplayController(width: 1920, height: 1200)
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        guard let width = editableField("Width", in: vc.view) else {
            Issue.record("Expected the width field")
            return
        }
        #expect(window.makeFirstResponder(width))
        guard let editor = width.currentEditor() else {
            Issue.record("Expected a field editor on the focused width field")
            return
        }
        editor.string = "1600"

        // Stands in for any observation pass — starting the VM from the toolbar
        // mutates status, which refreshes the whole pane.
        vc.viewDidAppear()

        #expect(width.currentEditor()?.string == "1600")
        // The committed value is untouched: only the editor holds the edit.
        #expect(editableField("Height", in: vc.view)?.integerValue == 1200)
    }

    @Test("The restart caption shows only while read-only")
    func restartCaptionOnlyWhileReadOnly() {
        let caption = "Takes effect on next start."

        let (readOnlyVC, _) = makeDisplayController(isReadOnly: true)
        #expect(visibleLabel(caption, in: readOnlyVC.view))

        let (editableVC, _) = makeDisplayController(isReadOnly: false)
        #expect(!visibleLabel(caption, in: editableVC.view))
    }

    // MARK: - Microphone permission

    /// Builds a controller whose Audio section is driven by a pinned permission
    /// status, so the denied banner does not depend on the test host's own TCC
    /// state.
    private func makeMicController(
        _ status: AVAuthorizationStatus,
        systemSettings: SystemSettingsLink = SystemSettingsLink()
    ) -> VMSettingsViewController {
        let instance = makeInstance(guestOS: .linux)
        instance.configuration.audioInputEnabled = true
        let vc = VMSettingsViewController(
            instance: instance, viewModel: makeViewModel(), isReadOnly: false,
            micPermissionStatus: { status }, systemSettings: systemSettings)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        return vc
    }

    @Test("Denied permission shows the warning banner with an Open System Settings button")
    func deniedMicShowsBannerAndButton() {
        let vc = makeMicController(.denied)

        #expect(findLabel(containing: "Microphone permission is denied", in: vc.view) != nil)
        #expect(findButton(titled: "Open System Settings", in: vc.view) != nil)
    }

    @Test("The banner's Open System Settings button opens the Microphone privacy pane")
    func deniedMicBannerButtonOpensSettings() throws {
        let recorder = URLOpenRecorder(results: [true])
        let vc = makeMicController(.denied, systemSettings: SystemSettingsLink(open: recorder.open))

        let button = try #require(findButton(titled: "Open System Settings", in: vc.view))
        button.performClick(nil)

        #expect(recorder.opened == [SystemSettingsLink.microphonePrivacyURL])
    }

    @Test("An undetermined permission explains the upcoming prompt instead of offering the link")
    func undeterminedMicShowsCaptionOnly() {
        let vc = makeMicController(.notDetermined)

        #expect(
            findLabel(
                withText: "macOS will ask for microphone permission the first time a VM uses it.",
                in: vc.view) != nil)
        #expect(findButton(titled: "Open System Settings", in: vc.view) == nil)
    }

    @Test("Granted permission shows neither the banner nor the link")
    func authorizedMicShowsNothing() {
        let vc = makeMicController(.authorized)

        #expect(findLabel(containing: "Microphone permission is denied", in: vc.view) == nil)
        #expect(findButton(titled: "Open System Settings", in: vc.view) == nil)
    }
}
