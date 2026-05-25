import Cocoa
import os
import SwiftUI

/// AppKit container that layers pure-AppKit VM displays on top of an always-present SwiftUI hosting controller.
///
/// Each running VM that displays inline gets its own `VMDisplayBackingView`
/// (and thus its own `VZVirtualMachineView`). Switching VMs swaps visibility rather than
/// reassigning the `virtualMachine` property, which `VZVirtualMachineView` does not handle
/// correctly.
///
/// The SwiftUI layer is kept in the view hierarchy at all times so that SwiftUI-hosted alerts
/// (delete, force-stop, cancel) remain functional even while the VM display is showing.
@MainActor
final class DetailContainerViewController: NSViewController {
    private let viewModel: VMLibraryViewModel
    private var backingViews: [UUID: VMDisplayBackingView] = [:]
    private var activeBackingViewID: UUID?
    private let swiftUIHost: NSHostingController<MainDetailView>
    private var stateObservation: ObservationLoop?

    /// Drives the AppKit creation-wizard sheet.
    ///
    /// Presentation moved out of the SwiftUI `MainDetailView.sheet` into this
    /// AppKit host so the wizard is a pure-AppKit sheet on the main window.
    private let wizardPresenter = SheetPresenter()
    private var wizardObservation: ObservationLoop?

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

        self.view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateDisplayState()
        if stateObservation == nil { observeState() }
        if wizardObservation == nil { observeWizardPresentation() }
        // Handle the case where the flag was set before the window existed.
        syncWizardPresentation()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stateObservation?.cancel()
        stateObservation = nil
        wizardObservation?.cancel()
        wizardObservation = nil
        if wizardPresenter.isShown { wizardPresenter.close() }
        for id in Array(backingViews.keys) {
            removeBackingView(for: id)
        }
    }

    // MARK: - Backing View Management

    private func backingView(for instance: VMInstance) -> VMDisplayBackingView {
        if let existing = backingViews[instance.id] {
            return existing
        }

        let backing = VMDisplayBackingView()
        backing.isHidden = true
        let instanceID = instance.id
        backing.onResume = { [weak viewModel] in
            guard let viewModel,
                let target = viewModel.instances.first(where: { $0.id == instanceID })
            else { return }
            Task { await viewModel.resume(target) }
        }

        backing.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backing)
        NSLayoutConstraint.activate([
            backing.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backing.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            backing.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        backingViews[instance.id] = backing
        return backing
    }

    private func removeBackingView(for id: UUID) {
        guard let backing = backingViews.removeValue(forKey: id) else { return }
        backing.update(virtualMachine: nil, isPaused: false, transitionText: nil)
        backing.removeFromSuperview()
        if activeBackingViewID == id {
            activeBackingViewID = nil
        }
    }

    // MARK: - State Observation

    private func observeState() {
        stateObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.viewModel.selectedInstance
                _ = self.viewModel.selectedInstance?.status
                _ = self.viewModel.selectedInstance?.displayMode
                _ = self.viewModel.selectedInstance?.detailPaneMode
                _ = self.viewModel.selectedInstance?.virtualMachine
                // Track instances with backing views so we detect when they stop or leave inline mode.
                // Also track the instances array itself so we detect additions/removals.
                _ = self.viewModel.instances.count
                for id in self.backingViews.keys {
                    if let inst = self.viewModel.instances.first(where: { $0.id == id }) {
                        _ = inst.status
                        _ = inst.virtualMachine
                        _ = inst.displayMode
                    }
                }
            },
            apply: { [weak self] in
                self?.updateDisplayState()
            }
        )
    }

    // MARK: - Creation Wizard Presentation

    private func observeWizardPresentation() {
        wizardObservation = observeRecurring(
            track: { [weak self] in
                _ = self?.viewModel.showCreationWizard
            },
            apply: { [weak self] in
                self?.syncWizardPresentation()
            }
        )
    }

    private func syncWizardPresentation() {
        if viewModel.showCreationWizard {
            guard !wizardPresenter.isShown, let window = view.window else { return }
            let creationVM = VMCreationViewModel()
            let wizard = VMCreationWizardViewController(creationVM: creationVM)
            wizard.delegate = self
            wizardPresenter.onClose = { [weak self] in
                // Resetting the flag re-fires the observation; the `isShown`
                // guard above makes the resulting `syncWizardPresentation()` a
                // no-op (the sheet is already gone).
                self?.viewModel.showCreationWizard = false
            }
            wizardPresenter.show(content: wizard, in: window)
            Self.logger.notice("Presented creation wizard")
        } else if wizardPresenter.isShown {
            wizardPresenter.close()
        }
    }

    private func updateDisplayState() {
        // Evict backing views for VMs no longer running inline
        let activeInlineIDs = Set(
            viewModel.instances
                .filter {
                    $0.virtualMachine != nil && $0.displayMode == .inline
                        && $0.status.hasActiveDisplay
                }
                .map(\.id)
        )
        let staleIDs = backingViews.keys.filter { !activeInlineIDs.contains($0) }
        for id in staleIDs {
            removeBackingView(for: id)
            Self.logger.debug("Removed stale backing view for VM \(id)")
        }

        guard let instance = viewModel.selectedInstance,
            let vm = instance.virtualMachine,
            instance.displayMode == .inline,
            instance.status.hasActiveDisplay,
            instance.detailPaneMode == .display
        else {
            if let currentID = activeBackingViewID, let current = backingViews[currentID] {
                current.isHidden = true
                Self.logger.debug("VM display hidden — SwiftUI content visible")
            }
            activeBackingViewID = nil
            return
        }

        if let currentID = activeBackingViewID, currentID != instance.id,
            let current = backingViews[currentID]
        {
            current.isHidden = true
        }

        let backing = backingView(for: instance)
        if backing.isHidden {
            backing.isHidden = false
            Self.logger.debug("VM display shown for '\(instance.name, privacy: .public)'")
        }
        activeBackingViewID = instance.id

        backing.update(
            virtualMachine: vm,
            isPaused: instance.status == .paused,
            transitionText: instance.status.transitionLabel
        )
    }
}

// MARK: - VMCreationWizardViewControllerDelegate

extension DetailContainerViewController: VMCreationWizardViewControllerDelegate {
    func wizardDidCancel(_ vc: VMCreationWizardViewController) {
        wizardPresenter.close()
    }

    func wizardDidRequestCreate(
        _ vc: VMCreationWizardViewController,
        creationVM: VMCreationViewModel
    ) {
        // Keep the sheet up until creation completes, matching the prior
        // SwiftUI flow (`await createVM(from:); dismiss()`). Errors surface
        // via the view model's non-blocking error presentation.
        Task { [weak self] in
            await self?.viewModel.createVM(from: creationVM)
            self?.wizardPresenter.close()
        }
    }
}
