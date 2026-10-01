import AppKit
import KernovaKit
import KernovaLogging

/// The System category: the VM's resources, display, audio, input devices and
/// serial console — everything about the machine the guest runs on.
@MainActor
final class VMSettingsSystemPanelViewController: NSViewController, VMSettingsPanel {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMSettingsSystemPanel")

    let context: VMSettingsPanelContext
    let category = VMSettingsCategory.system
    private var lockRegistry = VMSettingsLockRegistry()

    private var systemSettings: SystemSettingsLink { context.systemSettings }

    private let panelStack = NSStackView()

    init(context: VMSettingsPanelContext) {
        self.context = context
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
    }

    // MARK: - Panel

    func rebuild() {
        loadViewIfNeeded()
        panelStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        lockRegistry.removeAll()
        renderedAudioWarning = nil
        displayResolutionIsCustom = false

        var sections = [buildResourcesSection(), buildDisplaySection(), buildAudioSection()]
        sections.append(buildInputSection())
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
        refreshInput()
        refreshSerialRelay()
    }

    func prepareForDisappearance() {
        serialLogProbe?.cancel()
        serialLogProbe = nil
        // Re-probe on the next pass: the cancelled read answered nothing, and
        // the log may have appeared while the pane was away.
        probedSerialLog = nil
    }

    // Resources
    private var cpuField = ModelValueField()
    private var cpuStepper = NSStepper()
    private var memoryField = ModelValueField()
    private var memoryStepper = NSStepper()

    // Display
    private var displayMatchWindowSwitch = NSSwitch()
    private var displayResolutionPopUp = NSPopUpButton()
    private var displayWidthField = ModelValueField()
    private var displayHeightField = ModelValueField()
    private var displayHiDPISwitch = NSSwitch()
    private var displayAutoResizeSwitch = NSSwitch()
    /// Says the next cold start sizes the display, while the display is sized
    /// to the window at startup and no save file stands in the way.
    private var displayResolutionCaption: GroupedFormStateNote?
    /// Set while the user has explicitly chosen Custom, so the popup doesn't
    /// snap back to a preset the current size happens to match.
    private var displayResolutionIsCustom = false

    // Audio
    private var audioInputSwitch = NSSwitch()
    private var audioOutputSwitch = NSSwitch()
    private var audioWarningContainer = NSStackView()

    // Input
    /// macOS guests only — Linux guests always take the USB pair.
    private var inputDevicesPopUp = NSPopUpButton()
    private var systemKeysPopUp = NSPopUpButton()

    // Serial Console
    private var serialRelaySwitch = NSSwitch()
    private var revealSerialLogButton = NSButton()
    /// What the last existence probe answered for, so the probe re-runs when the
    /// log it names could have appeared rather than on every refresh pass.
    private var probedSerialLog: SerialLogProbeKey?
    private var serialLogProbe: Task<Void, Never>?

    /// serial.log is created on the VM's first run and persists thereafter, so a
    /// probe stays good until either the VM or its run state moves.
    private struct SerialLogProbeKey: Equatable {
        let path: String
        let status: VMStatus
    }

    private var renderedAudioWarning: MicWarningState?

    /// The info paragraphs of the denied-microphone banner.
    static let micPermissionInfo: [InfoPopoverParagraph] = [
        .body("Kernova needs microphone permission to pass your mic input to virtual machines."),
        .body("In System Settings › Privacy & Security › Microphone, turn on Kernova."),
    ]
    // MARK: Resources

    private func buildResourcesSection() -> NSView {
        cpuField = ModelValueField()
        cpuStepper = NSStepper()
        memoryField = ModelValueField()
        memoryStepper = NSStepper()
        configureGroupedFormCount(
            field: cpuField, stepper: cpuStepper, bounds: VMResourceLimits.cpuCount,
            value: instance.configuration.cpuCount, delegate: self, target: self,
            stepperAction: #selector(cpuStepperChanged))
        configureGroupedFormMemory(
            field: memoryField, stepper: memoryStepper, bounds: VMResourceLimits.memorySize,
            value: instance.configuration.memorySizeInGB, delegate: self, target: self,
            stepperAction: #selector(memoryStepperChanged))
        let card = makeGroupedFormCard(rows: [
            lockRegistry.lockable(
                makeGroupedFormCardRow(
                    "CPU cores", control: makeGroupedFormSteppedControl(cpuField, cpuStepper, unit: ""),
                    info: [
                        .body(
                            "Cores are scheduled by the host. Assigning more than the host has is allowed but slows each core under load."
                        )
                    ]),
                cpuField, cpuStepper),
            // `VZVirtualMachineConfiguration.memorySize`'s header: "Not all
            // memory is allocated on start, the virtual machine allocates memory
            // on demand."
            lockRegistry.lockable(
                makeGroupedFormCardRow(
                    "Memory", control: makeGroupedFormSteppedControl(memoryField, memoryStepper, unit: "GB"),
                    info: [
                        .body(
                            "The memory the guest sees. The VM takes it from this Mac as the guest uses it, not all at start."
                        )
                    ]),
                memoryField, memoryStepper),
        ])
        return makeGroupedFormSection([lockRegistry.makeHeader("Resources", editableWhen: .stopped), card])
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
            // Not `lockable`: the flag lives on the display view, so
            // it is legal to flip while the VM runs.
            makeGroupedFormCardRow(
                "Automatically resize with window", control: displayAutoResizeSwitch,
                info: Self.displayAutoResizeInfo(isMacOS: isMacOS)),
            lockRegistry.lockable(
                makeGroupedFormCardRow(
                    "Size display to fit window at startup", control: displayMatchWindowSwitch,
                    info: [
                        .body(
                            "Each cold start sizes the guest display to the window or screen it opens in, so the picture fills it without scaling."
                        ),
                        .body(
                            "A VM resumed from saved state keeps the resolution it was saved with."
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
                    makeGroupedFormCardRow(
                        "HiDPI (Retina)", control: displayHiDPISwitch,
                        info: [
                            .body(
                                "Doubles the pixel count and raises the reported pixel density, so the guest renders Retina-sharp at the size above: it boots at twice the width and height shown."
                            ),
                            .body(
                                "While the display is sized to fit the window, it fills the window at your screen's Retina scale instead of 1×."
                            ),
                        ]), displayHiDPISwitch))
        }
        // A save file keeps the next start a resume at the saved size
        // (`applyMatchWindowBootResolution` leaves it alone), so the note
        // speaks only while the next start is a cold one.
        let resolution = GroupedFormStateNote(
            Self.displayNextColdStartNote,
            shownWhen: { [weak self] in
                guard let instance = self?.instance else { return false }
                return instance.configuration.displaySizesToWindow && !instance.hasSaveFile
            })
        displayResolutionCaption = resolution

        return makeGroupedFormSection([
            lockRegistry.makeHeader("Display", editableWhen: .stopped),
            makeGroupedFormCard(rows: rows, notes: [resolution]),
        ])
    }

    /// The note under the Display card while the display is sized to the window
    /// at startup and no save file stands in the way, saying why the size
    /// fields are disabled.
    static let displayNextColdStartNote = "The next cold start sizes the display to fit its window."

    /// Info copy for the auto-resize row, whose consequences differ by guest OS.
    private static func displayAutoResizeInfo(isMacOS: Bool) -> [InfoPopoverParagraph] {
        if isMacOS {
            return [
                .body(
                    "Lets the guest change its own resolution to match the window as you resize it, instead of scaling the boot resolution. Requires macOS 14 or later in the guest — earlier guests keep the resolution set at startup and scale it to fit."
                )
            ]
        }
        return [
            .body(
                "Lets the guest change its own resolution to match the window as you resize it. Some guests may reset certain display settings (such as the scaling factor) whenever the resolution changes."
            )
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

    private func makeDisplaySizeField() -> ModelValueField {
        let field = ModelValueField()
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

        let paragraphs: [InfoPopoverParagraph] =
            instance.configuration.guestOS == .linux
            ? [.body("Needs Linux kernel 5.14 or newer in the guest.")] : []
        return makeGroupedFormSection([
            lockRegistry.makeHeader("Audio", editableWhen: .stopped, paragraphs: paragraphs),
            makeGroupedFormCard(rows: [
                lockRegistry.lockable(
                    makeGroupedFormCardRow(
                        "Audio input", control: audioInputSwitch,
                        info: [
                            .body(
                                "Lets the guest capture from your Mac's audio input. macOS asks for microphone permission the first time a VM uses it."
                            )
                        ]),
                    audioInputSwitch),
                lockRegistry.lockable(
                    makeGroupedFormCardRow(
                        "Audio output", control: audioOutputSwitch,
                        info: [.body("Plays the guest's sound through your Mac.")]),
                    audioOutputSwitch),
            ]),
            audioWarningContainer,
        ])
    }

    // MARK: Input

    /// Titles and modes for the input devices popup, in menu order.
    private static let inputDeviceChoices: [(title: String, mode: VMInputDeviceMode)] = [
        ("Automatic", .automatic),
        ("Mac Keyboard and Trackpad", .mac),
        ("USB Keyboard and Mouse", .usb),
    ]

    /// Info copy for the macOS-only input devices picker.
    private static let inputDevicesInfoParagraphs: [InfoPopoverParagraph] = [
        .body(
            "Chooses the keyboard and pointing device the guest sees. Automatic picks the Mac devices for macOS 13 and later, and when the guest's version isn't known; USB for earlier guests, which don't recognize the Mac ones. Choose USB if a guest has no working input."
        ),
        .body(
            "The USB pointer reads as a mouse inside the guest, so macOS shows permanently visible scroll bars instead of trackpad-style overlay scroll bars."
        ),
    ]

    /// Titles and modes for the system keys popup, in menu order.
    ///
    /// "Full Screen" is Apple's own name for the state the middle choice reads.
    private static let systemKeyChoices: [(title: String, mode: VMSystemKeyForwarding)] = [
        ("Never", .never),
        ("In Full Screen", .fullscreenOnly),
        ("Always", .always),
    ]

    /// Info copy for the system keys picker.
    ///
    /// Which keys Virtualization forwards is Apple's to decide and its
    /// documentation names none, so neither does this.
    private static let systemKeysInfoParagraphs: [InfoPopoverParagraph] = [
        .body(
            "Sends certain system hot keys to the guest instead of the host, while the VM display has keyboard focus. Virtualization chooses which keys those are."
        ),
        .body(
            "In Full Screen narrows that to a display filling a screen of its own, so the same keys keep acting on this Mac while the VM is in a window."
        ),
    ]

    private func buildInputSection() -> NSView {
        let isMacOS = instance.configuration.guestOS == .macOS
        systemKeysPopUp = makePopUp(
            Self.systemKeyChoices, action: #selector(systemKeysChanged))

        // Not `lockable`: the flag lives on the display view, so it
        // is legal to flip while the VM runs.
        var rows: [NSView] = [
            makeGroupedFormCardRow(
                "Send system keys to guest", control: systemKeysPopUp,
                info: Self.systemKeysInfoParagraphs)
        ]
        if isMacOS {
            inputDevicesPopUp = makePopUp(
                Self.inputDeviceChoices, action: #selector(inputDevicesChanged))
            rows.append(
                lockRegistry.lockable(
                    makeGroupedFormCardRow(
                        "Devices", control: inputDevicesPopUp,
                        info: Self.inputDevicesInfoParagraphs), inputDevicesPopUp))
        }

        return makeGroupedFormSection([
            // A Linux guest's section holds only the live row, so nothing in it
            // waits on a stop and the hint would name a lock that isn't there.
            lockRegistry.makeHeader("Input", editableWhen: isMacOS ? .stopped : nil),
            makeGroupedFormCard(rows: rows),
        ])
    }

    /// A settings popup whose items carry `choices`' modes as represented
    /// objects, in menu order.
    private func makePopUp<Mode>(
        _ choices: [(title: String, mode: Mode)], action: Selector
    ) -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.controlSize = .small
        for choice in choices {
            popUp.addItem(withTitle: choice.title)
            popUp.lastItem?.representedObject = choice.mode
        }
        popUp.target = self
        popUp.action = action
        return popUp
    }

    // MARK: Serial Console

    private func buildSerialRelaySection() -> NSView {
        serialRelaySwitch = makeGroupedFormSwitch(target: self, action: #selector(serialRelayToggled))
        revealSerialLogButton = makeGroupedFormPushButton(
            "Reveal serial.log in Finder", target: self, action: #selector(revealSerialLog))
        let socketPath = VMInstance.serialSocketPath(for: instance.id)
        let card = makeGroupedFormCard(rows: [
            makeGroupedFormCardRow(
                "Expose serial socket", control: serialRelaySwitch,
                info: [
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
        cpuStepper.integerValue = instance.configuration.cpuCount
        cpuField.show(String(instance.configuration.cpuCount))
        memoryStepper.doubleValue = instance.configuration.memorySizeInGB.gibibytes
        memoryField.show(instance.configuration.memorySizeInGB.gibibytesText)
    }

    /// The density the user asked for, which a match-window boot applies to the
    /// size it computes.
    private var displayHiDPIIntent: Bool {
        instance.configuration.guestOS.supportsDisplayDensity
            && instance.configuration.displayHiDPI
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
        applyGroupedFormRowEnabled(
            isAvailable(Keys.displayAutoResize, writing: String(!config.displayAutoResizes)),
            control: displayAutoResizeSwitch)
        displayWidthField.show(String(base.width))
        displayHeightField.show(String(base.height))

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
        for control in [displayResolutionPopUp, displayWidthField, displayHeightField] as [NSControl] {
            applyGroupedFormRowEnabled(manualEnabled, control: control)
        }

        displayResolutionCaption?.refresh()
    }

    private func refreshAudio() {
        audioInputSwitch.state = instance.configuration.audioInputEnabled ? .on : .off
        audioOutputSwitch.state = instance.configuration.audioOutputEnabled ? .on : .off
        let warning = resolved.micWarning
        guard warning != renderedAudioWarning else { return }
        renderedAudioWarning = warning
        audioWarningContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }

        switch warning {
        case .none:
            break
        case .denied:
            let openSettings = NSButton(
                title: "Open System Settings", target: self, action: #selector(openMicPermissionSettings))
            let banner = makeGroupedFormBanner(
                symbolName: "exclamationmark.triangle.fill",
                tint: .systemRed,
                message: VMOverviewResolver.micPermissionDeniedWarning,
                trailingButtons: [openSettings],
                info: (label: "Microphone Permission", paragraphs: Self.micPermissionInfo))
            addGroupedFormFullWidth(banner, to: audioWarningContainer)
        }
    }

    private func refreshInput() {
        let forwarding = instance.configuration.systemKeyForwarding
        select(forwarding, in: systemKeysPopUp, named: "system keys")
        applyGroupedFormRowEnabled(
            isAvailable(Keys.inputSystemKeys, writing: forwarding.rawValue), control: systemKeysPopUp)
        guard instance.configuration.guestOS == .macOS else { return }
        select(instance.configuration.inputDeviceMode, in: inputDevicesPopUp, named: "input device")
    }

    /// Selects the item carrying `mode`, reporting a popup that was built
    /// without one rather than leaving a stale selection standing.
    private func select<Mode: RawRepresentable & Equatable>(
        _ mode: Mode, in popUp: NSPopUpButton, named what: String
    ) where Mode.RawValue == String {
        guard let index = popUp.itemArray.firstIndex(where: { ($0.representedObject as? Mode) == mode })
        else {
            #log(
                Self.logger, .fault,
                "No popup item for \(what, privacy: .public) mode '\(mode.rawValue, privacy: .public)'")
            assertionFailure("No popup item for \(what) mode: \(mode.rawValue)")
            return
        }
        popUp.selectItem(at: index)
    }

    private func refreshSerialRelay() {
        let relays = instance.configuration.serialSocketRelayEnabled
        serialRelaySwitch.state = relays ? .on : .off
        applyGroupedFormRowEnabled(
            isAvailable(Keys.serialSocket, writing: String(!relays)), control: serialRelaySwitch)
        probeSerialLog()
    }

    /// Disables the reveal button until an off-main probe finds the log.
    ///
    /// The existence check is a filesystem syscall, so it never runs on the
    /// refresh pass itself.
    private func probeSerialLog() {
        let key = SerialLogProbeKey(
            path: instance.serialLogURL.path(percentEncoded: false), status: instance.status)
        guard key != probedSerialLog else { return }
        probedSerialLog = key
        revealSerialLogButton.isEnabled = false
        serialLogProbe?.cancel()
        serialLogProbe = Task { [weak self] in
            let exists = await Task.detached {
                FileManager.default.fileExists(atPath: key.path)
            }.value
            guard !Task.isCancelled, let self, self.probedSerialLog == key else { return }
            self.revealSerialLogButton.isEnabled = exists
        }
    }

    #if DEBUG
    /// The in-flight serial.log probe, so a test awaits it instead of polling
    /// the button it enables.
    var serialLogProbeForTesting: Task<Void, Never>? { serialLogProbe }
    #endif

    @objc private func cpuStepperChanged() {
        write(Keys.cpus.assigning(String(cpuStepper.integerValue)))
        cpuField.showDiscardingEdit(String(instance.configuration.cpuCount))
    }

    @objc private func memoryStepperChanged() {
        if let stepped = groupedFormMemoryStep(
            memoryStepper, from: instance.configuration.memorySizeInGB,
            within: VMResourceLimits.memorySize)
        {
            write(Keys.memory.assigning(stepped.gibibytesText))
        }
        showStoredMemorySize()
    }

    // MARK: Display

    @objc private func displayMatchWindowToggled() {
        write(Keys.displaySizeToWindow.assigning(displayMatchWindowSwitch.state == .on))
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
        applyDisplayBaseSize(width: preset.width, height: preset.height)
    }

    @objc private func displayHiDPIToggled() {
        write(Keys.displayHiDPI.assigning(displayHiDPISwitch.state == .on))
        // The size fields are derived from the trio this may have rewritten;
        // reconcile them now rather than on the configuration observation.
        refreshDisplay()
    }

    @objc private func displayAutoResizeToggled() {
        write(Keys.displayAutoResize.assigning(displayAutoResizeSwitch.state == .on))
    }

    /// Writes the typed base size, if either field holds an edit.
    private func applyDisplaySizeFieldEdit() {
        guard displayWidthField.holdsUserEdit || displayHeightField.holdsUserEdit else {
            showStoredDisplaySize()
            return
        }
        applyDisplayBaseSize(
            width: displayWidthField.integerValue, height: displayHeightField.integerValue)
    }

    /// Fits a chosen base size to what the VM takes and writes it — the one
    /// fit-and-write a preset and a typed size share.
    ///
    /// The size is only choosable in manual mode, where intent and stored
    /// density agree, so the fit is the one the `display.width` and
    /// `display.height` keys store — a size out of range is fitted here rather
    /// than refused there.
    private func applyDisplayBaseSize(width: Int, height: Int) {
        let fitted = instance.configuration.fittedDisplayBaseSize(width: width, height: height)
        write(
            Keys.displayWidth.assigning(String(fitted.width)),
            Keys.displayHeight.assigning(String(fitted.height)))
        showStoredDisplaySize()
    }

    /// Ends any edit in the size fields and shows the size the VM holds.
    private func showStoredDisplaySize() {
        let stored = displayBaseSize
        displayWidthField.showDiscardingEdit(String(stored.width))
        displayHeightField.showDiscardingEdit(String(stored.height))
        refreshDisplay()
    }

    @objc private func audioInputToggled() {
        // The permission decides what the banner below the switch says, and the
        // user may have answered macOS's prompt since the last read.
        context.overview.rereadMicPermission()
        write(Keys.audioInput.assigning(audioInputSwitch.state == .on))
        refreshResolved()
        refreshAudio()
    }

    @objc private func audioOutputToggled() {
        write(Keys.audioOutput.assigning(audioOutputSwitch.state == .on))
    }

    @objc private func inputDevicesChanged() {
        guard
            let mode = inputDevicesPopUp.selectedItem?.representedObject as? VMInputDeviceMode
        else {
            #log(Self.logger, .fault, "Input devices popup selection carries no mode")
            assertionFailure("Input devices popup selection carries no mode")
            return
        }
        write(Keys.inputDevices.assigning(mode.rawValue))
    }

    @objc private func systemKeysChanged() {
        guard
            let mode = systemKeysPopUp.selectedItem?.representedObject as? VMSystemKeyForwarding
        else {
            #log(Self.logger, .fault, "System keys popup selection carries no mode")
            assertionFailure("System keys popup selection carries no mode")
            return
        }
        write(Keys.inputSystemKeys.assigning(mode.rawValue))
    }

    @objc private func serialRelayToggled() {
        write(Keys.serialSocket.assigning(serialRelaySwitch.state == .on))
    }

    @objc private func revealSerialLog() {
        NSWorkspace.shared.activateFileViewerSelecting([instance.serialLogURL])
    }

    @objc private func openMicPermissionSettings() {
        systemSettings.openMicrophonePrivacy()
    }

    /// Clamps a typed count to the framework's bounds and writes it, then
    /// shows what the VM holds.
    private func applyCPUFieldEdit() {
        if cpuField.holdsUserEdit {
            let clamped = VMResourceLimits.cpuCount.clamp(cpuField.integerValue)
            write(Keys.cpus.assigning(String(clamped)))
        }
        cpuField.showDiscardingEdit(String(instance.configuration.cpuCount))
        cpuStepper.integerValue = instance.configuration.cpuCount
    }

    /// ``applyCPUFieldEdit()`` for the memory field, which takes decimal
    /// gigabytes; text that names no size is dropped.
    private func applyMemoryFieldEdit() {
        if memoryField.holdsUserEdit, let typed = VMMemorySize(gibibytesText: memoryField.stringValue) {
            let clamped = VMResourceLimits.memorySize.clamp(typed)
            write(Keys.memory.assigning(clamped.gibibytesText))
        }
        showStoredMemorySize()
    }

    /// Ends any edit in the memory field and shows the size the VM holds.
    private func showStoredMemorySize() {
        memoryField.showDiscardingEdit(instance.configuration.memorySizeInGB.gibibytesText)
        memoryStepper.doubleValue = instance.configuration.memorySizeInGB.gibibytes
    }
}

private typealias Keys = VMConfigurationKeyRegistry

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
