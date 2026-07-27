import AppKit

/// One paragraph rendered inside an ``InfoPopoverContentViewController``.
enum InfoPopoverParagraph: Equatable {
    /// Plain wrapping body text in the shared `.callout` style.
    case body(String)
    /// Monospaced, selectable text for shell commands and similar
    /// copy-worthy snippets.
    case code(String)
}

/// Popover content for an ``InfoButtonView``.
///
/// No headline is shown — the surrounding button carries the section or control
/// name as its hover tooltip and VoiceOver label.
@MainActor
final class InfoPopoverContentViewController: NSViewController {
    /// Paragraphs rendered, in order.
    let paragraphs: [InfoPopoverParagraph]

    init(paragraphs: [InfoPopoverParagraph]) {
        self.paragraphs = paragraphs
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InfoPopoverContentViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CalloutStyle.verticalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        for paragraph in paragraphs {
            switch paragraph {
            case .body(let text):
                stack.addArrangedSubview(makeCalloutBody(text))
            case .code(let text):
                stack.addArrangedSubview(makeCalloutCode(text))
            }
        }

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
        // Re-pin so `NSPopover` resizes its frame to the measured stack
        // height under the configured width.
        let fittingSize = view.fittingSize
        if preferredContentSize != fittingSize {
            preferredContentSize = fittingSize
        }
    }
}
