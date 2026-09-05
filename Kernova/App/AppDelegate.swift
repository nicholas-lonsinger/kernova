import AppIntents
import Cocoa
import KernovaKit
import os

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// The one owner of which user-facing windows exist, and whether any is on
    /// screen.
    private let windows: AppWindowRegistry
    /// The one owner of the menu bar — construction, the open-time rebuilds, and
    /// menu-item validation. Strongly held: `NSMenu.delegate` is weak, and this
    /// is the delegate of every menu whose opening it answers for.
    private let mainMenu: MainMenuController
    /// The one owner of what the process is when no window is on screen, and of
    /// what a launch, a reopen and a summon do to it.
    ///
    /// The mode's single branch point: assigned once in `init` to the resident
    /// app's ``AppResidencyController`` or the test host's
    /// ``TestHostResidencyController``, so nothing downstream forks on which
    /// process this is.
    private let lifecycle: any AppResidencyHosting
    /// The one owner of what a quit does: the classification latches, the
    /// termination gate, the save pass, and the TCC relaunch. Strongly held:
    /// `NSAppleEventManager` does not retain the quit-event handler this
    /// installs.
    private let termination: AppTerminationController
    private let viewModel: VMLibraryViewModel
    /// The library's first read from disk, started in
    /// `applicationWillFinishLaunching`.
    ///
    /// Retained so `application(_:open:)` can wait for it: a Finder open that
    /// launched the app is delivered while the read is still in flight.
    private var libraryLoad: Task<Void, Never>?
    /// Latched once ``armAutoStartPass()`` has armed the pass, so the first
    /// interactive bring-up of an automation-launched process runs it and no
    /// later one runs it a second time.
    private var hasArmedAutoStartPass = false
    /// Whether `applicationOpenUntitledFile(_:)` ran, latched before
    /// `applicationDidFinishLaunching` reads it — see ``AppResidencyController/launchProvenance(openedUntitledFile:openedDocuments:hasOpenAppleEvent:openEventIsDirect:isHiddenLaunch:isLoginItemLaunch:isDefaultLaunch:)``.
    private var didOpenUntitledFile = false
    /// Whether `application(_:open:)` ran with a launch document, latched the
    /// same way.
    private var didOpenLaunchDocuments = false

    private static let logger = Logger(subsystem: "app.kernova", category: "AppDelegate")

    /// Returns the VM that menu actions should target: the display or clipboard
    /// window's VM if its window is key, otherwise the sidebar-selected VM.
    private var activeInstance: VMInstance? {
        NSApp.keyWindow.flatMap(windows.instance(forKeyWindow:)) ?? viewModel.selectedInstance
    }

    /// The VM a nil-target action acts on: the one the sending item names, else
    /// ``activeInstance``.
    ///
    /// The sidebar's context menu dispatches its display toggles down the
    /// responder chain, and its row is not always the key window's VM — naming
    /// the VM on the item is what keeps the click acting on the row it came
    /// from. Every other sender carries none and gets the key-window rule.
    private func target(of sender: Any?) -> VMInstance? {
        (sender as? NSMenuItem)?.representedObject as? VMInstance ?? activeInstance
    }

    // MARK: - Entry Point

    static func main() {
        let isTestHost = ProcessInfo.processInfo.isRunningXCTests
        let app = NSApplication.shared

        // `NSApplication.delegate` is weak, so the local binding retains the
        // delegate for the process lifetime (`run()` never returns).
        let delegate = AppDelegate(isTestHost: isTestHost)
        app.delegate = delegate
        app.run()
    }

    init(isTestHost: Bool, preferences: AppPreferences = .shared) {
        let viewModel = VMLibraryViewModel()
        self.viewModel = viewModel
        let windows = AppWindowRegistry(
            viewModel: viewModel,
            displayPlacement: VMDisplayPlacementController(viewModel: viewModel))
        self.windows = windows
        // The one place the mode is branched on. Everything below takes the
        // residency it produced.
        let lifecycle: any AppResidencyHosting =
            isTestHost
            ? TestHostResidencyController(viewModel: viewModel, windows: windows)
            : AppResidencyController(
                viewModel: viewModel, preferences: preferences, windows: windows)
        self.lifecycle = lifecycle
        self.mainMenu = MainMenuController(
            viewModel: viewModel, preferences: preferences,
            hasSoftQuit: lifecycle.softQuit != nil)
        self.termination = AppTerminationController(viewModel: viewModel)

        super.init()

        lifecycle.host = self
        termination.residency = lifecycle.softQuit
        windows.residency = lifecycle
        mainMenu.host = self
        viewModel.onSurfaceLibrary = { [weak lifecycle] in
            lifecycle?.presentSummonedInterface()
        }
        viewModel.onOpenDisplayWindow = { [weak self] instance in
            self?.windows.displayPlacement.showDisplayWindow(for: instance)
        }
        viewModel.displayBootGeometryProvider = self
    }

    // MARK: - NSApplicationDelegate

    /// Starts the library read.
    ///
    /// Deliberately here and not in `applicationDidFinishLaunching`: AppKit
    /// delivers a launch document's `application(_:open:)` *between* the two, and
    /// that path waits on `libraryLoad` — left unset, the wait would silently
    /// pass through and re-import a bundle already in the library. Starting the
    /// read costs nothing here; the task body only runs once the main actor
    /// yields, and its file I/O is off the main actor either way.
    func applicationWillFinishLaunching(_ notification: Notification) {
        libraryLoad = Task { @MainActor [viewModel] in await viewModel.startLibrary() }
        // Before `lifecycle.start(provenance:)`, so an intent delivered during
        // launch resolves against a published gateway.
        lifecycle.registerIntentGateway()
    }

    /// Records that Launch Services asked for the app's default surface.
    ///
    /// AppKit sends this while handling the launch `kAEOpenApplication`, which
    /// it does *between* `applicationWillFinishLaunching` and
    /// `applicationDidFinishLaunching` — so the latch is always settled by the
    /// time `readLaunchProvenance` reads it. The window itself is not opened
    /// here: `AppResidencyController.start(provenance:)` owns presentation, and
    /// answering `true` only reports
    /// that the request was taken.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        didOpenUntitledFile = true
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainMenu.install()

        // Reclaim orphaned clipboard staging files from a previous run or crash —
        // every label family under the shared parent (`host`, per-VM `host-<vm>`
        // receive roots, `host-send-<vm>` outbound-archive roots). The staged file
        // URL must outlive the clipboard window (paste-after-close), so staging
        // never sweeps on close — only here, before any clipboard use.
        ClipboardFileStaging.reclaimAll()

        // Same reason, for the files a promise drag writes before it is offered:
        // the guest pulls a queued drop only when its turn comes, so launch is
        // the one moment nothing staged can still be owed to it.
        DropPromiseStaging.reclaimAll()

        termination.install()

        lifecycle.start(provenance: readLaunchProvenance(notification))
    }

    /// Reads the launch's raw signals and classifies them.
    ///
    /// The only place any of them is read: everything downstream takes the
    /// decided ``AppResidencyController/LaunchProvenance``, so a second front
    /// door (a CLI, #309) marks its own launches rather than adding a second
    /// detection mechanism.
    private func readLaunchProvenance(
        _ notification: Notification
    ) -> AppResidencyController.LaunchProvenance {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isOpenEvent =
            event.map { descriptor in
                descriptor.eventClass == AEEventClass(kCoreEventClass)
                    && (descriptor.eventID == AEEventID(kAEOpenApplication)
                        || descriptor.eventID == AEEventID(kAEOpenDocuments))
            } ?? false
        let isLoginItem =
            event.map { descriptor in
                descriptor.eventID == AEEventID(kAEOpenApplication)
                    && descriptor.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                        == keyAELaunchedAsLogInItem
            } ?? false
        // Absent means unknown, and unknown resolves to the interactive launch.
        let defaultLaunchKey = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool
        let isDefaultLaunch = defaultLaunchKey ?? true

        // The verdict alone cannot say which signal produced it, and a launch
        // that arrives with an open event no person sent looks identical to a
        // double-click in everything but these.
        let eventID = event.map { String(describing: $0.eventID) } ?? "none"
        let sender =
            event?.attributeDescriptor(forKeyword: keySenderPIDAttr).map { String($0.int32Value) }
            ?? "none"
        // A launch the app itself asked Launch Services for is `kAEDirectCall`;
        // a source that positively names another process sent the open event on
        // someone else's behalf. An absent or unreadable source (`int32Value` is
        // 0, `kAEUnknownSource`, on any coercion failure) is not evidence of
        // either, and unknown resolves toward the person.
        let eventSource = event?.attributeDescriptor(forKeyword: keyEventSourceAttr)?.int32Value
        let isDirectOpen =
            eventSource.map { $0 == Int32(kAEDirectCall) || $0 == Int32(kAEUnknownSource) }
            ?? true
        let source = eventSource.map { String($0) } ?? "none"
        let isHiddenLaunch = NSApp.isHidden
        Self.logger.notice(
            "Launch signals — openEvent=\(isOpenEvent, privacy: .public) eventID=\(eventID, privacy: .public) senderPID=\(sender, privacy: .public) eventSource=\(source, privacy: .public) directOpen=\(isDirectOpen, privacy: .public) loginItem=\(isLoginItem, privacy: .public) defaultLaunchKey=\(defaultLaunchKey.map(String.init) ?? "absent", privacy: .public) untitled=\(self.didOpenUntitledFile, privacy: .public) documents=\(self.didOpenLaunchDocuments, privacy: .public) hidden=\(isHiddenLaunch, privacy: .public) active=\(NSApp.isActive, privacy: .public)"
        )

        return AppResidencyController.launchProvenance(
            openedUntitledFile: didOpenUntitledFile,
            openedDocuments: didOpenLaunchDocuments,
            hasOpenAppleEvent: isOpenEvent,
            openEventIsDirect: isDirectOpen,
            isHiddenLaunch: isHiddenLaunch,
            isLoginItemLaunch: isLoginItem,
            isDefaultLaunch: isDefaultLaunch)
    }

    /// Arms the launch pass that brings up the VMs marked to start
    /// automatically, once per process.
    ///
    /// Deferred rather than skipped for an automation launch: a nightly
    /// automation must not cost the user *Start automatically on launch* for the
    /// rest of the process's life, so the first interactive bring-up — a reopen,
    /// a document open, a status-item summon — runs the pass it never got. The
    /// pass is safe to run late because `VMLibraryViewModel.autoStartStep`
    /// re-reads each instance when it acts and skips one already running.
    func armAutoStartPass() {
        guard !hasArmedAutoStartPass else { return }
        hasArmedAutoStartPass = true
        termination.registerLaunchWork(
            Task { @MainActor in
                await self.libraryLoad?.value
                await self.viewModel.startAutomaticVMsForLaunch()
            })
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        lifecycle.terminatesAfterLastWindowClosed
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        lifecycle.noteWillBecomeActive()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
        -> Bool
    {
        lifecycle.handleReopen(hasVisibleWindows: flag)
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        termination.handleTerminationRequest()
    }

    func applicationWillTerminate(_ notification: Notification) {
        termination.handleWillTerminate()
    }

    /// The app menu's honest "Quit Kernova" — an unconditional full quit,
    /// identical to the status item's Quit.
    @objc func quitCompletely(_ sender: Any?) {
        termination.requestFullQuit()
    }

    // MARK: - Open URLs (Finder double-click / dock icon drop)

    func application(_ application: NSApplication, open urls: [URL]) {
        // A launch document arrives between `applicationWillFinishLaunching` and
        // `applicationDidFinishLaunching`, so this latch is settled in time to
        // classify the launch — a double-clicked bundle is a person asking, and
        // carries no `kAEOpenApplication` of its own to say so.
        didOpenLaunchDocuments = true
        importVMs(from: urls)
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
    /// dedups by UUID against `instances` — against an empty library it would
    /// copy the bundle a second time instead. Awaiting a finished load resumes
    /// on the next tick, so an open arriving later is unaffected.
    ///
    /// `importVMs(fromDroppedURLs:)` then reserves every destination in the batch
    /// without suspending and runs the copies concurrently, so two overlapping
    /// triggers still see each other's phantoms.
    private func importVMs(from urls: [URL]) {
        Task { @MainActor in
            await self.libraryLoad?.value
            self.viewModel.importVMs(fromDroppedURLs: urls)
        }
    }

    // MARK: - Menu Actions

    @objc func newVM(_ sender: Any?) {
        windows.showLibrary(bringToFront: true)
        viewModel.presenter?.presentCreationWizard()
    }

    @objc func openVMsFolder(_ sender: Any?) {
        do {
            // Resolving `vmsDirectory` creates the folder when missing, so the
            // command also works on a fresh install with an empty library.
            NSWorkspace.shared.open(try viewModel.storageService.vmsDirectory)
        } catch {
            Self.logger.error(
                "openVMsFolder: failed to resolve VMs directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc func showLibrary(_ sender: Any?) {
        windows.showLibrary(bringToFront: true)
    }

    @objc func showAboutPanel(_ sender: Any?) {
        #if DEBUG
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let versionAnnotation = buildNumber.isEmpty ? "Debug" : "\(buildNumber) | Debug"
        NSApp.orderFrontStandardAboutPanel(options: [.version: versionAnnotation])
        #else
        NSApp.orderFrontStandardAboutPanel(sender)
        #endif
    }

    @objc func showSettings(_ sender: Any?) {
        windows.showSettings(sender)
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

    @objc func stopVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        // Require explicit confirmation before discarding saved state
        if instance.isColdPaused {
            viewModel.requestForceStop(instance)
        } else {
            Task { await viewModel.stop(instance) }
        }
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

    @objc func toggleSettingsPane(_ sender: Any?) {
        guard let instance = activeInstance,
            instance.hasActiveDisplay
        else { return }
        instance.detailPaneMode = instance.detailPaneMode == .settings ? .display : .settings
    }

    @objc func renameVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        // Reveal the sidebar first so the inline rename always lands on a visible
        // row.
        windows.showLibrary(bringToFront: true)
        windows.revealLibrarySidebar()
        viewModel.renameVMInSidebar(instance)
    }

    @objc func cloneVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.cloneVM(instance)
    }

    @objc func cloneVMAlternate(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.cloneVMWithOppositeMachineIdentity(instance)
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
        NSWorkspace.shared.activateFileViewerSelecting([instance.bundleURL])
    }

    @objc func showClipboard(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        windows.showClipboard(for: instance)
    }

    @objc func toggleGuestAgentDisk(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        // Same single source of truth as `MainMenuController.validate`, so the
        // action can never disagree with the title the user clicked.
        let model = GuestAgentDiskMenuItem.model(
            status: instance.agentStatus,
            isInstallerMounted: instance.hasGuestAgentInstallerMounted)
        switch model.action {
        case .eject:
            viewModel.unmountGuestAgentInstaller(from: instance)
        case .mount(let purpose):
            viewModel.mountGuestAgentInstaller(on: instance, purpose: purpose)
        }
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
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        mainMenu.validate(menuItem)
    }
}

// MARK: - AppLaunchHosting

extension AppDelegate: AppLaunchHosting {
    /// Awaits the app's first library read, so an intent that arrives while it is
    /// still in flight resolves against a landed library.
    func awaitLibraryReady() async { await libraryLoad?.value }

    func requestFullQuit() { termination.requestFullQuit() }
}

// MARK: - MainMenuHosting

extension AppDelegate: MainMenuHosting {
    func menuCommandTarget(of sender: Any?) -> VMInstance? { target(of: sender) }
}

// MARK: - DisplayBootGeometryProviding

extension AppDelegate: DisplayBootGeometryProviding {
    func displayBootSurface(for instance: VMInstance) -> DisplayBootSurface? {
        switch instance.configuration.displayPreference {
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
