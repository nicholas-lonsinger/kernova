import AppKit
import KernovaCore

/// The radio group an install on a Linux guest asks with, and beneath it the
/// command that installs the selected choice.
///
/// The choice is this view's own state, read when the user answers.
@MainActor
final class LinuxAgentInstallChoiceView: NSView {
    /// Wide enough for the install command to wrap over a few lines; an
    /// `NSAlert` gives its accessory view whatever width the view asks for.
    private static let contentWidth: CGFloat = 400

    private(set) var choice: LinuxAgentInstallChoice
    private(set) var radios: [NSButton] = []
    private let precondition = NSTextField(wrappingLabelWithString: "")
    let commandLabel = NSTextField(wrappingLabelWithString: "")
    let headlessLabel = NSTextField(wrappingLabelWithString: "")

    init(initial: LinuxAgentInstallChoice) {
        choice = initial
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // Radios sharing a superview and an action are one group to AppKit.
        radios = LinuxAgentInstallChoice.allCases.enumerated().map { index, choice in
            let radio = NSButton(radioButtonWithTitle: choice.title, target: self, action: #selector(choose(_:)))
            radio.tag = index
            return radio
        }
        let group = NSStackView(views: radios)
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = Spacing.small

        let callout = NSFont.preferredFont(forTextStyle: .callout)
        precondition.font = callout
        commandLabel.font = .monospacedSystemFont(ofSize: callout.pointSize, weight: .regular)
        commandLabel.isSelectable = true
        headlessLabel.font = .preferredFont(forTextStyle: .caption1)
        headlessLabel.textColor = .secondaryLabelColor
        headlessLabel.isSelectable = true
        for label in [precondition, commandLabel, headlessLabel] {
            label.preferredMaxLayoutWidth = Self.contentWidth
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.standard
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Top gravity: the frame is sized for the longest steps, and a shorter
        // choice's leave room beneath rather than float.
        stack.setViews([group, precondition, commandLabel, headlessLabel], in: .top)
        stack.setCustomSpacing(Spacing.relaxed + Spacing.small, after: group)
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.contentWidth),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        resolveFrame()
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LinuxAgentInstallChoiceView does not support NSCoder")
    }

    @objc private func choose(_ sender: NSButton) {
        let choices = LinuxAgentInstallChoice.allCases
        guard choices.indices.contains(sender.tag) else { return }
        choice = choices[sender.tag]
        apply()
    }

    private func apply() {
        for (radio, choice) in zip(radios, LinuxAgentInstallChoice.allCases) {
            radio.state = choice == self.choice ? .on : .off
        }
        show(AppAlertConfigurations.linuxAgentInstallSteps(for: choice))
    }

    private func show(_ steps: (precondition: String, command: String, headless: String)) {
        precondition.stringValue = steps.precondition
        commandLabel.stringValue = steps.command
        headlessLabel.stringValue = steps.headless
    }

    /// Sizes the frame for the tallest choice's steps: an `NSAlert` lays its
    /// accessory view out from the frame it has when the sheet is built, and
    /// never again as the selection changes what the labels hold.
    private func resolveFrame() {
        var size = NSSize.zero
        for choice in LinuxAgentInstallChoice.allCases {
            show(AppAlertConfigurations.linuxAgentInstallSteps(for: choice))
            layoutSubtreeIfNeeded()
            size.width = max(size.width, fittingSize.width)
            size.height = max(size.height, fittingSize.height)
        }
        frame = NSRect(origin: .zero, size: size)
    }
}

/// The question an install on a Linux guest asks before anything is attached.
@MainActor
enum LinuxAgentInstallChoiceAlert {
    /// The alert asking what to install on `vm`, starting on `initial`, its
    /// buttons from `configurations` and its command copied through `copy`.
    static func configuration(
        for vm: VMInstance, initial: LinuxAgentInstallChoice, configurations: AppAlertConfigurations,
        copy: @escaping (String) -> Void
    ) -> SheetAlert {
        let view = LinuxAgentInstallChoiceView(initial: initial)
        return SheetAlert(
            configurations.linuxAgentInstallChoiceConfig(vm, choice: { [view] in view.choice }, copy: copy),
            accessoryView: view)
    }
}
