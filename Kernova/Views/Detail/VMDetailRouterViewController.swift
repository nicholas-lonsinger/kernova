import AppKit

/// Routes the detail pane to the right content for the selected VM's status.
///
/// AppKit replacement for the former SwiftUI `VMDetailView`: it resolves a
/// ``DetailRoute`` from the instance's status (via the pure mapping function)
/// and swaps its visible child accordingly — settings, a transient-status
/// spinner, the macOS install progress UI, or the display placeholder. Child
/// controllers are reused across route changes; switching the bound VM rebuilds
/// per-instance state (mirroring the SwiftUI `.id(selected.id)` reset).
@MainActor
final class VMDetailRouterViewController: NSViewController {
    private var instance: VMInstance
    private var viewModel: VMLibraryViewModel
    private var observation: ObservationLoop?

    private let contentStack = NSStackView()
    private var currentChild: NSViewController?
    private var currentBanner: NSView?
    private var displayedRoute: DetailRoute?

    // Reused children.
    private lazy var settingsVC = VMSettingsViewController(
        instance: instance, viewModel: viewModel, isReadOnly: false)
    private lazy var placeholderVC = DetailStatusPlaceholderViewController()
    private lazy var displayVC = VMDisplayPlaceholderContentViewController(instance: instance)

    init(instance: VMInstance, viewModel: VMLibraryViewModel) {
        self.instance = instance
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMDetailRouterViewController does not support NSCoder")
    }

    /// Rebinds the router to a (possibly different) selected VM.
    func reconfigure(instance: VMInstance, viewModel: VMLibraryViewModel) {
        self.instance = instance
        self.viewModel = viewModel
        guard isViewLoaded else { return }
        displayedRoute = nil
        restartObservation()
        apply()
    }

    override func loadView() {
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = Spacing.none
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view = contentStack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        restartObservation()
        apply()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        observation?.cancel()
        observation = nil
    }

    private func restartObservation() {
        observation?.cancel()
        observation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.instance.preparingState
                _ = self.instance.status
                _ = self.instance.detailPaneMode
                _ = self.instance.installState
            },
            apply: { [weak self] in self?.apply() }
        )
    }

    // MARK: - Routing

    private func apply() {
        guard isViewLoaded else { return }
        let route = DetailRoute.resolve(
            preparingLabel: instance.preparingState?.displayLabel,
            status: instance.status,
            hasInstallState: instance.installState != nil,
            detailPaneMode: instance.detailPaneMode)

        guard route != displayedRoute else { return }
        displayedRoute = route
        render(route)
    }

    private func render(_ route: DetailRoute) {
        switch route {
        case .preparing(let label), .transition(let label):
            placeholderVC.configure(label: label)
            setContent(child: placeholderVC, banner: nil)

        case .settings(let readOnly):
            settingsVC.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: readOnly)
            setContent(child: settingsVC, banner: nil)

        case .initialBoot:
            settingsVC.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: false)
            setContent(child: settingsVC, banner: InitialBootBannerView(instance: instance))

        case .install:
            let installVC = MacOSInstallProgressViewController(instance: instance) { [weak self] in
                guard let self else { return }
                self.viewModel.cancelInstallation(self.instance)
            }
            setContent(child: installVC, banner: nil)

        case .display:
            displayVC.reconfigure(instance: instance)
            setContent(child: displayVC, banner: nil)
        }
    }

    /// Swaps the displayed child controller (and optional top banner), managing
    /// child-VC containment so appearance callbacks fire correctly.
    private func setContent(child: NSViewController, banner: NSView?) {
        if let previous = currentChild, previous !== child {
            previous.view.removeFromSuperview()
            previous.removeFromParent()
        }
        currentBanner?.removeFromSuperview()
        currentBanner = nil
        contentStack.arrangedSubviews.forEach {
            contentStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        if child.parent !== self {
            addChild(child)
        }
        currentChild = child

        if let banner {
            banner.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addArrangedSubview(banner)
            banner.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
            currentBanner = banner
        }

        child.view.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(child.view)
        child.view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        child.view.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
}
