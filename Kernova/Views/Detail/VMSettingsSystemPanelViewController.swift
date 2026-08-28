import AVFoundation
import AppKit
import os

/// The System category: the VM's resources, display, audio, input devices and
/// serial console — everything about the machine the guest runs on.
@MainActor
final class VMSettingsSystemPanelViewController: NSViewController, VMSettingsPanel {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "VMSettingsSystemPanel")

    let context: VMSettingsPanelContext
    let category = VMSettingsCategory.system
    private var lockRegistry = VMSettingsLockRegistry()

    private let micPermissionPresenter = PopoverPresenter()
    private var micPermission: AVAuthorizationStatus
    private var micPermissionStatus: @MainActor () -> AVAuthorizationStatus {
        context.micPermissionStatus
    }
    private var systemSettings: SystemSettingsLink { context.systemSettings }

    private let panelStack = NSStackView()

    init(context: VMSettingsPanelContext) {
        self.context = context
        self.micPermission = context.micPermissionStatus()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMSettingsSystemPanelViewController does not support NSCoder")
    }

    override func loadView() {
        panelStack.orientation = .vertical
        panelStack.alignment = .leading
        panelStack.spacing = Spacing.section
        panelStack.translatesAutoresizingMaskIntoConstraints = false
        view = panelStack
        rebuild()
    }

    // MARK: - Panel

    func rebuild() {
        loadViewIfNeeded()
        panelStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        lockRegistry.removeAll()
        renderedAudioWarning = nil
        displayResolutionIsCustom = false

        var sections = [buildResourcesSection(), buildDisplaySection(), buildAudioSection()]
        if instance.configuration.guestOS == .macOS {
            sections.append(buildInputDevicesSection())
        }
        sections.append(buildSerialRelaySection())
        for section in sections {
            panelStack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: panelStack.widthAnchor).isActive = true
        }
    }

    func refresh() {
        lockRegistry.apply(isReadOnly: isReadOnly)
        refreshResources()
        refreshDisplay()
        refreshAudio()
        refreshInputDevices()
        refreshSerialRelay()
    }

    func contribute(to resolved: inout VMOverviewResolved) {
        resolved.inputDevicesTitle =
            instance.configuration.guestOS == .macOS ? inputDevicesPopUp.titleOfSelectedItem : nil
        if renderedAudioWarning == .denied {
            resolved.warnings[.system] = Self.micPermissionDeniedWarning
        }
    }

    func prepareForDisappearance() {
        if micPermissionPresenter.isShown { micPermissionPresenter.close() }
    }

    /// The permission may have been changed in System Settings while the app was
    /// away, so it is re-read rather than trusted from the last pass.
    func hostDidBecomeActive() {
        refreshMicPermission()
    }

    // Resources
    private var cpuField = NSTextField()
    private var cpuStepper = NSStepper()
    private var memoryField = NSTextField()
    private var memoryStepper = NSStepper()

    // Display
    private var displayMatchWindowSwitch = NSSwitch()
    private var displayResolutionPopUp = NSPopUpButton()
    private var displayWidthField = NSTextField()
    private var displayHeightField = NSTextField()
    private var displayHiDPISwitch = NSSwitch()
    private var displayAutoResizeSwitch = NSSwitch()
    /// Caption naming the resolution the guest will boot at.
    private var displayResolutionCaption = NSTextField()
    /// Orange "takes effect on next start" caption, shown only while read-only.
    private var displayRestartCaption = NSTextField()
    /// Set while the user has explicitly chosen Custom, so the popup doesn't
    /// snap back to a preset the current size happens to match.
    private var displayResolutionIsCustom = false

    // Audio
    private var audioInputSwitch = NSSwitch()
    private var audioOutputSwitch = NSSwitch()
    private var audioWarningContainer = NSStackView()

    // Input devices (macOS guests only)
    private var inputDevicesPopUp = NSPopUpButton()

    // Serial Console
    private var serialRelaySwitch = NSSwitch()
    private var revealSerialLogButton = NSButton()

    private var renderedAudioWarning: MicWarningState?
    // MARK: Resources

    private func buildResourcesSection() -> NSView {
        let os = instance.configuration.guestOS
        cpuField = NSTextField()
        cpuStepper = NSStepper()
        memoryField = NSTextField()
        memoryStepper = NSStepper()
        configureGroupedFormNumeric(
            field: cpuField, stepper: cpuStepper, min: os.minCPUCount, max: os.maxCPUCount,
            value: instance.configuration.cpuCount, delegate: self, target: self,
            stepperAction: #selector(cpuStepperChanged))
        configureGroupedFormNumeric(
            field: memoryField, stepper: memoryStepper, min: os.minMemoryInGB, max: os.maxMemoryInGB,
            value: instance.configuration.memorySizeInGB, delegate: self, target: self,
            stepperAction: #selector(memoryStepperChanged))
        let card = makeGroupedFormCard(rows: [
            lockRegistry.lockable(
                makeGroupedFormCardRow(
                    "CPU cores", control: makeGroupedFormSteppedControl(cpuField, cpuStepper, unit: "")),
                cpuField, cpuStepper),
            lockRegistry.lockable(
                makeGroupedFormCardRow(
                    "Memory", control: makeGroupedFormSteppedControl(memoryField, memoryStepper, unit: "GB")),
                memoryField, memoryStepper),
        ])
        return makeGroupedFormSection([
            lockRegistry.makeHeader(
                "Resources", lockable: true,
                paragraphs: [
                    .body(
                        "Memory is committed to the VM up-front at start time — keep enough free on the host to avoid swap pressure. CPU cores are scheduled by the host; over-committing is fine but reduces per-core performance under load."
                    )
                ]), card,
        ])
    }

    // MARK: Display

    /// A base ("looks like") size offered by the Resolution popup, carried by its
    /// menu item as the item's `representedObject`.
    private struct DisplayResolutionPreset: Equatable {
        let width: Int
        let height: Int
    }

    private static let displayResolutionPresets: [DisplayResolutionPreset] = [
        .init(width: 1280, height: 800), .init(width: 1440, height: 900),
        .init(width: 1680, height: 1050), .init(width: 1920, height: 1080),
        .init(width: 1920, height: 1200), .init(width: 2560, height: 1440),
        .init(width: 2560, height: 1600),
    ]

    /// The one item carrying no preset, selected for any size off the list.
    private static let displayCustomTitle = "Custom"

    private func buildDisplaySection() -> NSView {
        let isMacOS = instance.configuration.guestOS == .macOS
        let supportsDensity = instance.configuration.guestOS.supportsDisplayDensity
        displayMatchWindowSwitch = makeGroupedFormSwitch(target: self, action: #selector(displayMatchWindowToggled))
        displayResolutionPopUp = makeDisplayResolutionPopUp()
        displayWidthField = makeDisplaySizeField()
        displayHeightField = makeDisplaySizeField()
        displayHiDPISwitch = makeGroupedFormSwitch(target: self, action: #selector(displayHiDPIToggled))
        displayAutoResizeSwitch = makeGroupedFormSwitch(target: self, action: #selector(displayAutoResizeToggled))

        var rows: [NSView] = [
            // Deliberately not `lockable`: the flag lives on the display view, so
            // it is legal to flip while the VM runs.
            makeGroupedFormToggleRowWithInfo(
                "Automatically resize with window", control: displayAutoResizeSwitch,
                paragraphs: Self.displayAutoResizeInfo(isMacOS: isMacOS)),
            lockRegistry.lockable(
                makeGroupedFormToggleRowWithInfo(
                    "Size display to fit window at startup", control: displayMatchWindowSwitch,
                    paragraphs: [
                        .body(
                            "Each cold start sizes the guest display to the window or screen it opens in, so the picture fills it without scaling."
                        ),
                        .body(
                            "A VM resumed from saved state keeps the resolution it was saved with — VZ restores only into the configuration it was suspended from."
                        ),
                    ]), displayMatchWindowSwitch),
            lockRegistry.lockable(
                makeGroupedFormCardRow("Resolution", control: displayResolutionPopUp),
                displayResolutionPopUp),
            lockRegistry.lockable(makeGroupedFormCardRow("Width", control: displayWidthField), displayWidthField),
            lockRegistry.lockable(makeGroupedFormCardRow("Height", control: displayHeightField), displayHeightField),
        ]
        if supportsDensity {
            rows.append(
                lockRegistry.lockable(
                    makeGroupedFormToggleRowWithInfo(
                        "HiDPI (Retina)", control: displayHiDPISwitch,
                        paragraphs: [
                            .body(
                                "Doubles the pixel count and raises the reported pixel density, so the guest renders Retina-sharp at the size above."
                            ),
                            .body(
                                "While the display is sized to fit the window, it fills the window at your screen's Retina scale instead of 1×."
                            ),
                        ]), displayHiDPISwitch))
        }
        displayResolutionCaption = makeGroupedFormCaption("")
        let restart = makeGroupedFormCaption("Takes effect on next start.")
        restart.textColor = .systemOrange
        restart.isHidden = true
        displayRestartCaption = restart

        return makeGroupedFormSection([
            lockRegistry.makeHeader("Display", lockable: true),
            makeGroupedFormCard(rows: rows),
            displayResolutionCaption,
            displayRestartCaption,
        ])
    }

    /// Info copy for the auto-resize row, whose consequences differ by guest OS.
    private static func displayAutoResizeInfo(isMacOS: Bool) -> [InfoPopoverParagraph] {
        if isMacOS {
            return [
                .body(
                    "Lets the guest change its own resolution to match the window as you resize it, instead of scaling the boot resolution. Requires macOS 14 or later in the guest — earlier guests keep the resolution set at startup and scale it to fit."
                ),
                .body("Takes effect immediately, including while the VM is running."),
            ]
        }
        return [
            .body(
                "Lets the guest change its own resolution to match the window as you resize it. Some guests may reset certain display settings (such as the scaling factor) whenever the resolution changes."
            ),
            .body("Takes effect immediately, including while the VM is running."),
        ]
    }

    private func makeDisplayResolutionPopUp() -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.controlSize = .small
        for preset in Self.displayResolutionPresets {
            popUp.addItem(withTitle: "\(preset.width) × \(preset.height)")
            popUp.lastItem?.representedObject = preset
        }
        popUp.menu?.addItem(.separator())
        popUp.addItem(withTitle: Self.displayCustomTitle)
        popUp.target = self
        popUp.action = #selector(displayResolutionChanged)
        return popUp
    }

    private func makeDisplaySizeField() -> NSTextField {
        let field = NSTextField()
        field.alignment = .right
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        return field
    }

    // MARK: Audio

    private func buildAudioSection() -> NSView {
        audioInputSwitch = makeGroupedFormSwitch(target: self, action: #selector(audioInputToggled))
        audioOutputSwitch = makeGroupedFormSwitch(target: self, action: #selector(audioOutputToggled))

        audioWarningContainer = NSStackView()
        audioWarningContainer.orientation = .vertical
        audioWarningContainer.alignment = .leading
        audioWarningContainer.spacing = Spacing.small
        audioWarningContainer.translatesAutoresizingMaskIntoConstraints = false

        var paragraphs: [InfoPopoverParagraph] = [
            .body(
                "Exposes a VirtioSound device with independent streams. Audio Input lets the guest capture from your Mac's audio input; Audio Output plays guest sound through your Mac."
            )
        ]
        if instance.configuration.guestOS == .linux {
            paragraphs.append(.body("Requires Linux kernel 5.14 or newer to detect the VirtioSound device."))
        }
        return makeGroupedFormSection([
            lockRegistry.makeHeader("Audio", lockable: true, paragraphs: paragraphs),
            makeGroupedFormCard(rows: [
                lockRegistry.lockable(
                    makeGroupedFormCardRow("Audio input", control: audioInputSwitch),
                    audioInputSwitch),
                lockRegistry.lockable(
                    makeGroupedFormCardRow("Audio output", control: audioOutputSwitch),
                    audioOutputSwitch),
            ]),
            audioWarningContainer,
        ])
    }

    // MARK: Input Devices

    /// Titles and modes for the input devices popup, in menu order.
    private static let inputDeviceChoices: [(title: String, mode: VMInputDeviceMode)] = [
        ("Automatic", .automatic),
        ("Mac Keyboard and Trackpad", .mac),
        ("USB Keyboard and Mouse", .usb),
    ]

    /// Info copy for the macOS-only input devices picker.
    private static let inputDevicesInfoParagraphs: [InfoPopoverParagraph] = [
        .body(
            "Chooses the virtual keyboard and pointing device the guest sees. Automatic picks by the guest's macOS version: the Mac devices for macOS 13 and later, the USB devices for earlier guests, which don't recognize the Mac ones. When the guest's version isn't known, Automatic picks the Mac devices — choose USB here if such a guest has no working input."
        ),
        .body(
            "The USB pointer reads as a mouse inside the guest, so macOS shows permanently visible scroll bars instead of trackpad-style overlay scroll bars."
        ),
    ]

    private func buildInputDevicesSection() -> NSView {
        inputDevicesPopUp = makeInputDevicesPopUp()
        return makeGroupedFormSection([
            lockRegistry.makeHeader("Input", lockable: true, paragraphs: Self.inputDevicesInfoParagraphs),
            makeGroupedFormCard(rows: [
                lockRegistry.lockable(
                    makeGroupedFormCardRow("Devices", control: inputDevicesPopUp), inputDevicesPopUp)
            ]),
        ])
    }

    private func makeInputDevicesPopUp() -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.controlSize = .small
        for choice in Self.inputDeviceChoices {
            popUp.addItem(withTitle: choice.title)
            popUp.lastItem?.representedObject = choice.mode
        }
        popUp.target = self
        popUp.action = #selector(inputDevicesChanged)
        return popUp
    }

    // MARK: Serial Console

    private func buildSerialRelaySection() -> NSView {
        serialRelaySwitch = makeGroupedFormSwitch(target: self, action: #selector(serialRelayToggled))
        revealSerialLogButton = makeGroupedFormPushButton(
            "Reveal serial.log in Finder", target: self, action: #selector(revealSerialLog))
        let socketPath = VMInstance.serialSocketPath(for: instance.id)
        let card = makeGroupedFormCard(rows: [
            makeGroupedFormToggleRowWithInfo(
                "Expose serial socket", control: serialRelaySwitch,
                paragraphs: [
                    .body(
                        "Exposes the running VM's serial port over a local UNIX socket so an external terminal can attach. Output is always captured to `serial.log` regardless of this setting; when it grows large it rolls to `serial.log.1` alongside."
                    ),
                    .body(
                        "While the VM is running, connect with `socat` (best for full-screen apps; `brew install socat`):"
                    ),
                    .code("socat -,raw,echo=0 UNIX-CONNECT:\(socketPath)"),
                    .body("…or the built-in `nc` (line mode):"),
                    .code("nc -U \(socketPath)"),
                ]),
            makeGroupedFormButtonRow([revealSerialLogButton]),
        ])
        return makeGroupedFormSection([lockRegistry.makeHeader("Serial Console"), card])
    }
    private func refreshResources() {
        let os = instance.configuration.guestOS
        cpuStepper.minValue = Double(os.minCPUCount)
        cpuStepper.maxValue = Double(os.maxCPUCount)
        cpuStepper.integerValue = instance.configuration.cpuCount
        cpuField.integerValue = instance.configuration.cpuCount
        memoryStepper.minValue = Double(os.minMemoryInGB)
        memoryStepper.maxValue = Double(os.maxMemoryInGB)
        memoryStepper.integerValue = instance.configuration.memorySizeInGB
        memoryField.integerValue = instance.configuration.memorySizeInGB
    }

    /// The density the user asked for, which a match-window boot applies to the
    /// size it computes.
    private var displayHiDPIIntent: Bool {
        instance.configuration.guestOS.supportsDisplayDensity
            && instance.configuration.displayHiDPI
    }

    /// Whether the stored resolution reads as HiDPI — the materialized
    /// counterpart to `displayHiDPIIntent`; the two diverge only in match mode,
    /// where the trio is the previous boot's artifact.
    private var displayResolutionIsHiDPI: Bool {
        instance.configuration.displayResolutionIsHiDPI
    }

    /// The "looks like" size shown in the Width/Height fields.
    private var displayBaseSize: (width: Int, height: Int) {
        instance.configuration.displayBaseSize
    }

    private func refreshDisplay() {
        let config = instance.configuration
        let base = displayBaseSize
        displayMatchWindowSwitch.state = config.displaySizesToWindow ? .on : .off
        // Intent, not the stored density: in match mode the two legitimately
        // differ until the next boot materializes the trio.
        displayHiDPISwitch.state = displayHiDPIIntent ? .on : .off
        displayAutoResizeSwitch.state = config.displayAutoResizes ? .on : .off
        // A field with an open editor is mid-edit: any refresh — a status change
        // started from the toolbar, say — would otherwise discard the keystrokes
        // typed so far.
        if displayWidthField.currentEditor() == nil {
            displayWidthField.integerValue = base.width
        }
        if displayHeightField.currentEditor() == nil {
            displayHeightField.integerValue = base.height
        }

        let stored = DisplayResolutionPreset(width: base.width, height: base.height)
        let presetItem =
            displayResolutionIsCustom
            ? nil
            : displayResolutionPopUp.menu?.items.first {
                $0.representedObject as? DisplayResolutionPreset == stored
            }
        if let presetItem {
            displayResolutionPopUp.select(presetItem)
        } else {
            displayResolutionPopUp.selectItem(withTitle: Self.displayCustomTitle)
        }

        // Match mode computes the size at start, so the size controls are inert
        // (disabled, not hidden). HiDPI stays live — it picks the scale that
        // computation runs at.
        let manualEnabled = !isReadOnly && !config.displaySizesToWindow
        displayResolutionPopUp.isEnabled = manualEnabled
        displayWidthField.isEnabled = manualEnabled
        displayHeightField.isEnabled = manualEnabled

        displayResolutionCaption.stringValue = displayResolutionCaptionText()
        displayRestartCaption.isHidden = !isReadOnly
    }

    private func displayResolutionCaptionText() -> String {
        let config = instance.configuration
        var text = "Boots at \(config.displayWidth) × \(config.displayHeight) pixels"
        if displayResolutionIsHiDPI {
            let base = displayBaseSize
            text += " (looks like \(base.width) × \(base.height))"
        }
        if config.displaySizesToWindow {
            return "\(text), until the next start resizes it to the window."
        }
        return "\(text)."
    }

    /// What the Audio banner — and the System card's warning glyph — say about a
    /// refused microphone.
    static let micPermissionDeniedWarning =
        "Microphone permission is denied. Enable it in System Settings for Kernova to pass your microphone to VMs."

    private func refreshAudio() {
        audioInputSwitch.state = instance.configuration.audioInputEnabled ? .on : .off
        audioOutputSwitch.state = instance.configuration.audioOutputEnabled ? .on : .off
        let warning = micPermissionPresentation(
            micPermission, audioInputEnabled: instance.configuration.audioInputEnabled)
        guard warning != renderedAudioWarning else { return }
        renderedAudioWarning = warning
        audioWarningContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }

        switch warning {
        case .none:
            break
        case .willPrompt:
            let caption = makeGroupedFormCaption(
                "macOS will ask for microphone permission the first time a VM uses it.")
            addGroupedFormFullWidth(caption, to: audioWarningContainer)
        case .denied:
            let info = NSButton(
                image: .systemSymbol("info.circle", accessibilityDescription: "Microphone permission help"),
                target: self, action: #selector(showMicPermissionInfo))
            info.isBordered = false
            info.imagePosition = .imageOnly
            info.contentTintColor = .secondaryLabelColor
            let openSettings = NSButton(
                title: "Open System Settings", target: self, action: #selector(openMicPermissionSettings))
            let banner = makeGroupedFormBanner(
                symbolName: "exclamationmark.triangle.fill",
                tint: .systemRed,
                message: Self.micPermissionDeniedWarning,
                trailingButtons: [openSettings, info])
            addGroupedFormFullWidth(banner, to: audioWarningContainer)
        }
    }

    private func refreshInputDevices() {
        guard instance.configuration.guestOS == .macOS else { return }
        let mode = instance.configuration.inputDeviceMode
        let index = inputDevicesPopUp.itemArray.firstIndex {
            ($0.representedObject as? VMInputDeviceMode) == mode
        }
        guard let index else {
            Self.logger.fault("No popup item for input device mode '\(mode.rawValue, privacy: .public)'")
            assertionFailure("No popup item for input device mode: \(mode.rawValue)")
            return
        }
        inputDevicesPopUp.selectItem(at: index)
    }

    private func refreshSerialRelay() {
        serialRelaySwitch.state = instance.configuration.serialSocketRelayEnabled ? .on : .off
        // serial.log is created on first run and persists thereafter; disable
        // the reveal button until it exists.
        revealSerialLogButton.isEnabled = FileManager.default.fileExists(
            atPath: instance.serialLogURL.path(percentEncoded: false))
    }

    private func refreshMicPermission() {
        micPermission = micPermissionStatus()
    }

    @objc private func cpuStepperChanged() {
        cpuField.integerValue = cpuStepper.integerValue
        writeConfig { $0.cpuCount = cpuStepper.integerValue }
    }

    @objc private func memoryStepperChanged() {
        memoryField.integerValue = memoryStepper.integerValue
        writeConfig { $0.memorySizeInGB = memoryStepper.integerValue }
    }

    // MARK: Display

    @objc private func displayMatchWindowToggled() {
        let sizesToWindow = displayMatchWindowSwitch.state == .on
        let hiDPI = displayHiDPIIntent
        writeConfig { config in
            config.displaySizesToWindow = sizesToWindow
            // Leaving match mode promotes the trio from the last boot's artifact
            // to the resolution the VM boots at, so it has to carry the intent
            // set while nothing was reconciling it.
            guard !sizesToWindow, hiDPI != DisplayBootSizing.isHiDPI(ppi: config.displayPPI) else {
                return
            }
            config.displayResolution = DisplayBootSizing.rescaled(
                config.displayResolution, toHiDPI: hiDPI)
        }
        // The write flips the manual controls' enablement; refresh in case the
        // value was already what the model held.
        refreshDisplay()
    }

    @objc private func displayResolutionChanged() {
        guard
            let preset = displayResolutionPopUp.selectedItem?.representedObject
                as? DisplayResolutionPreset
        else {
            displayResolutionIsCustom = true
            return
        }
        displayResolutionIsCustom = false
        // Route through the field-edit path so preset and typed sizes share one
        // clamp-and-write.
        displayWidthField.integerValue = preset.width
        displayHeightField.integerValue = preset.height
        applyDisplaySizeFieldEdit()
    }

    @objc private func displayHiDPIToggled() {
        let hiDPI = displayHiDPISwitch.state == .on
        let sizesToWindow = instance.configuration.displaySizesToWindow
        writeConfig { config in
            config.displayHiDPI = hiDPI
            // In match mode the trio is the last boot's artifact; the next boot
            // recomputes it at the scale this flag picks.
            guard !sizesToWindow else { return }
            config.displayResolution = DisplayBootSizing.rescaled(
                config.displayResolution, toHiDPI: hiDPI)
        }
        // The size fields are derived from the trio this may have rewritten;
        // reconcile them now rather than on the configuration observation.
        refreshDisplay()
    }

    @objc private func displayAutoResizeToggled() {
        writeConfig { $0.displayAutoResizes = displayAutoResizeSwitch.state == .on }
    }

    /// Clamps the typed base size, scales it for the current HiDPI state, and
    /// persists it.
    private func applyDisplaySizeFieldEdit() {
        // The fields are only editable in manual mode, where intent and stored
        // density agree; pairing with the stored one keeps the write the exact
        // inverse of the `displayBaseSize` that filled them.
        let hiDPI = displayResolutionIsHiDPI
        // A HiDPI base is doubled before it reaches VZ, so it clamps to half
        // the pixel ceiling.
        let base = DisplayBootSizing.clamped(
            width: displayWidthField.integerValue, height: displayHeightField.integerValue,
            ppi: DisplayBootSizing.standardPixelsPerInch,
            maximum: hiDPI ? DisplayBootSizing.maximumDimension / 2 : DisplayBootSizing.maximumDimension)
        writeDisplayResolution(hiDPI ? DisplayBootSizing.doubled(base) : base)
    }

    private func writeDisplayResolution(_ resolution: DisplayBootSizing.Resolution) {
        writeConfig { $0.displayResolution = resolution }
        // A clamped-back-to-current edit writes nothing, so the fields and popup
        // are reconciled here rather than by the configuration observation.
        refreshDisplay()
    }

    @objc private func audioInputToggled() {
        refreshMicPermission()
        writeConfig { $0.audioInputEnabled = audioInputSwitch.state == .on }
    }

    @objc private func audioOutputToggled() {
        writeConfig { $0.audioOutputEnabled = audioOutputSwitch.state == .on }
    }

    @objc private func inputDevicesChanged() {
        guard
            let mode = inputDevicesPopUp.selectedItem?.representedObject as? VMInputDeviceMode
        else {
            Self.logger.fault("Input devices popup selection carries no mode")
            assertionFailure("Input devices popup selection carries no mode")
            return
        }
        writeConfig { $0.inputDeviceMode = mode }
    }

    @objc private func serialRelayToggled() {
        writeConfig { $0.serialSocketRelayEnabled = serialRelaySwitch.state == .on }
    }

    @objc private func revealSerialLog() {
        NSWorkspace.shared.activateFileViewerSelecting([instance.serialLogURL])
    }

    @objc private func showMicPermissionInfo(_ sender: NSButton) {
        micPermissionPresenter.show(
            content: MicrophonePermissionPopoverContentViewController(systemSettings: systemSettings),
            from: sender, preferredEdge: .minY)
    }

    @objc private func openMicPermissionSettings() {
        systemSettings.openMicrophonePrivacy()
    }

    private func applyCPUFieldEdit() {
        let os = instance.configuration.guestOS
        let clamped = Swift.min(Swift.max(cpuField.integerValue, os.minCPUCount), os.maxCPUCount)
        cpuField.integerValue = clamped
        cpuStepper.integerValue = clamped
        writeConfig { $0.cpuCount = clamped }
    }

    private func applyMemoryFieldEdit() {
        let os = instance.configuration.guestOS
        let clamped = Swift.min(Swift.max(memoryField.integerValue, os.minMemoryInGB), os.maxMemoryInGB)
        memoryField.integerValue = clamped
        memoryStepper.integerValue = clamped
        writeConfig { $0.memorySizeInGB = clamped }
    }
}

// MARK: - NSTextFieldDelegate

extension VMSettingsSystemPanelViewController: NSTextFieldDelegate {
    /// The panel is the delegate of the fields it builds, so a commit lands
    /// here rather than on the shell.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        switch field {
        case cpuField:
            applyCPUFieldEdit()
        case memoryField:
            applyMemoryFieldEdit()
        case displayWidthField, displayHeightField:
            applyDisplaySizeFieldEdit()
        default:
            break
        }
    }
}
