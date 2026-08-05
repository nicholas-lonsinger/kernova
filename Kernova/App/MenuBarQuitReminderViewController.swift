import AppKit

/// Content for the transient popover the menu-bar status item shows after a soft
/// quit — a reminder that Kernova is still resident, with a "Stop Reminding Me"
/// opt-out.
///
/// The opt-out only invokes `onStopReminding`; the presenter
/// (`HostAgentStatusItemController`) owns the preference write and the close.
@MainActor
final class MenuBarQuitReminderViewController: NSViewController {
    private let onStopReminding: () -> Void

    init(onStopReminding: @escaping () -> Void) {
        self.onStopReminding = onStopReminding
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MenuBarQuitReminderViewController does not support NSCoder")
    }

    override func loadView() {
        let title = makeCalloutHeadline("Kernova is still running in the menu bar.")
        let body = makeCalloutBody(
            "Your virtual machines keep running. Quit Kernova fully from this menu-bar icon.")
        let stopReminding = makeLinkButton(
            "Stop Reminding Me", target: self, action: #selector(stopRemindingTapped))

        let stack = NSStackView(views: [title, body, stopReminding])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CalloutStyle.verticalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
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
        // Re-pin so `NSPopover` resizes its frame to the measured stack height
        // under the configured width.
        let fittingSize = view.fittingSize
        if preferredContentSize != fittingSize {
            preferredContentSize = fittingSize
        }
    }

    @objc private func stopRemindingTapped() {
        onStopReminding()
    }
}
