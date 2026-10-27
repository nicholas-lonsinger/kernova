import AppKit
import KernovaAppKitShared

/// Content for the callout the status item shows when a clipboard gesture made
/// in this guest ends in a notice: the dropdown's own line for it.
@MainActor
final class AgentClipboardNoticeViewController: NSViewController {
    private let line: String

    init(line: String) {
        self.line = line
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AgentClipboardNoticeViewController does not support NSCoder")
    }

    override func loadView() {
        installCalloutStack(rows: [makeCalloutBody(line, color: .labelColor)])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        syncCalloutContentSize()
    }
}
