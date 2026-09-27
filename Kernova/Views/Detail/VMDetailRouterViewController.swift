import AppKit

/// Routes the detail pane to the right content for the selected VM's status.
///
/// Child controllers are reused across route changes; switching the bound VM
/// rebuilds per-instance state.
@MainActor
final class VMDetailRouterViewController: NSViewController {
    private var instance: VMInstance
    private var viewModel: VMLibraryViewModel
    private var observation: ObservationLoop?

    private let contentStack = NSStackView()
    private var currentChild: NSViewController?
    private var currentBanner: NSView?
    private var displayed: Rendered?

    /// What the pane last rendered: the route, and whether a settings form it
    /// shows takes edits.
    private struct Rendered: Equatable {
        let route: DetailRoute
        let isReadOnly: Bool
    }

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

    #if DEBUG
    /// What the pane last rendered: its route, and whether it holds a form
    /// read-only.
    var renderedForTesting: (route: DetailRoute, isReadOnly: Bool)? {
        displayed.map { ($0.route, $0.isReadOnly) }
    }

    /// The settings form every form-bearing route shows.
    var settingsForTesting: VMSettingsViewController { settingsVC }
    #endif

    /// Rebinds the router to a (possibly different) selected VM.
    func reconfigure(instance: VMInstance, viewModel: VMLibraryViewModel) {
        self.instance = instance
        self.viewModel = viewModel
        guard isViewLoaded else { return }
        displayed = nil
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
                _ = self.instance.phase
                _ = self.instance.detailPaneMode
                _ = self.instance.setupState
                _ = self.isSettingsReadOnly
            },
            apply: { [weak self] in self?.apply() }
        )
    }

    // MARK: - Routing

    /// Whether a settings form this pane shows takes configuration edits: the
    /// catalog's answer, so the form locks for whatever refuses them — a live
    /// guest, an operation, another copy of Kernova holding the VM.
    private var isSettingsReadOnly: Bool {
        !viewModel.capabilities.isAvailable(.editConfiguration, on: instance)
    }

    private func apply() {
        guard isViewLoaded else { return }
        let route = DetailRoute.resolve(
            phase: instance.phase,
            hasSetupState: instance.setupState != nil,
            detailPaneMode: instance.detailPaneMode)
        let showsSettings =
            switch route {
            case .settings, .initialBoot, .error: true
            case .setup, .transition, .display: false
            }
        // Read only for a route showing the form, so a lock that moves under
        // the display leaves it in place.
        let rendered = Rendered(route: route, isReadOnly: showsSettings && isSettingsReadOnly)

        guard rendered != displayed else { return }
        displayed = rendered
        render(rendered)
    }

    private func render(_ rendered: Rendered) {
        let readOnly = rendered.isReadOnly
        switch rendered.route {
        case .transition(let label):
            placeholderVC.configure(label: label)
            setContent(child: placeholderVC, banner: nil)

        case .settings:
            settingsVC.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: readOnly)
            setContent(child: settingsVC, banner: nil)

        case .initialBoot:
            settingsVC.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: readOnly)
            setContent(child: settingsVC, banner: DetailBannerView.initialBoot(instance: instance))

        case .error(let message):
            settingsVC.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: readOnly)
            setContent(child: settingsVC, banner: DetailBannerView.error(message: message))

        case .setup:
            let setupVC = GuestSetupProgressViewController(
                instance: instance,
                descriptor: .forSetup(of: instance)
            ) { [weak self] in
                guard let self else { return }
                self.viewModel.cancelGuestSetup(self.instance)
            }
            setContent(child: setupVC, banner: nil)

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
            // Buffer below the banner so it doesn't crowd the first section title.
            contentStack.setCustomSpacing(Spacing.section, after: banner)
            currentBanner = banner
        }

        child.view.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(child.view)
        child.view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        child.view.setContentHuggingPriority(.defaultLow, for: .vertical)
    }
}
