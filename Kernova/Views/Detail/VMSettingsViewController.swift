import AVFoundation
import AppKit
import UniformTypeIdentifiers
import Virtualization
import os

/// Pure-AppKit settings pane for editing a stopped VM's configuration, or
/// viewing a running VM's configuration in read-only mode.
///
/// Structure that depends on the *instance* (guest-agent section visibility,
/// OS-specific help text) is fixed per instance and built in ``buildForm()``;
/// switching VMs rebuilds the form. ``apply()`` only updates
/// mutable state: control values, lock/enabled state, the dynamic attachment
/// lists, and the microphone permission warning.
///
/// Both attachment lists — storage disks and removable media — are served by one
/// set of row, menu and popover builders parameterized by `AttachmentKind` and
/// dispatching on an `AttachmentRef(kind:id:)`, never a second implementation
/// per list.
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

    // MARK: - Persistent chrome (rebuilt per instance in `buildForm`)

    private let formStack = NSStackView()
    /// The scrolling form below the pinned header.
    private var scrollView = NSScrollView()
    /// Hosts the pinned header.
    private let headerContent = NSStackView()
    /// The pinned header: the VM's identity on the overview, the open
    /// category's name and the way back inside a panel.
    private var identityHeader = VMIdentityHeaderView()

    /// The overview of category cards, shown when no category is open.
    private let overviewVC = VMSettingsOverviewViewController()
    /// One panel per category, all built up-front and shown one at a time —
    /// hidden panels stay in the tree so `apply()` keeps them current and a
    /// drill-in shows the right state immediately.
    private var panels: [VMSettingsCategory: NSView] = [:]
    /// The per-category panels, each owning its own sections and refresh pass.
    private var panelControllers: [VMSettingsCategory: any VMSettingsPanel] = [:]
    /// The open category, or `nil` for the overview.
    private(set) var selectedCategory: VMSettingsCategory?

    // MARK: - Rendered-list snapshots (early-out keys)

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
            panelControllers.values.forEach { $0.willRebind() }
        }
        self.instance = instance
        self.viewModel = viewModel
        self.isReadOnly = isReadOnly
        panelContext.rebind(instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)

        guard isViewLoaded else { return }

        if instanceChanged {
            buildForm()
            // Re-arm the model observation on the new instance: it is one-shot and
            // re-registers only after it fires, so otherwise the loop stays bound
            // to the previous instance. Only restart when already observing;
            // creating it here early would skip the notification observer.
            if modelObservation != nil {
                restartModelObservation()
            }
        }
        apply()

        if instanceChanged {
            // The indicator is reused across VM switches, so without this re-arm
            // only the first overflowing pane in a session would flash. Force
            // layout so overflow is measured on the new form's real height.
            view.layoutSubtreeIfNeeded()
            scrollMoreIndicator?.rearmFlash()
        }
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
        installPanels()

        view = root
        buildForm()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        panelContext.setDismissed(false)
        panelControllers.values.forEach { $0.hostDidAppear() }
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
            },
            apply: { [weak self] in self?.apply() }
        )
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        panelContext.setDismissed(true)
        panelControllers.values.forEach { $0.prepareForDisappearance() }
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
    /// Rebuilds the whole form for the current instance.
    ///
    /// Called on first load and whenever the bound instance changes.
    private func buildForm() {
        formStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        panels.removeAll()

        identityHeader = VMIdentityHeaderView()
        overviewVC.rebuild(guestOS: instance.configuration.guestOS)
        addPanelContent(overviewVC.view)

        for category in VMSettingsCategory.allCases {
            guard let controller = panelControllers[category] else {
                Self.logger.fault("No panel for category '\(category.rawValue, privacy: .public)'")
                assertionFailure("No panel for category: \(category.rawValue)")
                continue
            }
            controller.rebuild()
            controller.view.isHidden = true
            addPanelContent(controller.view)
            panels[category] = controller.view
        }
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
    /// The panel view for `category`, so a test can scope its search to one
    /// category rather than the whole pane.
    func panelForTesting(_ category: VMSettingsCategory) -> NSView? { panels[category] }

    /// The overview's card for `category`.
    func overviewCardForTesting(_ category: VMSettingsCategory) -> VMOverviewCardView? {
        overviewVC.cardForTesting(category)
    }

    /// The panel controller for `category`, for a test reaching a seam the
    /// panel owns.
    func settingsPanelForTesting(_ category: VMSettingsCategory) -> (any VMSettingsPanel)? {
        panelControllers[category]
    }
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
        // resign first responder on hide, so a half-typed MAC address, display
        // dimension or inline row title would keep focus inside a hidden panel,
        // swallowing keystrokes and committing later out of context. Resigning
        // commits it through the normal end-editing path.
        if let window = view.window, let responder = window.firstResponder as? NSView,
            responder.isDescendant(of: view)
        {
            window.makeFirstResponder(nil)
        }
        selectedCategory = category
        overviewVC.view.isHidden = category != nil
        for (key, panel) in panels {
            panel.isHidden = key != category
        }
        refreshHeader()
        view.layoutSubtreeIfNeeded()
        // A panel opens at its own top, not wherever the previous one was
        // scrolled to.
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollMoreIndicator?.rearmFlash()
    }

    /// Paints the pinned header for the current state, installing it the first
    /// time and on a VM switch.
    ///
    /// One header serves both states, so a drill-in reconfigures it in place
    /// rather than swapping views.
    private func refreshHeader() {
        if headerContent.arrangedSubviews.first !== identityHeader {
            headerContent.arrangedSubviews.forEach { $0.removeFromSuperview() }
            headerContent.addArrangedSubview(identityHeader)
            identityHeader.widthAnchor.constraint(equalTo: headerContent.widthAnchor)
                .isActive = true
            identityHeader.setBackAction(target: self, action: #selector(backToOverview))
        }
        let chrome = selectedCategory.flatMap { panelControllers[$0]?.chrome }
        identityHeader.configure(
            with: instance,
            mode: selectedCategory.map { .category($0.title) } ?? .identity,
            leadingAccessories: chrome?.leading ?? [],
            trailingAccessories: chrome?.trailing ?? [])
    }
}

// MARK: - apply() and per-section refresh

extension VMSettingsViewController {
    /// Idempotently refreshes all mutable chrome from the model.
    private func apply() {
        guard isViewLoaded else { return }
        panelControllers.values.forEach { $0.refresh() }
        // Last, so the cards and the header state what the refreshers above
        // just resolved — the open panel's chrome among it.
        refreshOverview()
        refreshHeader()
    }

    /// Paints the overview cards from the same pass that refreshed the panels.
    ///
    /// Each panel adds what only it resolved; the shell holds no per-category
    /// state of its own to state here.
    private func refreshOverview() {
        var resolved = VMOverviewResolved()
        for panel in panelControllers.values {
            panel.contribute(to: &resolved)
        }
        overviewVC.configure(instance: instance, isReadOnly: isReadOnly, resolved: resolved)
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
    /// goes through — this pane's row, the overview card, and the clipboard
    /// window's footer switch.
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
        panelControllers.values.forEach { $0.hostDidBecomeActive() }
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

    func settingsPanelRequestsFullRefresh() {
        apply()
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
