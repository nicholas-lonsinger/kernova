import AppKit
import SwiftUI

/// Transient hosting controller that wraps the remaining SwiftUI surface
/// (`VMDetailView` — settings + install progress + lifecycle alerts) inside
/// the AppKit detail router.
///
/// Exists for Phase 2 of the SwiftUI-to-AppKit detail-pane conversion. Phases
/// 3–5 progressively shrink the hosted SwiftUI tree until this controller
/// has nothing left to host, at which point it is deleted (Phase 5).
@MainActor
final class SettingsHostViewController: NSViewController {
    private let hostingController: NSHostingController<VMDetailView>

    init(instance: VMInstance, viewModel: VMLibraryViewModel) {
        self.hostingController = NSHostingController(
            rootView: VMDetailView(instance: instance, viewModel: viewModel)
        )
        hostingController.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
        addChild(hostingController)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsHostViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()
        container.addFullSizeSubview(hostingController.view)
        view = container
    }
}
