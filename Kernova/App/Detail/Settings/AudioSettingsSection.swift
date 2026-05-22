import AVFoundation
import AppKit

/// Microphone toggle + permission-aware banners.
@MainActor
final class AudioSettingsSection: NSObject {
    let section = SettingsSection(title: "Audio", lockable: true)

    private let instance: VMInstance
    private let viewModel: VMLibraryViewModel
    private let isReadOnly: Bool

    private let micToggle = NSSwitch()
    private let micNotDeterminedLabel = NSTextField(labelWithString: "")
    private let micDeniedBanner = NSStackView()
    private var micPermission: AVAuthorizationStatus = .notDetermined

    private var observation: ObservationLoop?

    init(instance: VMInstance, viewModel: VMLibraryViewModel, isReadOnly: Bool) {
        self.instance = instance
        self.viewModel = viewModel
        self.isReadOnly = isReadOnly
        super.init()
        configure()
    }

    func startObserving() {
        observation = observeRecurring(
            track: { [weak self] in _ = self?.instance.configuration.microphoneEnabled },
            apply: { [weak self] in self?.apply() }
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive(_:)),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        apply()
    }

    func stopObserving() {
        observation?.cancel()
        observation = nil
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    // MARK: - Internals

    private func configure() {
        micToggle.target = self
        micToggle.action = #selector(micToggleChanged(_:))
        micToggle.isEnabled = !isReadOnly

        micNotDeterminedLabel.stringValue =
            "macOS will ask for microphone permission the first time a VM uses it."
        micNotDeterminedLabel.font = .preferredFont(forTextStyle: .caption1)
        micNotDeterminedLabel.textColor = .secondaryLabelColor
        micNotDeterminedLabel.isHidden = true
        micNotDeterminedLabel.maximumNumberOfLines = 0
        micNotDeterminedLabel.lineBreakMode = .byWordWrapping
        micNotDeterminedLabel.translatesAutoresizingMaskIntoConstraints = false
        micNotDeterminedLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        micNotDeterminedLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let denyIcon = NSImageView(
            image: .systemSymbol("exclamationmark.triangle.fill", accessibilityDescription: ""))
        denyIcon.contentTintColor = .systemRed
        let denyLabel = NSTextField(
            wrappingLabelWithString:
                "Microphone permission is denied. Enable it in System Settings for Kernova to pass your microphone to VMs."
        )
        denyLabel.font = .preferredFont(forTextStyle: .caption1)
        denyLabel.maximumNumberOfLines = 0
        denyLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        denyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let openSettings = NSButton(
            title: "Open Privacy Settings", target: self,
            action: #selector(openMicSettings(_:)))
        openSettings.controlSize = .small
        micDeniedBanner.setViews([denyIcon, denyLabel, openSettings], in: .leading)
        micDeniedBanner.orientation = .horizontal
        micDeniedBanner.alignment = .centerY
        micDeniedBanner.spacing = 8
        micDeniedBanner.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        micDeniedBanner.wantsLayer = true
        micDeniedBanner.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.1).cgColor
        micDeniedBanner.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.3).cgColor
        micDeniedBanner.layer?.borderWidth = 1
        micDeniedBanner.layer?.cornerRadius = 8
        micDeniedBanner.isHidden = true
        micDeniedBanner.translatesAutoresizingMaskIntoConstraints = false

        let grid = makeFormGrid([
            FormRow("Microphone", control: micToggle)
        ])
        let wrapper = NSStackView(views: [grid, micNotDeterminedLabel, micDeniedBanner])
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        wrapper.spacing = 8
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        // RATIONALE: NSStackView `.leading` alignment doesn't stretch
        // arranged subviews. All three children need wrapper width:
        // - The grid container needs wrapper-width to center its grid
        //   horizontally (see makeFormGrid).
        // - The two aux views need wrapper-width so wrap-by-word and
        //   banner-background math compute against the section-card width.
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            micNotDeterminedLabel.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            micNotDeterminedLabel.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            micDeniedBanner.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            micDeniedBanner.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])
        section.setBody(wrapper)
        section.setLocked(isReadOnly)
        let isLinux = instance.configuration.guestOS == .linux
        section.setInfoHelp(title: "Audio") {
            var paragraphs = [
                "Exposes a VirtioSound device. Speaker output is always enabled; toggle the"
                    + " microphone to grant the guest access to your host mic."
            ]
            if isLinux {
                paragraphs.append(
                    "Requires Linux kernel 5.14 or newer to detect the VirtioSound device."
                )
            }
            return calloutParagraphs(paragraphs)
        }
    }

    private func apply() {
        micToggle.state = instance.configuration.microphoneEnabled ? .on : .off
        refreshMicPermission()
    }

    private func refreshMicPermission() {
        micPermission = AVCaptureDevice.authorizationStatus(for: .audio)
        let enabled = instance.configuration.microphoneEnabled
        micNotDeterminedLabel.isHidden = !(enabled && micPermission == .notDetermined)
        micDeniedBanner.isHidden = !(enabled && (micPermission == .denied || micPermission == .restricted))
    }

    @objc private func micToggleChanged(_ sender: NSSwitch) {
        viewModel.updateConfiguration(of: instance) { $0.microphoneEnabled = sender.state == .on }
        refreshMicPermission()
    }

    @objc private func openMicSettings(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func applicationDidBecomeActive(_ note: Notification) {
        refreshMicPermission()
    }
}
