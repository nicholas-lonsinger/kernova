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
    private var hasDisappeared = false
    // MARK: - Presenters & coordinators

    // MARK: - Persistent chrome (rebuilt per instance in `buildForm`)

    private let formStack = NSStackView()
    /// The scrolling form below the pinned header.
    private var scrollView = NSScrollView()
    /// Hosts the identity header, or the panel header while a category is open.
    private let headerContent = NSStackView()
    /// The VM's identity block, shown above the overview.
    private var identityHeader = VMIdentityHeaderView()
    private let panelHeader = VMSettingsPanelHeaderView()

    /// The overview of category cards, shown when no category is open.
    private let overviewVC = VMSettingsOverviewViewController()
    /// One panel per category, all built up-front and shown one at a time —
    /// hidden panels stay in the tree so `apply()` keeps them current and a
    /// drill-in shows the right state immediately.
    private var panels: [VMSettingsCategory: NSView] = [:]
    /// Header pieces a single-section category hands to the panel header.
    private var panelChrome: [VMSettingsCategory: VMSettingsPanelChrome] = [:]
    /// The per-category panels, each owning its own sections and refresh pass.
    private var panelControllers: [VMSettingsCategory: any VMSettingsPanel] = [:]
    /// The open category, or `nil` for the overview.
    private(set) var selectedCategory: VMSettingsCategory?

    /// "Editable when stopped" hints on lockable section headers; shown only
    /// while read-only.
    private var lockHints: [NSView] = []
    /// Form rows that only a stopped VM can change: their controls go inert and
    /// the whole row dims while read-only (per-row controls in the dynamic lists
    /// set their own enabled state when those lists are rebuilt).
    private var lockableRows: [(row: NSView, controls: [NSControl])] = []

    // General
    private var nameButton = NSButton()
    private let nameField = NSTextField()
    /// The "Installed From" row and its value label, hidden while the VM
    /// carries no record of the image it was set up from.
    private var installedImageRow: GroupedFormCollapsibleRow?
    private var installedImageValueLabel: NSTextField?
    /// The OS version row and its value label, hidden until an agent reports
    /// one; both `nil` for Linux guests, which have no agent to report one.
    private var guestOSVersionRow: GroupedFormCollapsibleRow?
    private var guestOSVersionValueLabel: NSTextField?
    private var nameDisplayRow = NSView()
    private var nameEditRow = NSView()
    private var nameRowIsEditing = false
    /// Suppresses the end-editing commit while a path that already settled the
    /// rename (Escape's cancel) resigns the field editor.
    private var suppressNameEndEditingCommit = false
    /// Caps the name edit box at its text width so it hugs the name and grows as
    /// you type (right-aligned, the leading spacer absorbs the slack).
    ///
    /// A `<=` bound, not `==`, so a name wider than the form scrolls instead of
    /// stretching the window. Created once for the lifetime of the reused
    /// `nameField`, *not* per `buildForm()`: the constraint lives on the field,
    /// so a copy minted on every instance swap outlives its build cycle — the
    /// caps accumulate and the smallest constant wins.
    private lazy var nameEditMaxWidth: NSLayoutConstraint = {
        let constraint = nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        constraint.priority = .defaultHigh
        return constraint
    }()
    /// Active only while renaming: ends the edit on a click outside the name field.
    ///
    /// Resigns the field editor (committing the current text) — AppKit doesn't end
    /// field editing when a click lands on the settings card's non-focusable
    /// space, so without this the box would linger.
    private var nameOutsideClickMonitor: Any?

    // Startup
    private var autoStartSwitch = NSSwitch()
    /// Holds the banner naming how many macOS guests are marked to start at
    /// launch, when that exceeds what macOS runs at once.
    private var autoStartWarningContainer = NSStackView()
    private var ephemeralSwitch = NSSwitch()
    /// The Ephemeral Mode row's title label, retained so `refreshStartup` can
    /// gray it in step with a switch a VM without snapshots can't use.
    private var ephemeralLabel = NSTextField()
    private var ephemeralBaselinePopUp = NSPopUpButton()
    /// The Ephemeral Mode row and its Baseline snapshot sub-option, retained so
    /// the sub-option shows only while the mode is on.
    private var ephemeralGroup: GroupedFormSubOptionGroup?
    /// Explains that a baseline needs a snapshot first; hidden once the VM has one.
    private var ephemeralNoSnapshotsCaption = NSView()
    /// One entry of the Baseline snapshot menu, as rendered.
    private struct BaselineMenuItem: Equatable {
        let id: UUID
        let name: String
    }
    /// What the baseline menu was last built from, so it rebuilds exactly when
    /// the list or a listed name changed rather than on every `apply()` pass.
    private var renderedEphemeralBaselines: [BaselineMenuItem]?

    // MARK: - Rendered-list snapshots (early-out keys)

    /// The Startup capacity banner's rendered message, on the same terms.
    private var renderedAutoStartWarning: String?
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
        // End an in-flight name rename for the outgoing instance while it is
        // still bound: `buildForm()` resets the session flags without
        // commit/cancel, which would drop the typed text, strand `activeRename`
        // at the old id (re-selecting that VM would spontaneously reopen the
        // box), and leave the outside-click monitor installed.
        if instanceChanged, isViewLoaded, nameRowIsEditing {
            endNameRenameSession()
        }
        // Panels settle anything bound to the outgoing instance before the
        // context moves under them.
        panelControllers.values.forEach { $0.willRebind() }
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

        // The identity — or, inside a panel, the back affordance and panel title
        // — stays put while the form below it scrolls, on the same column.
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
        panelHeader.onBack = { [weak self] in self?.showOverview() }

        view = root
        buildForm()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        hasDisappeared = false
        panelContext.setDismissed(false)
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
        hasDisappeared = true
        panelContext.setDismissed(true)
        panelControllers.values.forEach { $0.prepareForDisappearance() }
        // End an in-flight name rename through the commit path (focus loss
        // commits): leaving the session flags armed would re-show the edit box
        // on reappear with no outside-click monitor and a stale marker.
        if nameRowIsEditing {
            endNameRenameSession()
        }
        removeNameOutsideClickMonitor()
        modelObservation?.cancel()
        modelObservation = nil
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        // Fallback teardown of the name-rename monitor for any path that reaches
        // `viewDidDisappear` without `viewWillDisappear`.
        removeNameOutsideClickMonitor()
    }

    private var isRenaming: Bool {
        viewModel.activeRename == .detail(instance.id)
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
        lockHints.removeAll()
        lockableRows.removeAll()
        nameRowIsEditing = false
        // The list stacks and the audio-warning container are recreated below,
        // so invalidate the render snapshots that guard their refreshes.
        renderedAutoStartWarning = nil

        panels.removeAll()
        panelChrome.removeAll()

        identityHeader = VMIdentityHeaderView()
        overviewVC.rebuild(guestOS: instance.configuration.guestOS)
        addPanelContent(overviewVC.view)

        let sections: [VMSettingsCategory: [NSView]] = [
            .general: [buildGeneralSection(), buildStartupSection()],
        ]

        for category in VMSettingsCategory.allCases {
            let panel: NSView
            if let controller = panelControllers[category] {
                controller.rebuild()
                panel = controller.view
            } else {
                panel = makePanel(sections[category] ?? [])
            }
            panel.isHidden = true
            addPanelContent(panel)
            panels[category] = panel
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

    /// Stacks one category's sections into the panel shown for it.
    private func makePanel(_ sections: [NSView]) -> NSView {
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.section
        stack.translatesAutoresizingMaskIntoConstraints = false
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
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

    /// Puts the identity header or the open panel's header into the pinned
    /// header container.
    private func refreshHeader() {
        let header: NSView = selectedCategory == nil ? identityHeader : panelHeader
        if headerContent.arrangedSubviews.first !== header {
            headerContent.arrangedSubviews.forEach { $0.removeFromSuperview() }
            headerContent.addArrangedSubview(header)
            header.widthAnchor.constraint(equalTo: headerContent.widthAnchor).isActive = true
        }
        refreshPanelHeader()
    }

    /// Paints the open panel's header from the model; a no-op on the overview.
    private func refreshPanelHeader() {
        guard let category = selectedCategory else { return }
        let chrome = panelControllers[category]?.chrome ?? panelChrome[category]
            ?? VMSettingsPanelChrome()
        panelHeader.configure(
            vmName: instance.name,
            statusColor: instance.statusDisplayNSColor,
            statusText: instance.statusDisplayName,
            facts: identityHeader.renderedFactsLine,
            title: category.title,
            leadingAccessories: chrome.leading,
            trailingAccessories: chrome.trailing)
    }

    /// Section header; any lock hint it creates is registered in ``lockHints``
    /// and toggled by ``apply()``. A section whose lock is conditional passes
    /// `lockHintSink` to keep its own reference — by handoff, not by position
    /// in ``lockHints``.
    private func makeHeader(
        _ title: String, lockable: Bool = false, paragraphs: [InfoPopoverParagraph] = [],
        lockHintSink: ((NSView) -> Void)? = nil
    ) -> NSView {
        var views: [NSView] = [makeGroupedFormSectionHeader(title)]
        if !paragraphs.isEmpty {
            let info = InfoButtonView()
            info.configure(label: title, paragraphs: paragraphs)
            views.append(info)
        }
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(spacer)
        if lockable {
            views.append(makeLockHint(sink: lockHintSink))
        }

        let header = NSStackView(views: views)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Spacing.small
        return header
    }

    /// A lock hint registered in ``lockHints``, for a section header or the
    /// panel header a single-section category hands its chrome to.
    private func makeLockHint(sink: ((NSView) -> Void)? = nil) -> NSView {
        let hint = makeGroupedFormLockHint()
        hint.isHidden = true
        lockHints.append(hint)
        sink?(hint)
        return hint
    }

    /// Registers `row` as editable only while the VM is stopped, returning it so
    /// it can be handed straight to a card.
    @discardableResult
    private func lockable(_ row: NSView, _ controls: NSControl...) -> NSView {
        lockableRows.append((row: row, controls: controls))
        return row
    }

    // MARK: General

    /// What the install-record row is called for `guestOS`.
    ///
    /// A macOS install ran to completion under Kernova, so its row names the
    /// version the VM started life at, sitting beside the "OS version" row that
    /// names what the guest reports today. A Linux ISO is only attached for the
    /// distribution's own installer to use — which can install something else,
    /// or nothing — so that row names the media and claims nothing about the
    /// outcome.
    static func installedImageRowLabel(guestOS: VMGuestOS) -> String {
        guestOS == .macOS ? "Installed version" : "Installer image"
    }

    private func buildGeneralSection() -> NSView {
        nameButton = NSButton(title: instance.name, target: self, action: #selector(startRename))
        nameButton.isBordered = false
        nameButton.alignment = .right
        nameButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Right-click "Rename" too, matching the storage rows and sidebar (the
        // item is gated by `validateMenuItem` when the VM can't be renamed).
        let renameMenu = NSMenu()
        let renameItem = NSMenuItem(title: "Rename", action: #selector(startRename), keyEquivalent: "")
        renameItem.target = self
        renameMenu.addItem(renameItem)
        nameButton.menu = renameMenu
        nameDisplayRow = makeGroupedFormCardRow("Name", control: nameButton)

        nameField.placeholderString = "Name"
        nameField.alignment = .right
        nameField.delegate = self
        nameField.cell?.isScrollable = true
        // The field fills the row (the leading spacer absorbs the slack) and
        // `nameEditMaxWidth` caps it at the text width. Hug is one step below the
        // spacer's so the field claims the slack first; compression is low so it
        // yields (scrolls) rather than pushes.
        nameField.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameEditRow = makeGroupedFormCardRow("Name", control: nameField)
        // `.fill` (vs the default gravity-areas) actually stretches the field to
        // fill the row, so it claims the slack and the `<=` cap below binds —
        // otherwise the scrollable field sits at its sliver-sized intrinsic.
        (nameEditRow as? NSStackView)?.distribution = .fill
        nameEditRow.isHidden = true

        nameEditMaxWidth.isActive = true

        let nameRow = NSStackView(views: [nameDisplayRow, nameEditRow])
        nameRow.orientation = .vertical
        nameRow.alignment = .leading
        nameRow.spacing = Spacing.none
        nameDisplayRow.widthAnchor.constraint(equalTo: nameRow.widthAnchor).isActive = true
        nameEditRow.widthAnchor.constraint(equalTo: nameRow.widthAnchor).isActive = true

        var rows: [NSView] = [
            nameRow,
            makeGroupedFormCardRow(
                "Type", control: makeGroupedFormValueLabel(instance.configuration.guestOS.displayName)),
        ]
        // Both OS rows are built whatever the VM knows today, then hidden until
        // it knows: an install completing or a first agent Hello fills one in
        // while this pane is on screen, and only `apply()` runs then.
        let installedImage = instance.configuration.installedImage?.displayName
        let installedLabel = makeGroupedFormValueLabel(installedImage ?? "")
        installedImageValueLabel = installedLabel
        let installedRow = GroupedFormCollapsibleRow(
            row: makeGroupedFormCardRow(
                Self.installedImageRowLabel(guestOS: instance.configuration.guestOS),
                control: installedLabel))
        installedRow.isHidden = installedImage == nil
        installedImageRow = installedRow
        rows.append(installedRow)

        if instance.configuration.guestOS == .macOS {
            let reported = instance.guestOSVersionDisplay
            let versionLabel = makeGroupedFormValueLabel(reported ?? "")
            guestOSVersionValueLabel = versionLabel
            let versionRow = GroupedFormCollapsibleRow(
                row: makeGroupedFormCardRow("OS version", control: versionLabel))
            versionRow.isHidden = reported == nil
            guestOSVersionRow = versionRow
            rows.append(versionRow)
        } else {
            guestOSVersionValueLabel = nil
            guestOSVersionRow = nil
        }
        rows += [
            makeGroupedFormCardRow(
                "Boot mode", control: makeGroupedFormValueLabel(instance.configuration.bootMode.displayName)),
            makeGroupedFormCardRow(
                "Created",
                control: makeGroupedFormValueLabel(
                    instance.configuration.createdAt.formatted(date: .abbreviated, time: .shortened))),
        ]
        return makeGroupedFormSection([makeHeader("General"), makeGroupedFormCard(rows: rows)])
    }

    // MARK: Startup

    /// How many macOS guests macOS itself will run at the same time.
    ///
    /// The cap is the platform's, enforced by VZ — a start past it fails, which
    /// is what ``VMLibraryViewModel/explainedFailure(for:on:)`` explains after
    /// the fact. Here it is read ahead of time, off the marked set.
    static let concurrentMacOSGuestLimit = 2

    /// Caption under the Startup card: the launch pass walks the library in
    /// sidebar order, so that is the order the marked VMs come up in.
    static let autoStartOrderCaption =
        "Virtual machines start in the order they appear in the sidebar."

    /// Warning for a marked set macOS cannot run at once, or `nil` when it fits.
    ///
    /// Shown only on a macOS guest's own pane: it is the guests past the cap
    /// that fail, and the pane a user is looking at is the one they can act on.
    /// Linux guests do not count against the macOS cap and never see it.
    static func autoStartCapacityWarning(
        isMacOSGuest: Bool, markedMacOSVMCount: Int
    ) -> String? {
        guard isMacOSGuest, markedMacOSVMCount > concurrentMacOSGuestLimit else { return nil }
        return "\(markedMacOSVMCount) macOS virtual machines are set to start when Kernova opens. "
            + "macOS allows at most two macOS virtual machines to run at once, "
            + "so the ones after the first two won't start."
    }

    /// The Startup card's two toggles, their captions, and the capacity banner's
    /// container.
    ///
    /// Not `lockable`, and neither switch is in `persistentLockableControls`:
    /// the auto-start flag is read once at app launch, the ephemeral one at
    /// power-off, and neither reaches a `VZVirtualMachineConfiguration` — so
    /// both edit while the VM runs.
    private func buildStartupSection() -> NSView {
        autoStartSwitch = makeGroupedFormSwitch(target: self, action: #selector(autoStartToggled))
        ephemeralSwitch = makeGroupedFormSwitch(target: self, action: #selector(ephemeralModeToggled))
        ephemeralBaselinePopUp = makeEphemeralBaselinePopUp()
        renderedEphemeralBaselines = nil
        let ephemeralGroup = makeGroupedFormSubOptionGroup(
            primary: makeGroupedFormToggleRowWithInfo(
                "Ephemeral Mode", control: ephemeralSwitch,
                paragraphs: EphemeralModeCopy.popoverParagraphs,
                titleLabel: { [weak self] in self?.ephemeralLabel = $0 }),
            subOption: makeGroupedFormCardRow(
                "Baseline snapshot", control: ephemeralBaselinePopUp))
        self.ephemeralGroup = ephemeralGroup

        let card = makeGroupedFormCard(rows: [
            makeGroupedFormToggleRowWithInfo(
                "Start when Kernova opens", control: autoStartSwitch,
                paragraphs: [
                    .body(
                        "Starts this virtual machine each time Kernova opens. A suspended VM resumes from its saved state; one that has not finished its initial setup is left alone."
                    ),
                    .body(
                        "Turn on Open at Login in Settings → General to have it running after you log in."
                    ),
                ]),
            ephemeralGroup,
        ])

        autoStartWarningContainer = NSStackView()
        autoStartWarningContainer.orientation = .vertical
        autoStartWarningContainer.alignment = .leading
        autoStartWarningContainer.spacing = Spacing.small
        autoStartWarningContainer.translatesAutoresizingMaskIntoConstraints = false

        let noSnapshots = makeGroupedFormCaption(EphemeralModeCopy.noSnapshotsCaption)
        noSnapshots.isHidden = true
        ephemeralNoSnapshotsCaption = noSnapshots

        return makeGroupedFormSection([
            makeHeader("Startup"), card,
            makeGroupedFormCaption(Self.autoStartOrderCaption),
            makeGroupedFormCaption(EphemeralModeCopy.settingsCaption),
            noSnapshots,
            autoStartWarningContainer,
        ])
    }

    private func makeEphemeralBaselinePopUp() -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.controlSize = .small
        popUp.target = self
        popUp.action = #selector(ephemeralBaselineChanged)
        return popUp
    }
}

// MARK: - apply() and per-section refresh

extension VMSettingsViewController {
    /// Idempotently refreshes all mutable chrome from the model.
    private func apply() {
        guard isViewLoaded else { return }
        lockHints.forEach { $0.isHidden = !isReadOnly }
        for entry in lockableRows {
            entry.controls.forEach { $0.isEnabled = !isReadOnly }
            entry.row.alphaValue = isReadOnly ? Alpha.disabled : 1
        }

        identityHeader.configure(with: instance)
        refreshGeneral()
        refreshStartup()
        panelControllers.values.forEach { $0.refresh() }
        // Last, so the cards state what the refreshers above just resolved.
        refreshOverview()
        refreshPanelHeader()
    }

    /// Paints the overview cards from the same pass that refreshed the panels.
    ///
    /// Each panel adds what only it resolved; the shell holds no per-category
    /// state of its own to state here.
    private func refreshOverview() {
        var resolved = VMOverviewResolved()
        resolved.warnings[.general] = renderedAutoStartWarning
        for panel in panelControllers.values {
            panel.contribute(to: &resolved)
        }
        overviewVC.configure(
            instance: instance, isReadOnly: isReadOnly,
            networkIsLiveSwitchable: resolved.networkIsLiveSwitchable, resolved: resolved)
    }

    private func refreshGeneral() {
        nameButton.title = instance.name
        nameButton.isEnabled = instance.status.canRename
        let installedImage = instance.configuration.installedImage?.displayName
        installedImageValueLabel?.stringValue = installedImage ?? ""
        installedImageRow?.isHidden = installedImage == nil
        let reportedOSVersion = instance.guestOSVersionDisplay
        guestOSVersionValueLabel?.stringValue = reportedOSVersion ?? ""
        guestOSVersionRow?.isHidden = reportedOSVersion == nil
        let renaming = isRenaming
        if renaming != nameRowIsEditing {
            if renaming {
                nameRowIsEditing = true
                nameDisplayRow.isHidden = true
                nameEditRow.isHidden = false
                nameField.stringValue = instance.name
                view.window?.makeFirstResponder(nameField)
                // Re-seed after taking focus: the makeFirstResponder above can
                // synchronously commit the *other* surface's pending rename,
                // changing `instance.name` after the seed — and the mutation
                // lands inside this very apply() pass, so no later pass repairs
                // an already-open box.
                nameField.stringValue = instance.name
                if let editor = nameField.currentEditor() {
                    editor.string = instance.name
                    editor.selectAll(nil)
                }
                nameEditMaxWidth.constant = InlineRenameSizing.boxWidth(
                    for: instance.name, font: Typography.body)
                installNameOutsideClickMonitor()
            } else {
                removeNameOutsideClickMonitor()
                // End a still-active editor session BEFORE flipping the session
                // flag or hiding the row: the resign flows through
                // `controlTextDidEndEditing`, whose commit gate reads
                // `nameRowIsEditing`, so a superseded rename's in-flight text
                // still commits and no focused-but-invisible editor survives to
                // swallow keystrokes.
                if nameField.currentEditor() != nil {
                    Self.logger.debug(
                        "Ending superseded name rename session via end-editing commit")
                    view.window?.makeFirstResponder(nil)
                }
                nameRowIsEditing = false
                nameDisplayRow.isHidden = false
                nameEditRow.isHidden = true
            }
        }
    }

    /// Installs a local mouse-down monitor that ends the rename on an outside click.
    ///
    /// Resigns the field editor so `controlTextDidEndEditing` commits when the
    /// user clicks anywhere outside the name field — AppKit doesn't end field
    /// editing on clicks that land on non-focusable space in the settings card.
    private func installNameOutsideClickMonitor() {
        removeNameOutsideClickMonitor()
        nameOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, self.isRenaming else { return event }
            let pointInField = self.nameField.convert(event.locationInWindow, from: nil)
            if !self.nameField.bounds.contains(pointInField) {
                self.view.window?.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func removeNameOutsideClickMonitor() {
        if let monitor = nameOutsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            nameOutsideClickMonitor = nil
        }
    }

    /// Ends an in-flight name rename through the end-editing commit path.
    ///
    /// For paths that bypass `refreshGeneral`'s teardown transition (instance
    /// rebind, view disappearance): those reset `nameRowIsEditing` out-of-band,
    /// stranding the typed text, the marker, and the outside-click monitor.
    private func endNameRenameSession() {
        if nameField.currentEditor() != nil {
            view.window?.makeFirstResponder(nil)
        }
        removeNameOutsideClickMonitor()
        nameRowIsEditing = false
        nameDisplayRow.isHidden = false
        nameEditRow.isHidden = true
    }

    private func refreshStartup() {
        autoStartSwitch.state = instance.configuration.startsAutomaticallyOnLaunch ? .on : .off
        refreshEphemeralMode()

        let message = Self.autoStartCapacityWarning(
            isMacOSGuest: instance.configuration.guestOS == .macOS,
            markedMacOSVMCount: viewModel.macOSVMNamesMarkedForAutoStart.count)
        guard message != renderedAutoStartWarning else { return }
        renderedAutoStartWarning = message
        autoStartWarningContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let message else { return }
        let banner = makeGroupedFormBanner(
            symbolName: "exclamationmark.triangle.fill", tint: .systemYellow, message: message)
        addGroupedFormFullWidth(banner, to: autoStartWarningContainer)
    }

    /// Renders the Ephemeral Mode toggle, its baseline menu, and the captions
    /// that stand in for a VM with nothing to use as a baseline.
    ///
    /// Both controls stay live while the pane is read-only: the flag is read at
    /// power-off, and a running ephemeral VM is exactly where a user reaches for
    /// the switch.
    private func refreshEphemeralMode() {
        let manifest = instance.snapshotManifest
        let enabled = instance.configuration.ephemeralModeEnabled
        ephemeralSwitch.state = enabled ? .on : .off
        // A VM with nothing to fall back to can't take the mode — but one that
        // is already in it can always be taken back out.
        let offerable = !manifest.isEmpty || enabled
        applyGroupedFormRowEnabled(offerable, control: ephemeralSwitch, label: ephemeralLabel)
        ephemeralNoSnapshotsCaption.isHidden = !manifest.isEmpty
        ephemeralGroup?.isSubOptionHidden = !enabled

        let listed = manifest.ordered.map { BaselineMenuItem(id: $0.id, name: $0.name) }
        if listed != renderedEphemeralBaselines {
            renderedEphemeralBaselines = listed
            ephemeralBaselinePopUp.menu?.removeAllItems()
            for item in listed {
                ephemeralBaselinePopUp.addItem(withTitle: item.name)
                ephemeralBaselinePopUp.lastItem?.representedObject = item.id
            }
        }
        guard
            let index = ephemeralBaselinePopUp.itemArray.firstIndex(where: {
                ($0.representedObject as? UUID) == instance.configuration.ephemeralBaselineSnapshotID
            })
        else { return }
        ephemeralBaselinePopUp.selectItem(at: index)
    }
}

// MARK: - Actions

extension VMSettingsViewController: NSMenuItemValidation {
    @objc private func startRename() {
        guard instance.status.canRename else { return }
        viewModel.renameVMInDetail(instance)
    }

    /// Disables the name field's right-click "Rename" while the VM can't be
    /// renamed (e.g. while running), mirroring the disabled name button.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(startRename) {
            return instance.status.canRename
        }
        return true
    }

    @objc private func autoStartToggled() {
        setAutoStart(autoStartSwitch.state == .on)
    }

    /// The one write path for the auto-start flag, whichever surface's switch
    /// asked for it.
    private func setAutoStart(_ isOn: Bool) {
        writeMirrored { $0.startsAutomaticallyOnLaunch = isOn }
    }

    @objc private func ephemeralModeToggled() {
        setEphemeralMode(ephemeralSwitch.state == .on)
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

    @objc private func ephemeralBaselineChanged() {
        guard let id = ephemeralBaselinePopUp.selectedItem?.representedObject as? UUID else {
            Self.logger.fault("Ephemeral baseline popup selection carries no snapshot")
            assertionFailure("Ephemeral baseline popup selection carries no snapshot")
            return
        }
        writeConfig { $0.applyEphemeralMode(enabled: true, baseline: id) }
    }

    /// The baseline a freshly-enabled mode takes: the VM's own choice while it
    /// still names a listed snapshot, then the Current one, then the newest.
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

// MARK: - NSTextFieldDelegate

extension VMSettingsViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === nameField else { return }
        let live = nameField.currentEditor()?.string ?? nameField.stringValue
        nameEditMaxWidth.constant = InlineRenameSizing.boxWidth(for: live, font: Typography.body)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        switch field {
        case nameField:
            // Gate on the local session flag, not the model marker: when this
            // surface's rename is superseded mid-handoff the marker has already
            // moved to the other surface, but the in-flight text must still
            // commit.
            if nameRowIsEditing, !suppressNameEndEditingCommit {
                viewModel.commitRename(
                    for: instance, newName: nameField.stringValue, from: .detail)
            }
        default:
            break
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === nameField else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Resign instead of committing directly: the end-editing path is the
            // single commit path, so Return, outside clicks, and superseded
            // teardowns all commit the same way.
            view.window?.makeFirstResponder(nil)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Clear the rename first, then end the field editor with the
            // commit suppressed so the resign can't write the live buffer.
            viewModel.cancelRename(for: instance, from: .detail)
            suppressNameEndEditingCommit = true
            view.window?.makeFirstResponder(nil)
            suppressNameEndEditingCommit = false
            return true
        }
        return false
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
