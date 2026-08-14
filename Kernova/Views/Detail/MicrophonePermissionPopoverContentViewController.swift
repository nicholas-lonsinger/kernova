import AppKit

/// Popover content shown when the user clicks the info-circle on the
/// "Microphone permission is denied" warning bar in the Audio settings.
///
/// Explains why Kernova needs the permission and walks the user through
/// the steps to grant it via System Settings.
@MainActor
final class MicrophonePermissionPopoverContentViewController: NSViewController {
    private let systemSettings: SystemSettingsLink

    init(systemSettings: SystemSettingsLink = SystemSettingsLink()) {
        self.systemSettings = systemSettings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MicrophonePermissionPopoverContentViewController does not support NSCoder")
    }

    override func loadView() {
        installCalloutStack(rows: [
            makeCalloutHeadline("Microphone Permission"),
            makeCalloutBody(
                "Kernova needs microphone permission to pass your mic input to virtual machines.",
                color: .labelColor
            ),
            makeOpenSettingsButton(),
            makeDivider(),
            makeSubheadline("How to enable"),
            makeStep(number: 1, lead: "Open ", bold: "System Settings"),
            makeStep(number: 2, lead: "Go to ", bold: "Privacy & Security → Microphone"),
            makeStep(number: 3, lead: "Enable the toggle for ", bold: "Kernova"),
            makeCalloutBody("You will need to restart Kernova after granting permission."),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncCalloutContentSize()
    }

    private func makeOpenSettingsButton() -> NSButton {
        let button = NSButton(
            title: "Open System Settings", target: self, action: #selector(openSettingsTapped))
        button.bezelStyle = .push
        button.keyEquivalent = "\r"
        return button
    }

    @objc private func openSettingsTapped() {
        systemSettings.openMicrophonePrivacy()
    }

    /// Full-width horizontal `NSBox` separator.
    ///
    /// Pinned to `CalloutStyle.bodyWidth` because the parent `NSStackView`
    /// uses leading alignment and would otherwise leave the box at its
    /// intrinsic (zero) width.
    private func makeDivider() -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: CalloutStyle.bodyWidth).isActive = true
        return divider
    }

    private func makeSubheadline(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize,
            weight: .medium
        )
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = CalloutStyle.bodyWidth
        label.isSelectable = false
        return label
    }

    /// Numbered-step row rendered as `"<number>. <lead><bold>"`.
    private func makeStep(number: Int, lead: String, bold: String) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        let font = CalloutStyle.bodyFont
        let boldFont = NSFont.boldSystemFont(ofSize: font.pointSize)
        let attributed = NSMutableAttributedString(
            string: "\(number). \(lead)",
            attributes: [.font: font, .foregroundColor: NSColor.labelColor]
        )
        attributed.append(
            NSAttributedString(
                string: bold,
                attributes: [.font: boldFont, .foregroundColor: NSColor.labelColor]
            )
        )
        label.attributedStringValue = attributed
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = CalloutStyle.bodyWidth
        label.isSelectable = false
        return label
    }
}
