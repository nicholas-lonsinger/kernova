import AppKit
import os

/// AppKit detail-pane router.
///
/// Observes the library view model's `selectedInstance`, `status`,
/// `displayMode`, `detailPaneMode`, and global modal flags, and swaps the
/// active child view controller between:
///
/// * ``EmptyStateViewController`` — no VM selected.
/// * ``PreparingProgressViewController`` — `preparingState != nil`.
/// * ``TransitionProgressViewController`` — lifecycle transitions
///   (starting, stopping, pausing, resuming, installing without progress).
/// * ``ConsolePlaceholderViewController`` — running VMs in non-settings
///   `detailPaneMode` (display, popped-out, fullscreen, suspended).
/// * ``SettingsHostViewController`` — anything else (settings form, install
///   progress, lifecycle alerts) — currently still SwiftUI-hosted; Phases
///   3–5 of the conversion shrink this further.
///
/// Replaces the SwiftUI `MainDetailView` previously hosted by
/// `DetailContainerViewController`. The two global modal alerts that
/// `MainDetailView` owned (error + installer-mounted) are presented here
/// via ``AlertPresenter``.
@MainActor
final class DetailRouterViewController: NSViewController {
    private static let logger = Logger(subsystem: "com.kernova.app", category: "DetailRouterVC")

    private let viewModel: VMLibraryViewModel
    private var routerObservation: ObservationLoop?
    private var errorObserver: ObservationLoop?
    private var installerMountedObserver: ObservationLoop?
    private var currentChild: NSViewController?

    /// The ID of the instance the current child was built for, so a sidebar
    /// switch on the same VM state still produces a fresh child VC (matching
    /// the SwiftUI `.id(...)` identity-reset behavior of `MainDetailView`).
    private var currentChildInstanceID: UUID?

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DetailRouterViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()
        view = container
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if routerObservation == nil { observeRoutingState() }
        if errorObserver == nil { observeErrorAlert() }
        if installerMountedObserver == nil { observeInstallerMountedAlert() }
        refresh()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        routerObservation?.cancel()
        routerObservation = nil
        errorObserver?.cancel()
        errorObserver = nil
        installerMountedObserver?.cancel()
        installerMountedObserver = nil
    }

    // MARK: - Routing observation

    private func observeRoutingState() {
        routerObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.viewModel.selectedID
                _ = self.viewModel.selectedInstance
                if let instance = self.viewModel.selectedInstance {
                    _ = instance.status
                    _ = instance.displayMode
                    _ = instance.detailPaneMode
                    _ = instance.preparingState
                    _ = instance.installState
                }
            },
            apply: { [weak self] in self?.refresh() }
        )
    }

    // MARK: - Global alerts

    private func observeErrorAlert() {
        errorObserver = observeModalFlag(
            { [weak viewModel] in viewModel?.showError ?? false },
            present: { [weak self] in self?.presentErrorAlert() }
        )
    }

    private func presentErrorAlert() {
        guard let window = view.window else { return }
        let message = viewModel.errorMessage ?? ""
        AlertPresenter.present(
            in: window,
            title: "Error",
            message: message,
            style: .warning,
            buttons: [.ok()]
        ) { [weak self] _ in
            self?.viewModel.showError = false
        }
    }

    private func observeInstallerMountedAlert() {
        installerMountedObserver = observeModalFlag(
            { [weak viewModel] in viewModel?.showInstallerMountedAlert ?? false },
            present: { [weak self] in self?.presentInstallerMountedAlert() }
        )
    }

    private func presentInstallerMountedAlert() {
        guard let window = view.window else { return }
        let name = viewModel.installerMountedVMName ?? ""
        AlertPresenter.info(
            in: window,
            title: "Installer Mounted",
            message:
                "The Kernova guest agent installer has been attached to \(name) as a USB disk. "
                + "Inside the VM, open the \u{201C}Kernova Guest Agent\u{201D} disk in Finder and "
                + "run install.command to complete setup."
        ) { [weak self] in
            self?.viewModel.showInstallerMountedAlert = false
        }
    }

    // MARK: - Routing

    private func refresh() {
        let target = chooseChild()
        swap(to: target.vc, for: target.instanceID)
    }

    private struct Target {
        let vc: NSViewController
        let instanceID: UUID?
    }

    private func chooseChild() -> Target {
        guard let instance = viewModel.selectedInstance else {
            return Target(vc: EmptyStateViewController(viewModel: viewModel), instanceID: nil)
        }

        if instance.preparingState != nil {
            return Target(vc: PreparingProgressViewController(instance: instance), instanceID: instance.id)
        }

        switch instance.status {
        case .stopped, .error, .initialBoot:
            return Target(
                vc: SettingsHostViewController(instance: instance, viewModel: viewModel),
                instanceID: instance.id
            )
        case .installing:
            return Target(
                vc: SettingsHostViewController(instance: instance, viewModel: viewModel),
                instanceID: instance.id
            )
        default:
            break
        }

        if instance.status.hasActiveDisplay {
            if instance.detailPaneMode == .settings {
                return Target(
                    vc: SettingsHostViewController(instance: instance, viewModel: viewModel),
                    instanceID: instance.id
                )
            }
            return Target(
                vc: ConsolePlaceholderViewController(instance: instance),
                instanceID: instance.id
            )
        }

        // Lifecycle transitions (starting, stopping, pausing, resuming…)
        return Target(
            vc: TransitionProgressViewController(instance: instance),
            instanceID: instance.id
        )
    }

    private func swap(to next: NSViewController, for instanceID: UUID?) {
        // Re-create the child VC when the selected instance changes — mirrors
        // SwiftUI `.id(...)` identity reset so per-VM transient UI state is
        // discarded on a sidebar switch.
        let needsSwap: Bool = {
            guard let current = currentChild else { return true }
            if currentChildInstanceID != instanceID { return true }
            return type(of: current) != type(of: next)
        }()

        guard needsSwap else { return }

        if let current = currentChild {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }

        addChild(next)
        view.addFullSizeSubview(next.view)
        currentChild = next
        currentChildInstanceID = instanceID
    }
}
