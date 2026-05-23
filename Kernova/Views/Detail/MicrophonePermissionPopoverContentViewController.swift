import AppKit

/// Popover content shown when the user clicks the info-circle on the
/// "Microphone permission is denied" warning bar in the Audio settings.
///
/// Explains why Kernova needs the permission and walks the user through
/// the steps to grant it via System Settings. Unique among the AppKit
/// popovers in this codebase because it carries structure (a horizontal
/// divider, a sub-headline, three numbered steps with inline bold) that
/// doesn't fit the generic `InfoPopoverContentViewController` paragraph
/// shape — built as its own concrete subclass per the per-popover-subclass
/// pattern.
@MainActor
final class MicrophonePermissionPopoverContentViewController: NSViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MicrophonePermissionPopoverContentViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CalloutStyle.verticalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(makeCalloutHeadline("Microphone Permission"))
        stack.addArrangedSubview(
            makeCalloutBody(
                "Kernova needs microphone permission to pass your mic input to virtual machines.",
                color: .labelColor
            )
        )
        stack.addArrangedSubview(makeDivider())
        stack.addArrangedSubview(makeSubheadline("How to enable"))
        stack.addArrangedSubview(makeStep(number: 1, lead: "Open ", bold: "System Settings"))
        stack.addArrangedSubview(
            makeStep(number: 2, lead: "Go to ", bold: "Privacy & Security → Microphone")
        )
        stack.addArrangedSubview(
            makeStep(number: 3, lead: "Enable the toggle for ", bold: "Kernova")
        )
        stack.addArrangedSubview(
            makeCalloutBody("You will need to restart Kernova after granting permission.")
        )

        container.addSubview(stack)
        let padding = CalloutStyle.padding
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
            container.widthAnchor.constraint(equalToConstant: CalloutStyle.width),
        ])

        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let fittingSize = view.fittingSize
        if preferredContentSize != fittingSize {
            preferredContentSize = fittingSize
        }
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

    /// `.subheadline`-styled, medium-weight label used to break the popover
    /// into named regions (e.g. "How to enable").
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

    /// Numbered-step row with a bold-emphasized phrase.
    ///
    /// Renders as `"<number>. <lead><bold>"` where `bold` is the app or
    /// setting name to emphasize — mirrors the SwiftUI predecessor's
    /// inline `**bold**` markdown by building an `NSAttributedString`
    /// with a bold run on the trailing portion.
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
