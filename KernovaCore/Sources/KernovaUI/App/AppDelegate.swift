import AppIntents
import Cocoa
import KernovaCommandModel
import KernovaCore
import KernovaKit
import KernovaLogging

@MainActor
package final class AppDelegate: VMScriptingRoot, NSMenuItemValidation {
    /// The one owner of which user-facing windows exist, and whether any is on
    /// screen.
    private let windows: AppWindowRegistry
    /// The one owner of the menu bar — construction, the open-time rebuilds, and
    /// menu-item validation. Strongly held: `NSMenu.delegate` is weak, and this
    /// is the delegate of every menu whose opening it answers for.
    private let mainMenu: MainMenuController
    /// The one owner of what the process is when no window is on screen, and of
    /// what a launch, a reopen and a summon do to it.
    private let lifecycle: AppResidencyController
    /// The one owner of what a quit does: the classification latches, the
    /// termination gate, the save pass, and the TCC relaunch. Strongly held:
    /// `NSAppleEventManager` does not retain the quit-event handler this
    /// installs.
    private let termination: AppTerminationController
    private let viewModel: VMLibraryViewModel
    /// The one owner of where every alert the view model raises is shown,
    /// attached to the view model before the library's first read.
    private let alerts: AppAlertPresenter
    /// The library's first read from disk, started in
    /// `applicationWillFinishLaunching`, answering the VMs it found marked to
    /// start automatically.
    ///
    /// Retained so `application(_:open:)` can wait for it: a Finder open that
    /// launched the app is delivered while the read is still in flight.
    private var libraryLoad: Task<Set<UUID>, Never>?
    /// Latched once ``armAutoStartPass()`` has armed the pass, so no later call
    /// runs it a second time.
    private var hasArmedAutoStartPass = false
    /// This process's claim on its copy of Kernova, held for the life of the
    /// process and handed to the command socket when the automation front
    /// doors open.
    private let copyClaim: Result<AppCopyClaim, AppCopyClaim.Unavailable>
    /// The app's activation policy, hidden state and activation, shared with
    /// every owner that reads or changes them.
    private let presence: any AppPresence

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "AppDelegate")

    /// The VM a menu action acts on with no sender, as the menu bar's validation
    /// resolves it (``MainMenuController/activeInstance``).
    private var activeInstance: VMInstance? { mainMenu.activeInstance }

    /// The VM a nil-target action acts on, as the menu bar's validation
    /// resolves it (``MainMenuController/target(of:)``).
    private func target(of sender: Any?) -> VMInstance? { mainMenu.target(of: sender) }

    /// Builds the app's owners over `viewModel`, the library the entry point
    /// (`KernovaApp`) built over the production services.
    package init(
        viewModel: VMLibraryViewModel, copyClaim: Result<AppCopyClaim, AppCopyClaim.Unavailable>,
        presence: any AppPresence
    ) {
        self.copyClaim = copyClaim
        self.presence = presence
        self.viewModel = viewModel
        let windows = AppWindowRegistry(
            viewModel: viewModel,
            displayPlacement: VMDisplayPlacementController(viewModel: viewModel, stage: .app),
            stage: .app,
            presence: presence)
        self.windows = windows
        let alerts = AppAlertPresenter(viewModel: viewModel, windows: windows)
        self.alerts = alerts
        viewModel.presenter = alerts
        let lifecycle = AppResidencyController(
            viewModel: viewModel, windows: windows, heldAlerts: alerts.held, presence: presence)
        self.lifecycle = lifecycle
        self.mainMenu = MainMenuController(viewModel: viewModel, windows: windows)
        self.termination = AppTerminationController(
            viewModel: viewModel, residency: lifecycle, presence: presence)

        super.init()

        lifecycle.host = self
        windows.residency = lifecycle
        viewModel.onSurfaceLibrary = { [weak lifecycle] in
            lifecycle?.presentSummonedInterface()
        }
        // The status item's own Quit path, so the command core's quit verb and
        // the affordance a person clicks take the app down the same way.
        viewModel.onRequestQuit = { [weak self] consent in
            self?.termination.requestFullQuit(consentedBy: consent)
        }
        viewModel.onOpenDisplayWindow = { [weak self] instance in
            self?.windows.displayPlacement.showDisplayWindow(for: instance)
        }
        viewModel.onReadyDisplay = { [weak self] instance, presence in
            self?.windows.displayPlacement.readyDisplay(for: instance, presence: presence)
        }
        viewModel.onRevealInFinder = { instance in
            NSWorkspace.shared.activateFileViewerSelecting([instance.bundleURL])
        }
        viewModel.onShowConfigCheck = { [weak self] request in
            self?.windows.showConfigCheck(request)
        }
        viewModel.onShowSettings = { [weak self] destination in
            self?.windows.showSettings(at: destination)
        }
        viewModel.displayBootSurface = { [weak self] in self?.displayBootSurface(for: $0) }
    }

    // MARK: - NSApplicationDelegate

    /// Starts the library read.
    ///
    /// Here and not in `applicationDidFinishLaunching`: AppKit delivers a launch
    /// document's `application(_:open:)` *between* the two, and that path waits
    /// on `libraryLoad` — left unset, the wait would silently pass through and
    /// re-import a bundle already in the library. Starting the read costs nothing
    /// here; the task body only runs once the main actor yields, and its file I/O
    /// is off the main actor either way.
    package func applicationWillFinishLaunching(_ notification: Notification) {
        libraryLoad = Task { @MainActor [viewModel] in await viewModel.startLibrary() }
        // Before `lifecycle.start(provenance:)`, so an intent delivered during
        // launch resolves against a published gateway, and the command socket
        // is bound before a client that just launched the app dials it.
        lifecycle.registerAutomationFrontDoors(copyClaim: copyClaim)
    }

    /// Takes Launch Services' request for the app's default surface without
    /// opening anything: `AppResidencyController.start(provenance:)` owns
    /// presentation, and answering `true` only reports that the request was
    /// taken.
    package func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    package func applicationDidFinishLaunching(_ notification: Notification) {
        mainMenu.install()

        // Staged file URLs outlive the window and the process that staged them
        // (paste-after-close, a queued promise drop), so staging is reclaimed
        // only here, and only from processes that have exited.
        Task.detached(priority: .utility) {
            ClipboardFileStaging.processRoot.reclaimAbandonedRoots()
            DropPromiseStaging.processRoot.reclaimAbandonedRoots()
        }

        lifecycle.start(provenance: readLaunchProvenance())
    }

    /// Reads what the launch asked for.
    ///
    /// The only place either signal is read: everything downstream takes the
    /// ``AppResidencyPolicy/LaunchProvenance`` this builds.
    private func readLaunchProvenance() -> AppResidencyPolicy.LaunchProvenance {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isLoginItem =
            event.map { descriptor in
                descriptor.eventID == AEEventID(kAEOpenApplication)
                    && descriptor.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                        == keyAELaunchedAsLogInItem
            } ?? false
        let isHiddenLaunch = presence.isHidden
        Self.logger.log(
            .notice,
            "Launch signals — loginItem=\(isLoginItem, privacy: .public) hidden=\(isHiddenLaunch, privacy: .public) active=\(self.presence.isActive, privacy: .public)"
        )

        return AppResidencyPolicy.LaunchProvenance(
            origin: isLoginItem ? .loginItem : .user, isHidden: isHiddenLaunch)
    }

    /// Arms the launch pass that brings up the VMs marked to start
    /// automatically, once per process.
    ///
    /// Every posture arms the same pass; the latch is what keeps a later
    /// arming from running it a second time.
    func armAutoStartPass() {
        guard !hasArmedAutoStartPass else { return }
        hasArmedAutoStartPass = true
        Task { @MainActor in
            let marked = await self.libraryLoad?.value ?? []
            await self.viewModel.startAutomaticVMsForLaunch(marked)
        }
    }

    /// Never. The `willClose` reconcile decides between the Dock icon, a
    /// headless status-item app, and quitting, on a presence answer that counts
    /// miniaturized windows and untracked panels AppKit's own last-window rule
    /// does not — letting AppKit terminate too would double-fire on a different
    /// predicate.
    package func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    package func applicationDidUnhide(_ notification: Notification) {
        lifecycle.noteDidUnhide()
    }

    package func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool)
        -> Bool
    {
        // AppKit's flag counts no `NSPanel` — the About panel is one Kernova
        // counts — and is computed before `handleReopen()` takes the app out
        // of hiding. Returning `true` lets AppKit deminiaturize a miniaturized
        // window, which `handleReopen()` counts as present.
        lifecycle.handleReopen()
        return true
    }

    package func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Show Library", action: #selector(summonLibraryFromDockMenu), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// The Dock menu's "Show Library", routed through the summon path rather
    /// than `showLibrary(_:)`: unlike ⌘0 (only reachable while the app is
    /// already active), a Dock-menu selection can arrive while Kernova is
    /// inactive and needs the summon path's activation request.
    @objc private func summonLibraryFromDockMenu(_: Any?) {
        lifecycle.summonUserInterface()
    }

    package func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        NSApplication.TerminateReply(termination.handleTerminationRequest())
    }

    package func applicationWillTerminate(_ notification: Notification) {
        termination.handleWillTerminate()
    }

    /// The app menu's honest "Quit Kernova" — an unconditional full quit,
    /// identical to the status item's Quit.
    @objc func quitCompletely(_ sender: Any?) {
        termination.requestFullQuit()
    }

    // MARK: - Open URLs (Finder double-click / dock icon drop / kernova link)

    /// Takes both of what Launch Services delivers here: `.kernova` bundles to
    /// import, and `kernova:` links the automation front door answers.
    ///
    /// Only the files present the library here. A link opens the one surface it
    /// asked for — its own activation and its verb's hook are what put that on
    /// screen — and dragging the library up behind it would surface a window
    /// nobody asked for, the same rule the status item's per-VM open follows.
    /// A link with a refusal to show summons the library itself.
    package func application(_ application: NSApplication, open urls: [URL]) {
        let (links, files) = VMURLRoute.partition(urls)
        for link in links {
            lifecycle.openAutomationLink(link)
        }
        guard !files.isEmpty else { return }
        importVMs(from: files)
        // A double-click while the app is already resident+headless gets no
        // reopen — macOS sends no reopen for a document open — so surface the
        // window here. Presentation only: a launch document open and a later
        // one delivered to the running app are both Launch-Services-mediated
        // and already carry their own activation request, per
        // `presentSummonedInterface`'s invariant.
        lifecycle.presentSummonedInterface()
    }

    /// Filters to `.kernova` bundles and imports the batch, once the library is
    /// readable.
    ///
    /// The wait is what makes a Finder open of a bundle *already in the library*
    /// still resolve to "select the existing VM": a launch document arrives
    /// while the first read is in flight, and `importVMs(fromDroppedURLs:)`
    /// dedups by UUID against the library's rows — against an empty library it would
    /// copy the bundle a second time instead. Awaiting a finished load resumes
    /// on the next tick, so an open arriving later is unaffected.
    private func importVMs(from urls: [URL]) {
        Task { @MainActor in
            _ = await self.libraryLoad?.value
            self.viewModel.importVMs(fromDroppedURLs: urls)
        }
    }

    // MARK: - Scripting (Apple events)

    override var scriptingGateway: VMScriptingGateway? { lifecycle.scriptingGateway }

    // MARK: - Menu Actions

    @objc func newVM(_ sender: Any?) {
        windows.showLibrary(bringToFront: true)
        viewModel.libraryWindowPresenter?.presentCreationWizard()
    }

    @objc func openVMsFolder(_ sender: Any?) {
        do {
            // Resolving `vmsDirectory` creates the folder when missing, so the
            // command also works on a fresh install with an empty library.
            NSWorkspace.shared.open(try viewModel.storageService.vmsDirectory)
        } catch {
            Self.logger.log(
                .error,
                "openVMsFolder: failed to resolve VMs directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc func checkConfigFiles(_ sender: Any?) {
        windows.showConfigCheck(.user)
    }

    @objc func showLibrary(_ sender: Any?) {
        windows.showLibrary(bringToFront: true)
    }

    @objc func showAboutPanel(_ sender: Any?) {
        #if DEBUG
        let buildNumber = viewModel.library.bundleProducts.buildNumber ?? ""
        let versionAnnotation = buildNumber.isEmpty ? "Debug" : "\(buildNumber) | Debug"
        NSApp.orderFrontStandardAboutPanel(options: [.version: versionAnnotation])
        #else
        NSApp.orderFrontStandardAboutPanel(sender)
        #endif
    }

    /// Shows Settings on the pane it was last left on.
    @objc func showSettings(_ sender: Any?) {
        windows.showSettings()
    }

    // MARK: - VM Actions

    @objc func startVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        Task { await viewModel.start(instance) }
    }

    @objc func startVMInRecovery(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.requestStartInRecovery(instance)
    }

    @objc func pauseVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        Task { await viewModel.pause(instance) }
    }

    @objc func resumeVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        Task { await viewModel.resume(instance) }
    }

    /// One call for every state the stop slot stands for: the consent a
    /// suspended VM's discard needs arrives as the verb's own refusal, which
    /// raises the sheet.
    @objc func stopVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        Task { await viewModel.stop(instance) }
    }

    @objc func forceStopVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.requestForceStop(instance)
    }

    @objc func saveVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        Task { await viewModel.save(instance) }
    }

    @objc func takeSnapshot(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.requestTakeSnapshot(instance)
    }

    /// Reverts to the snapshot the sending "Revert to Snapshot" item names.
    @objc func revertToSnapshot(_ sender: Any?) {
        guard let ref = (sender as? NSMenuItem)?.representedObject as? SnapshotMenuRef else {
            return
        }
        viewModel.requestRevert(ref.instance, to: ref.snapshot)
    }

    @objc func attachUSBAccessory(_ sender: Any?) {
        guard let ref = (sender as? NSMenuItem)?.representedObject as? USBAccessoryMenuRef else {
            return
        }
        viewModel.attachUSBAccessory(ref.registryID, to: ref.instance)
    }

    @objc func detachUSBAccessory(_ sender: Any?) {
        guard let ref = (sender as? NSMenuItem)?.representedObject as? USBAccessoryMenuRef,
            let deviceID = ref.deviceID
        else { return }
        viewModel.detachUSBAccessory(deviceID: deviceID, from: ref.instance)
    }

    @objc func toggleSettingsPane(_ sender: Any?) {
        guard let instance = activeInstance,
            viewModel.capabilities.isAvailable(.toggleSettingsPane, on: instance)
        else { return }
        instance.detailPaneMode = instance.detailPaneMode == .settings ? .display : .settings
    }

    @objc func renameVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        windows.showLibrary(bringToFront: true)
        windows.revealLibrarySidebar()
        viewModel.renameVMInSidebar(instance)
    }

    @objc func findVM(_ sender: Any?) {
        windows.focusLibrarySearch()
    }

    @objc func cloneVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.cloneVM(instance)
    }

    @objc func cloneVMAlternate(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.cloneVMAsAlternate(instance)
    }

    @objc func deleteVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.requestDelete(instance)
    }

    @objc func deleteImmediatelyVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.requestDelete(instance, permanently: true)
    }

    @objc func showVMInFinder(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.showVMInFinder(instance)
    }

    @objc func showClipboard(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        windows.showClipboard(for: instance)
    }

    @objc func toggleGuestAgentDisk(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        Task { @MainActor [viewModel] in await viewModel.toggleGuestAgentDisk(on: instance) }
    }

    // MARK: - Display Window (Pop-Out / Fullscreen)

    @objc func togglePopOut(_ sender: Any?) {
        guard let instance = target(of: sender) else { return }
        windows.displayPlacement.togglePopOut(for: instance)
    }

    /// Brings the VM's display window forward, reopening it (in its persisted
    /// style) if the user previously closed it while the VM ran headless.
    @objc func showDisplayWindow(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        windows.displayPlacement.showDisplayWindow(for: instance)
    }

    @objc func toggleFullscreen(_ sender: Any?) {
        guard let instance = target(of: sender) else { return }
        windows.displayPlacement.toggleFullscreen(for: instance)
    }

    // MARK: - Menu Validation

    /// AppKit asks a menu item's *target*, and a nil-target item resolves to
    /// this delegate — so the answer is forwarded to the menu's own owner.
    package func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        mainMenu.validate(menuItem)
    }
}

// MARK: - AppLaunchHosting

extension AppDelegate: AppLaunchHosting {
    /// Awaits the app's first library read, so an intent that arrives while it is
    /// still in flight resolves against a landed library.
    func awaitLibraryReady() async { _ = await libraryLoad?.value }

    func requestFullQuit() { termination.requestFullQuit() }
}

// MARK: - Display Boot Geometry

extension AppDelegate {
    fileprivate func displayBootSurface(for instance: VMInstance) -> DisplayBootSurface? {
        switch instance.hostState.displayPreference {
        case .popOut:
            // `start` opens the display window before consulting this, and
            // `setFrameAutosaveName` restores the saved frame at init, so the
            // content view already carries the size the guest will fill.
            guard let window = windows.displayPlacement.window(for: instance.instanceID),
                let content = window.contentView
            else { return nil }
            return surface(pointSize: content.bounds.size, scale: window.backingScaleFactor)
        case .fullscreen:
            // The screen, never the window: the fullscreen transition is still
            // in flight, so the window's frame is the pre-transition one.
            // Fullscreen content sits below the camera housing, so the notch
            // strip (`safeAreaInsets.top`) is not part of the surface.
            guard
                let screen = windows.displayPlacement.preferredScreenForFullscreen(of: instance)
            else { return nil }
            var size = screen.frame.size
            size.height -= screen.safeAreaInsets.top
            return surface(pointSize: size, scale: screen.backingScaleFactor)
        case .inline:
            return windows.libraryDetailContainer?.displayBootSurface()
        }
    }

    private func surface(pointSize: CGSize, scale: CGFloat) -> DisplayBootSurface? {
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }
        return DisplayBootSurface(pointSize: pointSize, backingScaleFactor: scale)
    }
}
