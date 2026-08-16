import AppKit

/// Content for the transient popover the menu-bar status item shows when a
/// clipboard transfer was refused and no clipboard window was open to say so.
///
/// The link only invokes `onOpenClipboardWindow`; the presenter
/// (`HostAgentStatusItemController`) owns the dismissal and the window summons.
@MainActor
final class ClipboardNoticeViewController: NSViewController {
    private let wording: ClipboardTransferWording
    private let onOpenClipboardWindow: () -> Void

    init(
        wording: ClipboardTransferWording, onOpenClipboardWindow: @escaping () -> Void
    ) {
        self.wording = wording
        self.onOpenClipboardWindow = onOpenClipboardWindow
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClipboardNoticeViewController does not support NSCoder")
    }

    override func loadView() {
        var rows: [NSView] = [
            makeCalloutHeadline(wording.headline),
            makeCalloutBody(wording.message),
        ]
        if wording.mentionsMacClipboardKept {
            rows.append(makeCalloutBody("The Mac clipboard still has its previous contents."))
        }
        rows.append(
            makeLinkButton(
                "Open Clipboard Window", target: self, action: #selector(openClipboardTapped)))

        installCalloutStack(rows: rows)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncCalloutContentSize()
    }

    @objc private func openClipboardTapped() {
        onOpenClipboardWindow()
    }
}
