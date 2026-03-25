import Cocoa
import os
import SwiftUI

/// AppKit container that layers a pure-AppKit VM display on top of an always-present SwiftUI
/// hosting controller. When a VM is running inline, `VMDisplayBackingView` covers the SwiftUI
/// content; otherwise it is hidden and the SwiftUI detail views are visible.
///
/// The SwiftUI layer is kept in the view hierarchy at all times so that SwiftUI-hosted alerts
/// (delete, force-stop, cancel) remain functional even while the VM display is showing.
@MainActor
final class DetailContainerViewController: NSViewController {

    private let viewModel: VMLibraryViewModel
    private let displayBackingView = VMDisplayBackingView()
    private let swiftUIHost: NSHostingController<MainDetailView>
    private var observing = false

    private static let logger = Logger(subsystem: "com.kernova.app", category: "DetailContainerVC")

    // MARK: - Init

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
        self.swiftUIHost = NSHostingController(rootView: MainDetailView(viewModel: viewModel))
        swiftUIHost.sizingOptions = []

        super.init(nibName: nil, bundle: nil)

        addChild(swiftUIHost)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        container.addFullSizeSubview(swiftUIHost.view)

        displayBackingView.isHidden = true
        container.addFullSizeSubview(displayBackingView)

        displayBackingView.onResume = { [weak viewModel] in
            guard let viewModel, let instance = viewModel.selectedInstance else { return }
            Task { await viewModel.resume(instance) }
        }

        self.view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if !observing { observeState() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        observing = false
    }

    // MARK: - State Observation

    private func observeState() {
        observing = true
        withObservationTracking {
            _ = self.viewModel.selectedInstance
            _ = self.viewModel.selectedInstance?.status
            _ = self.viewModel.selectedInstance?.displayMode
            _ = self.viewModel.selectedInstance?.virtualMachine
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.observing else { return }
                self.updateDisplayState()
                self.observeState()
            }
        }
    }

    private func updateDisplayState() {
        guard let instance = viewModel.selectedInstance,
              let vm = instance.virtualMachine,
              instance.displayMode == .inline,
              instance.status == .running || instance.status == .paused
                  || instance.status == .saving || instance.status == .restoring
        else {
            if !displayBackingView.isHidden {
                displayBackingView.isHidden = true
                displayBackingView.update(virtualMachine: nil, isPaused: false, transitionText: nil)
                Self.logger.debug("VM display hidden — SwiftUI content visible")
            }
            return
        }

        if displayBackingView.isHidden {
            displayBackingView.isHidden = false
            Self.logger.debug("VM display shown for '\(instance.name, privacy: .public)'")
        }

        displayBackingView.update(
            virtualMachine: vm,
            isPaused: instance.status == .paused,
            transitionText: instance.status.transitionLabel
        )
    }
}
