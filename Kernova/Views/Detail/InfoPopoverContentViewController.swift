import AppKit

/// One paragraph rendered inside an ``InfoPopoverContentViewController``.
enum InfoPopoverParagraph: Equatable {
    /// Wrapping body text in the shared `.callout` style, in which a
    /// backtick-delimited span renders in ``CalloutStyle/codeFont`` without
    /// its backticks.
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
                let label = makeCalloutBody(text)
                label.attributedStringValue = Self.renderedBody(text)
                stack.addArrangedSubview(label)
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

    /// `text` in the body style, each backtick-delimited span set in the code
    /// font with its backticks dropped; an unpaired backtick stays as written.
    static func renderedBody(_ text: String) -> NSAttributedString {
        var parts = text.components(separatedBy: "`")
        if parts.count.isMultiple(of: 2), let unpaired = parts.popLast() {
            parts[parts.count - 1] += "`" + unpaired
        }
        let rendered = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            let font = index.isMultiple(of: 2) ? CalloutStyle.bodyFont : CalloutStyle.codeFont
            rendered.append(
                NSAttributedString(
                    string: part,
                    attributes: [.font: font, .foregroundColor: CalloutStyle.bodyColor]))
        }
        return rendered
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
