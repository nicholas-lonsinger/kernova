import AppKit
import KernovaAppKitShared

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

    /// The reminder's title, which Settings ▸ Reminders shows beside its switch.
    static let title = "Kernova is still running in the menu bar."
    /// The reminder's text, which Settings ▸ Reminders shows beside its switch.
    static let text = "Your virtual machines keep running. Quit Kernova fully from this menu bar item."

    override func loadView() {
        installCalloutStack(rows: [
            makeCalloutHeadline(Self.title),
            makeCalloutBody(Self.text),
            makeLinkButton(
                "Stop Reminding Me", target: self, action: #selector(stopRemindingTapped)),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncCalloutContentSize()
    }

    @objc private func stopRemindingTapped() {
        onStopReminding()
    }
}
