import AppKit
import KernovaCommandModel

/// How the user ends a VM's process Kernova is waiting on: the explanation,
/// the Terminal command, and a button that copies the command — hidden while
/// there is no ``instruction``.
@MainActor
final class VMProcessEndInstructionView: NSStackView {
    /// What the view shows, or `nil` to hide it.
    var instruction: VMProcessEndInstruction? {
        didSet {
            guard instruction != oldValue else { return }
            apply()
        }
    }

    private let explanationLabel = NSTextField(wrappingLabelWithString: "")
    private let commandLabel = NSTextField(wrappingLabelWithString: "")
    private let copyButton = NSButton(title: "Copy Command", target: nil, action: nil)
    private let pasteboard: NSPasteboard

    private static let width: CGFloat = 440

    /// A view whose text is drawn in `textColor`, copying to `pasteboard`.
    init(textColor: NSColor, pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .centerX
        spacing = Spacing.small

        explanationLabel.font = .preferredFont(forTextStyle: .callout)
        explanationLabel.textColor = textColor
        explanationLabel.alignment = .center
        explanationLabel.isSelectable = false
        explanationLabel.preferredMaxLayoutWidth = Self.width

        commandLabel.font = .monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        commandLabel.textColor = textColor
        commandLabel.alignment = .center
        commandLabel.isSelectable = true
        commandLabel.preferredMaxLayoutWidth = Self.width

        copyButton.bezelStyle = .push
        copyButton.target = self
        copyButton.action = #selector(copyCommand)

        setViews([explanationLabel, commandLabel, copyButton], in: .center)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMProcessEndInstructionView does not support NSCoder")
    }

    private func apply() {
        isHidden = instruction == nil
        explanationLabel.stringValue = instruction?.explanation ?? ""
        commandLabel.stringValue = instruction?.command ?? ""
    }

    @objc private func copyCommand() {
        guard let command = instruction?.command else { return }
        copyToPasteboard(command, to: pasteboard)
    }
}
