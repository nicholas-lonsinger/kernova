import AppKit
import KernovaAppKitShared
import KernovaCore

/// Content for the transient popover the menu-bar status item shows when a
/// clipboard transfer was refused; the presenter
/// (`HostAgentStatusItemController`) owns its dismissal.
@MainActor
final class ClipboardNoticeViewController: NSViewController {
    private let wording: ClipboardTransferWording

    init(wording: ClipboardTransferWording) {
        self.wording = wording
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
        installCalloutStack(rows: rows)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncCalloutContentSize()
    }
}
