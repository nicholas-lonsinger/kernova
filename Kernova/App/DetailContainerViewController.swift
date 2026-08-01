import Cocoa
import os

/// AppKit container that layers pure-AppKit VM displays on top of the detail
/// content (the empty state, or the per-VM detail router).
///
/// Each running VM that displays inline gets its own `VMDisplayBackingView` (and
/// thus its own `VZVirtualMachineView`). Switching VMs swaps visibility rather
/// than reassigning the `virtualMachine` property, which `VZVirtualMachineView`
/// does not handle correctly. The detail content layer stays in the view
/// hierarchy at all times beneath the backing views.
@MainActor
final class DetailContainerViewController: NSViewController {
    private let viewModel: VMLibraryViewModel
    private var backingViews: [UUID: VMDisplayBackingView] = [:]
    private var activeBackingViewID: UUID?
    private var stateObservation: ObservationLoop?

    // MARK: - Detail content layer

    private let contentContainer = NSView()
    private lazy var emptyStateView = DetailEmptyStateView { [weak self] in
        self?.presentCreationWizard()
    }
    private var routerVC: VMDetailRouterViewController?
    private var currentContentView: NSView?
    private var displayedInstanceID: UUID?

    /// Presents the lifecycle confirmation alerts and the delete sheet.
    private let alertsPresenter: DetailAlertsPresenter

    /// Drives the AppKit creation-wizard sheet.
    private let wizardPresenter = SheetPresenter()
    /// Set when a wizard presentation is requested before the window exists;
    /// `viewDidAppear` honors it once the window is available.
    private var pendingWizard = false

    private static let logger = Logger(subsystem: "app.kernova", category: "DetailContainerVC")

    // MARK: - Init

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
        self.alertsPresenter = DetailAlertsPresenter(viewModel: viewModel)
        super.init(nibName: nil, bundle: nil)
        viewModel.presenter = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(contentContainer)
        NSLayoutConstraint.activate([
            contentContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            // Pin the top to the safe area so detail content clears the
            // full-size-content window's toolbar.
            contentContainer.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
        ])

        self.view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateContent()
        updateDisplayState()
        if stateObservation == nil { observeState() }
        if let window = view.window { alertsPresenter.start(window: window) }
        if pendingWizard { presentCreationWizard() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stateObservation?.cancel()
        stateObservation = nil
        alertsPresenter.stop()
        if wizardPresenter.isShown { wizardPresenter.close() }
        for id in Array(backingViews.keys) {
            removeBackingView(for: id)
        }
    }

    // MARK: - Detail content (empty state ⇆ router)

    private func updateContent() {
        if let selected = viewModel.selectedInstance {
            let router: VMDetailRouterViewController
            if let existing = routerVC {
                router = existing
            } else {
                router = VMDetailRouterViewController(instance: selected, viewModel: viewModel)
                addChild(router)
                routerVC = router
            }
            if displayedInstanceID != selected.id {
                displayedInstanceID = selected.id
                router.reconfigure(instance: selected, viewModel: viewModel)
            }
            showContentView(router.view)
        } else {
            displayedInstanceID = nil
            showContentView(emptyStateView)
        }
    }

    private func showContentView(_ newView: NSView) {
        guard currentContentView !== newView else { return }
        currentContentView?.removeFromSuperview()
        contentContainer.addFullSizeSubview(newView)
        currentContentView = newView
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
        backing.detach()
        backing.removeFromSuperview()
        if activeBackingViewID == id {
            activeBackingViewID = nil
        }
    }

    // MARK: - Display Boot Geometry

    /// The area an inline display will fill, or `nil` while the pane has no
    /// window or has not been laid out yet.
    ///
    /// Measures `contentContainer`, which carries the same top-safe-area
    /// constraints a backing view gets.
    func displayBootSurface() -> DisplayBootSurface? {
        guard let window = view.window else { return nil }
        let size = contentContainer.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        return DisplayBootSurface(pointSize: size, backingScaleFactor: window.backingScaleFactor)
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
                _ = self.viewModel.selectedInstance?.configuration.displayAutoResizes
                // Track instances with backing views so a stop or a move out of
                // inline mode is detected, and the array itself for adds/removes.
                _ = self.viewModel.instances.count
                for id in self.backingViews.keys {
                    if let inst = self.viewModel.instances.first(where: { $0.id == id }) {
                        _ = inst.status
                        _ = inst.virtualMachine
                        _ = inst.displayMode
                        _ = inst.configuration.displayAutoResizes
                    }
                }
            },
            apply: { [weak self] in
                self?.updateContent()
                self?.updateDisplayState()
            }
        )
    }

    private func updateDisplayState() {
        // Ahead of the early return below: a hidden backing view stays attached and
        // constrained, so a VM whose Settings pane is up still reconfigures its
        // guest on every window resize unless the toggle reaches it here.
        for (id, backing) in backingViews {
            guard let instance = viewModel.instances.first(where: { $0.id == id }) else { continue }
            backing.apply(
                automaticallyReconfiguresDisplay: instance.configuration.displayAutoResizes)
        }

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
                Self.logger.debug("VM display hidden — detail content visible")
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
            transitionText: instance.status.transitionLabel,
            automaticallyReconfiguresDisplay: instance.configuration.displayAutoResizes
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
        // Keep the sheet up until creation completes: on failure the error is
        // presented on the wizard's own window, so the global alerts presenter on
        // this same window can't race the still-open wizard sheet.
        Task { [weak self] in
            guard let self else { return }
            switch await self.viewModel.createVM(from: creationVM) {
            case .success:
                self.wizardPresenter.close()
            case .failure(let error):
                vc.presentCreationFailure(message: error.localizedDescription)
            }
        }
    }
}

// MARK: - VMLibraryPresenting

extension DetailContainerViewController: VMLibraryPresenting {
    func presentError(_ message: String, title: String) {
        alertsPresenter.presentError(message, title: title)
    }

    func presentStartFailedAttachment(_ failure: StartFailedAttachment, for instance: VMInstance) {
        alertsPresenter.presentStartFailedAttachment(failure, for: instance)
    }

    func presentDeleteSheet(for instance: VMInstance, permanently: Bool) {
        alertsPresenter.presentDeleteSheet(for: instance, permanently: permanently)
    }

    func presentForceStop(for instance: VMInstance) {
        alertsPresenter.presentForceStop(for: instance)
    }

    func presentRecoveryBoot(for instance: VMInstance) {
        alertsPresenter.presentRecoveryBoot(for: instance)
    }

    func presentStopPaused(for instance: VMInstance) {
        alertsPresenter.presentStopPaused(for: instance)
    }

    func presentCancelPreparing(for instance: VMInstance) {
        alertsPresenter.presentCancelPreparing(for: instance)
    }

    func presentInstallerMounted(vmName: String, purpose: GuestAgentInstallerPurpose) {
        alertsPresenter.presentInstallerMounted(vmName: vmName, purpose: purpose)
    }

    func presentCreationWizard() {
        guard !wizardPresenter.isShown else { return }
        guard let window = view.window else {
            pendingWizard = true
            return
        }
        pendingWizard = false
        let creationVM = VMCreationViewModel()
        let wizard = VMCreationWizardViewController(creationVM: creationVM)
        wizard.delegate = self
        wizardPresenter.show(content: wizard, in: window)
        Self.logger.notice("Presented creation wizard")
    }
}
