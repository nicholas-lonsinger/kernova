import AVFoundation
import AppKit
import UniformTypeIdentifiers
import Virtualization
import os

/// Pure-AppKit settings pane for editing a stopped VM's configuration, or
/// viewing a running VM's configuration in read-only mode.
///
/// A router over two surfaces: the overview's cards, and one open category's
/// panel. Only the visible one exists — a panel is built on the first drill-in
/// and rebuilt when the VM under it changed — so switching VMs costs one
/// overview build, and the cards state their figures from
/// ``VMOverviewResolver`` rather than from the panels that would otherwise have
/// to exist to answer for them.
///
/// ``apply()`` refreshes only what is on screen: control values, lock/enabled
/// state and the dynamic lists of the open panel, or the cards.
@MainActor
final class VMSettingsViewController: NSViewController {
    private static let logger = Logger(
        subsystem: "app.kernova", category: "VMSettingsViewController")

    private(set) var instance: VMInstance
    private var viewModel: VMLibraryViewModel
    private var isReadOnly: Bool

    /// The bindings every panel reads; rebound in one write per `reconfigure`.
    private let panelContext: VMSettingsPanelContext

    // MARK: - Observation & live state

    /// Flashes the form's scroller once when its content overflows the viewport,
    /// signaling there's more below.
    private var scrollMoreIndicator: ScrollMoreIndicator?
    private var modelObservation: ObservationLoop?
    // MARK: - Presenters & coordinators

    // MARK: - Persistent chrome

    private let formStack = NSStackView()
    /// The scrolling form below the pinned header.
    private var scrollView = NSScrollView()
    /// Hosts the pinned header.
    private let headerContent = NSStackView()
    /// The pinned header: the VM's identity on the overview, the open
    /// category's name and the way back inside a panel.
    private let identityHeader = VMIdentityHeaderView()

    /// The overview of category cards, shown when no category is open.
    private let overviewVC = VMSettingsOverviewViewController()
    /// The per-category panels, each owning its own sections and refresh pass.
    /// All are installed as child controllers; only the open one holds views.
    private var panelControllers: [VMSettingsCategory: any VMSettingsPanel] = [:]
    /// The categories whose panels hold views built for the *current* VM — the
    /// only ones with anything to paint. A VM switch empties it, so the next
    /// drill-in rebuilds.
    private var builtPanels: Set<VMSettingsCategory> = []
    /// The panel currently in `formStack`, and the width constraint holding it
    /// to the column, both dropped when it leaves.
    private var installedPanel: VMSettingsCategory?
    private var installedPanelWidth: NSLayoutConstraint?
    /// The open category, or `nil` for the overview.
    private(set) var selectedCategory: VMSettingsCategory?

    // MARK: - Init

    init(
        instance: VMInstance,
        viewModel: VMLibraryViewModel,
        isReadOnly: Bool,
        bridgedInterfaces: any BridgedInterfaceProviding = HostBridgedInterfaceProvider(),
        entitlements: EntitlementService = .shared,
        vmnetNetworks: any VmnetNetworkProviding = VmnetNetworkService.shared,
        micPermissionStatus: @escaping @MainActor () -> AVAuthorizationStatus = {
            AVCaptureDevice.authorizationStatus(for: .audio)
        },
        systemSettings: SystemSettingsLink = SystemSettingsLink()
    ) {
        self.instance = instance
        self.viewModel = viewModel
        self.isReadOnly = isReadOnly
        self.panelContext = VMSettingsPanelContext(
            instance: instance, viewModel: viewModel, isReadOnly: isReadOnly,
            bridgedInterfaces: bridgedInterfaces, entitlements: entitlements,
            vmnetNetworks: vmnetNetworks, micPermissionStatus: micPermissionStatus,
            systemSettings: systemSettings)
        super.init(nibName: nil, bundle: nil)
        panelContext.host = self
        panelContext.overview.onCategoryResolved = { [weak self] category in
            self?.repaint(category)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMSettingsViewController does not support NSCoder")
    }

    /// Rebinds the controller to a (possibly different) instance / view model and
    /// read-only state without recreating the controller.
    ///
    /// Switching to a different VM rebuilds the form (per-instance structure)
    /// and restarts the per-instance side effects; a same-instance read-only
    /// flip only re-applies mutable state.
    func reconfigure(instance: VMInstance, viewModel: VMLibraryViewModel, isReadOnly: Bool) {
        let instanceChanged = instance.id != self.instance.id
        // Panels settle anything bound to the outgoing instance before the
        // context moves under them — only when there IS an outgoing one: a
        // read-only flip re-enters `reconfigure` with the same VM, and ending a
        // rename there would commit a half-typed name.
        if instanceChanged {
            livePanels.forEach { $0.willRebind() }
        }
        self.instance = instance
        self.viewModel = viewModel
        self.isReadOnly = isReadOnly
        panelContext.rebind(instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)

        guard isViewLoaded else { return }

        guard instanceChanged else {
            apply()
            return
        }
        // `buildForm` returns to the overview through `show`, which applies.
        buildForm()
        // Re-arm the model observation on the new instance: it is one-shot and
        // re-registers only after it fires, so otherwise the loop stays bound
        // to the previous instance. Only restart when already observing;
        // creating it here early would skip the notification observer.
        if modelObservation != nil {
            restartModelObservation()
        }
    }

    /// The panels holding views built for the current VM — the only ones with
    /// anything to paint or settle.
    private var livePanels: [any VMSettingsPanel] {
        builtPanels.compactMap { panelControllers[$0] }
    }

    // MARK: - Lifecycle

    override func loadView() {
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = Spacing.section
        formStack.translatesAutoresizingMaskIntoConstraints = false

        // The detail pane has no width of its own, so the form takes the capped
        // column rather than stretching a row's control away from its label.
        let scrollView = makeGroupedFormScrollView(
            documentView: formStack, bottomInset: 16,
            maxContentWidth: GroupedFormStyle.columnWidth)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollMoreIndicator = ScrollMoreIndicator(scrollView: scrollView, cues: .flash)
        self.scrollView = scrollView

        // The header stays put while the form below it scrolls, on the same
        // column.
        headerContent.orientation = .vertical
        headerContent.alignment = .leading
        headerContent.spacing = Spacing.none
        let headerContainer = NSView()
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        headerContainer.addSubview(headerContent)
        applyCappedColumn(
            headerContent, in: headerContainer, maxWidth: GroupedFormStyle.columnWidth)

        let root = NSView()
        root.addSubview(headerContainer)
        root.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerContent.topAnchor.constraint(
                equalTo: headerContainer.topAnchor, constant: Spacing.large),
            headerContent.bottomAnchor.constraint(
                equalTo: headerContainer.bottomAnchor, constant: -Spacing.medium),
            headerContainer.topAnchor.constraint(equalTo: root.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        overviewVC.delegate = self
        addChild(overviewVC)
        addPanelContent(overviewVC.view)
        headerContent.addArrangedSubview(identityHeader)
        identityHeader.widthAnchor.constraint(equalTo: headerContent.widthAnchor).isActive = true
        identityHeader.setBackAction(target: self, action: #selector(backToOverview))
        installPanels()

        view = root
        buildForm()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        panelContext.setDismissed(false)
        livePanels.forEach { $0.hostDidAppear() }
        if modelObservation == nil {
            restartModelObservation()
            NotificationCenter.default.addObserver(
                self, selector: #selector(appDidBecomeActive),
                name: NSApplication.didBecomeActiveNotification, object: nil)
        }
        apply()
    }

    /// (Re)starts the model observation loop, cancelling any prior one so it
    /// tracks the current instance.
    private func restartModelObservation() {
        modelObservation?.cancel()
        modelObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.instance.configuration
                _ = self.instance.status
                _ = self.instance.snapshotManifest
                _ = self.viewModel.activeRename
                _ = self.viewModel.agentInstallPromptDisabled
                // Registers every instance's configuration, so the
                // duplicate-MAC banner follows a change made on the *other*
                // holder, and library membership changing under it.
                _ = self.viewModel.vmNamesSharingMACAddress(with: self.instance)
                // Same reach for the Startup capacity banner, which counts the
                // marked macOS guests across the whole library. Registered on
                // its own rather than riding the read above, which is free to
                // stop enumerating every configuration.
                _ = self.viewModel.macOSVMNamesMarkedForAutoStart
                // Registers every instance's `preparingState`, so the Storage
                // lock follows a clone of *this* VM starting and finishing.
                _ = self.viewModel.capabilities.isAvailable(.editStorageDisks, on: self.instance)
            },
            apply: { [weak self] in self?.apply() }
        )
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        panelContext.setDismissed(true)
        // Every controller, not only the live ones: a panel built for a VM the
        // pane has since switched away from can still be holding a sheet open.
        panelControllers.values.forEach { $0.prepareForDisappearance() }
        panelContext.overview.prepareForDisappearance()
        modelObservation?.cancel()
        modelObservation = nil
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    // MARK: - Write helpers (route through updateConfiguration)

    /// - Returns: Whether the mutation was applied, so a caller whose control
    ///   already moved can put it back when the view model refused.
    @discardableResult
    private func writeConfig(_ mutate: (inout VMConfiguration) -> Void) -> Bool {
        viewModel.updateConfiguration(of: instance, mutate: mutate)
    }
}

// MARK: - Form construction (per-instance structure)

extension VMSettingsViewController {
    /// Returns the form to the current instance's overview, marking every panel
    /// as needing a rebuild before it is shown again.
    ///
    /// Called on first load and whenever the bound instance changes.
    private func buildForm() {
        builtPanels.removeAll()
        overviewVC.rebuild(instance: instance)
        // Through `show`, not by setting `selectedCategory`: the overview's own
        // visibility is written there and nowhere else, so a rebuild that only
        // cleared the category would leave the overview hidden from the previous
        // VM's drill-in — a blank pane with nothing to click.
        show(nil)
    }

    /// Creates the per-category panels once, as child controllers.
    private func installPanels() {
        let panels: [any VMSettingsPanel] = [
            VMSettingsGeneralPanelViewController(context: panelContext),
            VMSettingsNetworkPanelViewController(context: panelContext),
            VMSettingsStoragePanelViewController(context: panelContext),
            VMSettingsSharingPanelViewController(context: panelContext),
            VMSettingsSystemPanelViewController(context: panelContext),
            VMSettingsSnapshotsPanelViewController(context: panelContext),
        ]
        for panel in panels {
            addChild(panel)
            panelControllers[panel.category] = panel
        }
    }

    #if DEBUG
    /// The open panel's view when `category` is the open one, so a test can
    /// scope its search to that panel; `nil` for a category not drilled into.
    func panelForTesting(_ category: VMSettingsCategory) -> NSView? {
        guard installedPanel == category else { return nil }
        return panelControllers[category]?.view
    }

    /// The overview's card for `category`.
    func overviewCardForTesting(_ category: VMSettingsCategory) -> VMOverviewCardView? {
        overviewVC.cardForTesting(category)
    }

    /// The panel controller for `category`, for a test reaching a seam the
    /// panel owns.
    func settingsPanelForTesting(_ category: VMSettingsCategory) -> (any VMSettingsPanel)? {
        panelControllers[category]
    }

    /// The pane's resolver, so a test awaits its reads instead of polling.
    var overviewResolverForTesting: VMOverviewResolver { panelContext.overview }

    /// What the cards are currently painted from.
    var resolvedForTesting: VMOverviewResolved { panelContext.overview.resolved }
    #endif

    private func addPanelContent(_ content: NSView) {
        formStack.addArrangedSubview(content)
        content.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
    }

    // MARK: - Navigation

    /// Opens `category`'s panel in place of the overview.
    func showCategory(_ category: VMSettingsCategory) {
        show(category)
    }

    /// Returns to the overview.
    func showOverview() {
        show(nil)
    }

    /// The panel header's back button.
    @objc private func backToOverview(_ sender: Any?) {
        showOverview()
    }

    private func show(_ category: VMSettingsCategory?) {
        // Settle an open field editor before its panel goes: AppKit doesn't
        // resign first responder when the view leaves, so a half-typed MAC
        // address, display dimension or inline row title would keep focus in a
        // panel the user can no longer see, swallowing keystrokes and
        // committing later out of context. Resigning commits it through the
        // normal end-editing path.
        if let window = view.window, let responder = window.firstResponder as? NSView,
            responder.isDescendant(of: view)
        {
            window.makeFirstResponder(nil)
        }
        selectedCategory = category
        if installedPanel != category {
            removeInstalledPanel()
            if let category { installPanel(category) }
        }
        overviewVC.view.isHidden = category != nil
        apply()
        // A panel opens at its own top, not wherever the previous one was
        // scrolled to.
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        // The indicator is reused across drill-ins and VM switches, so without
        // this re-arm only the first overflowing pane in a session would flash.
        // Layout first, or the re-arm measures the outgoing surface's height
        // and spends the flash on it — the tree holds the one pane on screen,
        // so this is the only forced pass a navigation costs.
        view.layoutSubtreeIfNeeded()
        scrollMoreIndicator?.rearmFlash()
    }

    /// Puts `category`'s panel in the form, building it first when it holds
    /// nothing for the current VM.
    private func installPanel(_ category: VMSettingsCategory) {
        guard let controller = panelControllers[category] else {
            Self.logger.fault("No panel for category '\(category.rawValue, privacy: .public)'")
            assertionFailure("No panel for category: \(category.rawValue)")
            return
        }
        if !builtPanels.contains(category) {
            controller.rebuild()
            builtPanels.insert(category)
        }
        formStack.addArrangedSubview(controller.view)
        let width = controller.view.widthAnchor.constraint(equalTo: formStack.widthAnchor)
        width.isActive = true
        installedPanelWidth = width
        installedPanel = category
    }

    /// Takes the open panel's view out of the form, leaving its controller — and
    /// everything it has resolved — in place for the next drill-in.
    private func removeInstalledPanel() {
        guard let installedPanel, let controller = panelControllers[installedPanel] else { return }
        installedPanelWidth?.isActive = false
        installedPanelWidth = nil
        formStack.removeArrangedSubview(controller.view)
        controller.view.removeFromSuperview()
        self.installedPanel = nil
    }

    /// Paints the pinned header for the current state.
    ///
    /// One header serves both states, so a drill-in reconfigures it in place
    /// rather than swapping views.
    private func refreshHeader() {
        let chrome = selectedCategory.flatMap { panelControllers[$0]?.chrome }
        identityHeader.configure(
            with: instance,
            mode: selectedCategory.map { .category($0.title) } ?? .identity,
            bootDiskBytes: panelContext.overview.resolved.bootDiskBytes,
            leadingAccessories: chrome?.leading ?? [],
            trailingAccessories: chrome?.trailing ?? [])
    }
}

// MARK: - apply() and per-section refresh

extension VMSettingsViewController {
    /// Idempotently refreshes the visible surface from the model: the open
    /// panel, or the overview's cards — never both, and never a panel the user
    /// has not drilled into.
    private func apply() {
        guard isViewLoaded else { return }
        panelContext.overview.refresh()
        if let selectedCategory, builtPanels.contains(selectedCategory) {
            panelControllers[selectedCategory]?.refresh()
        }
        // After the panel, so the header states what its chrome just resolved.
        refreshHeader()
        if selectedCategory == nil { refreshOverview() }
    }

    private func refreshOverview() {
        overviewVC.configure(
            instance: instance, isReadOnly: isReadOnly,
            resolved: panelContext.overview.resolved)
    }

    /// Repaints the one surface an async read moved, rather than the whole pane.
    private func repaint(_ category: VMSettingsCategory) {
        guard isViewLoaded else { return }
        if selectedCategory == category, builtPanels.contains(category) {
            panelControllers[category]?.refresh()
        }
        // The facts line carries the boot disk's capacity, so the header follows
        // the Storage read in both states.
        if category == .storage { refreshHeader() }
        guard selectedCategory == nil else { return }
        overviewVC.configureCard(
            category, instance: instance, isReadOnly: isReadOnly,
            resolved: panelContext.overview.resolved)
    }
}

// MARK: - Actions

extension VMSettingsViewController {
    /// The one write path for the auto-start flag, whichever surface's switch
    /// asked for it.
    private func setAutoStart(_ isOn: Bool) {
        writeMirrored { $0.startsAutomaticallyOnLaunch = isOn }
    }

    private func setEphemeralMode(_ isOn: Bool) {
        writeMirrored { $0.applyEphemeralMode(enabled: isOn, baseline: defaultEphemeralBaseline()) }
    }

    /// Writes a setting that renders on more than one surface, re-rendering all
    /// of them when the view model refuses so no control is left showing a value
    /// the model does not hold.
    private func writeMirrored(_ mutate: (inout VMConfiguration) -> Void) {
        guard writeConfig(mutate) else {
            apply()
            return
        }
    }

    private func defaultEphemeralBaseline() -> UUID? {
        let manifest = instance.snapshotManifest
        if let chosen = instance.configuration.ephemeralBaselineSnapshotID,
            manifest.snapshot(id: chosen) != nil
        {
            return chosen
        }
        if let current = manifest.currentID, manifest.snapshot(id: current) != nil {
            return current
        }
        return manifest.ordered.first?.id
    }

    private func setClipboardSharing(_ isOn: Bool) {
        writeMirrored { $0.clipboardSharingEnabled = isOn }
    }

    private func setDropFiles(_ isOn: Bool) {
        writeMirrored { $0.dropFilesEnabled = isOn }
    }

    /// Passthrough's shared write path, which every surface offering the toggle
    /// goes through — this pane's Sharing row and the clipboard window's footer
    /// switch.
    ///
    /// Built per use so the confirmation alert never holds this controller.
    private var passthroughSetting: ClipboardPassthroughSetting {
        ClipboardPassthroughSetting(
            instance: instance, viewModel: viewModel,
            refresh: { [weak self] in self?.apply() })
    }

    private func setClipboardPassthrough(_ isOn: Bool) {
        passthroughSetting.set(isOn, confirmingIn: view.window)
    }

    #if DEBUG
    /// Drives the confirmation outcomes without a window/sheet, so tests exercise
    /// the real enable-commit and cancel-revert paths.
    func confirmPassthroughEnableForTesting() { passthroughSetting.confirmEnable() }
    func cancelPassthroughEnableForTesting() { passthroughSetting.cancelEnable() }
    #endif

    @objc private func appDidBecomeActive() {
        panelContext.overview.rereadMicPermission()
        livePanels.forEach { $0.hostDidBecomeActive() }
        apply()
    }
}

// MARK: - VMSettingsOverviewDelegate

extension VMSettingsViewController: VMSettingsOverviewDelegate {
    func overview(
        _ vc: VMSettingsOverviewViewController, didSelect category: VMSettingsCategory
    ) {
        showCategory(category)
    }

    /// Routes a card switch into the same write path the panel's own switch
    /// takes, so a setting shown twice is still written once.
    func overview(
        _ vc: VMSettingsOverviewViewController, didSet toggle: VMOverviewToggle, to isOn: Bool
    ) {
        apply(toggle, to: isOn)
    }

    /// Runs a card's foot command through the view model's own gate — the same
    /// one the category's panel runs it through.
    func overview(_ vc: VMSettingsOverviewViewController, didInvoke action: VMOverviewAction) {
        switch action {
        case .takeSnapshot: viewModel.requestTakeSnapshot(instance)
        }
    }
}

// MARK: - VMSettingsPanelHost

extension VMSettingsViewController: VMSettingsPanelHost {
    /// The panel's own switch, arriving at the same dispatcher the overview
    /// card's does — one write path per mirrored setting, not two.
    func settingsPanel(
        _ panel: any VMSettingsPanel, setToggle toggle: VMOverviewToggle, to isOn: Bool
    ) {
        apply(toggle, to: isOn)
    }

    /// The one dispatcher for every mirrored toggle, whichever surface flipped.
    private func apply(_ toggle: VMOverviewToggle, to isOn: Bool) {
        switch toggle {
        case .autoStart: setAutoStart(isOn)
        case .ephemeralMode: setEphemeralMode(isOn)
        case .clipboardSharing: setClipboardSharing(isOn)
        case .clipboardPassthrough: setClipboardPassthrough(isOn)
        case .dropFiles: setDropFiles(isOn)
        }
    }
}
