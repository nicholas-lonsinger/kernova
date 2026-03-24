import Cocoa
import os
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {

    private var mainWindowController: MainWindowController?
    private var viewModel: VMLibraryViewModel!
    private var pendingOpenURLs: [URL] = []
    private var serialConsoleWindows: [UUID: SerialConsoleWindowController] = [:]
    private var serialConsoleObservers: [UUID: Any] = [:]
    private var clipboardWindows: [UUID: ClipboardWindowController] = [:]
    private var clipboardObservers: [UUID: Any] = [:]
    private var displayWindows: [UUID: VMDisplayWindowController] = [:]
    private var displayWindowObservers: [UUID: Any] = [:]
    private var serialConsoleMenuItem: NSMenuItem!
    private var clipboardMenuItem: NSMenuItem!
    /// Set in `applicationWillBecomeActive` and read in `applicationShouldHandleReopen`
    /// to distinguish a dock click that activates the app from one on an already-active app.
    ///
    /// Cleared in two places: synchronously in `applicationShouldHandleReopen` (for dock clicks)
    /// and asynchronously via Task (for non-dock activations like Cmd-Tab where the reopen
    /// callback never fires). The synchronous clear prevents rapid successive dock clicks from
    /// reading a stale `true` before the async Task has run.
    private var wasJustActivated = false

    private static let logger = Logger(subsystem: "com.kernova.app", category: "AppDelegate")

    /// Returns the VM that menu actions should target: the display or serial console
    /// window's VM if its window is key, otherwise the sidebar-selected VM.
    private var activeInstance: VMInstance? {
        if let keyWindow = NSApp.keyWindow {
            if let controller = displayWindows.values.first(where: { $0.window === keyWindow }) {
                return controller.instance
            }
            if let controller = serialConsoleWindows.values.first(where: { $0.window === keyWindow }) {
                return controller.instance
            }
            if let controller = clipboardWindows.values.first(where: { $0.window === keyWindow }) {
                return controller.instance
            }
        }
        return viewModel.selectedInstance
    }

    // MARK: - Entry Point

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewModel = VMLibraryViewModel()
        viewModel.onOpenDisplayWindow = { [weak self] instance in
            self?.openDisplayWindow(for: instance)
        }
        setupMainMenu()

        let windowController = MainWindowController(viewModel: viewModel)
        windowController.showWindow(nil)
        mainWindowController = windowController

        // Process any URLs received before the view model was ready
        for url in pendingOpenURLs {
            viewModel.importVM(from: url)
        }
        pendingOpenURLs.removeAll()

        observeForTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let hasActiveVMs = viewModel.instances.contains(where: \.isKeepingAppAlive)

        // Stay alive if VMs are active or display windows still exist
        if hasActiveVMs || !displayWindows.isEmpty {
            Self.logger.debug("applicationShouldTerminateAfterLastWindowClosed: false (activeVMs=\(hasActiveVMs, privacy: .public), displayWindows=\(self.displayWindows.count, privacy: .public))")
            return false
        }

        Self.logger.debug("applicationShouldTerminateAfterLastWindowClosed: true")
        return true
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        Self.logger.debug("applicationWillBecomeActive: setting wasJustActivated")
        wasJustActivated = true
        // Clear after the current event cycle so the flag doesn't remain stale
        // for non-dock activations (e.g., Cmd-Tab, clicking a window) where
        // applicationShouldHandleReopen is never called. When it IS called
        // (dock clicks), it runs synchronously during the same event dispatch,
        // so it reads the flag before this Task body executes.
        //
        // Note: DispatchQueue.main.async cannot be used here — its @Sendable
        // closure cannot access @MainActor-isolated state under strict concurrency.
        Task { @MainActor [weak self] in
            self?.wasJustActivated = false
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let justActivated = wasJustActivated
        wasJustActivated = false  // Synchronous clear — see wasJustActivated doc comment

        if !flag {
            showLibrary(nil)
        } else if !justActivated && isMainWindowDismissed {
            Self.logger.debug("applicationShouldHandleReopen: reopening dismissed library window")
            showLibrary(nil)
        } else if justActivated {
            Self.logger.debug("applicationShouldHandleReopen: suppressed (initial activation with visible windows)")
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Show Library", action: #selector(showLibrary(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cancel all preparing operations and remove phantom rows before terminating
        viewModel.instances.removeAll { instance in
            guard instance.isPreparing else { return false }

            Self.logger.notice("Terminating: cancelling preparing operation for '\(instance.name, privacy: .public)'")
            instance.preparingState?.task.cancel()
            // Best effort — in-flight copy may still be writing (FileManager.copyItem is not interruptible)
            do {
                try FileManager.default.trashItem(at: instance.bundleURL, resultingItemURL: nil)
            } catch {
                Self.logger.warning("Failed to clean up partial bundle for '\(instance.name, privacy: .public)' during termination: \(error.localizedDescription, privacy: .public)")
            }
            return true
        }

        // Save VMs that have a live virtual machine; cold-paused VMs already have state on disk
        let runningInstances = viewModel.instances.filter {
            ($0.status == .running || $0.status == .paused) && $0.virtualMachine != nil
        }

        guard !runningInstances.isEmpty else {
            return .terminateNow
        }

        Task { @MainActor in
            for instance in runningInstances {
                do {
                    try await viewModel.trySave(instance)
                    viewModel.saveConfiguration(for: instance)
                } catch {
                    Self.logger.error("Failed to save '\(instance.name, privacy: .public)' during termination: \(error.localizedDescription, privacy: .public)")
                    do {
                        try await viewModel.tryForceStop(instance)
                    } catch {
                        Self.logger.error("Failed to force-stop '\(instance.name, privacy: .public)' during termination: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    // MARK: - Open URLs (Finder double-click / dock icon drop)

    func application(_ application: NSApplication, open urls: [URL]) {
        let vmURLs = urls.filter { $0.pathExtension == VMStorageService.bundleExtension }

        guard let viewModel else {
            // Called before applicationDidFinishLaunching — queue for later
            pendingOpenURLs.append(contentsOf: vmURLs)
            return
        }

        for url in vmURLs {
            viewModel.importVM(from: url)
        }
    }

    // MARK: - Menu Actions

    @objc func newVM(_ sender: Any?) {
        viewModel.showCreationWizard = true
    }

    @objc func showLibrary(_ sender: Any?) {
        showLibraryWindow(bringToFront: true)
    }

    private func showLibraryWindow(bringToFront: Bool) {
        if let existingWindow = mainWindowController?.window {
            if bringToFront {
                Self.logger.debug("showLibrary: focusing existing window")
                NSApp.activate()
                existingWindow.makeKeyAndOrderFront(nil)
            } else {
                Self.logger.debug("showLibrary: showing existing window in background")
                existingWindow.orderBack(nil)
            }
        } else {
            Self.logger.notice("showLibrary: recreating main window controller")
            let windowController = MainWindowController(viewModel: viewModel)
            if bringToFront {
                windowController.showWindow(nil)
            } else {
                windowController.showWindowInBackground()
            }
            mainWindowController = windowController
        }
    }

    // MARK: - VM Actions

    @objc func startVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        Task { await viewModel.start(instance) }
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
            viewModel.confirmForceStop(instance)
        } else {
            viewModel.stop(instance)
        }
    }

    @objc func forceStopVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.confirmForceStop(instance)
    }

    @objc func saveVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        Task { await viewModel.save(instance) }
    }

    @objc func renameVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.renameVM(instance)
    }

    @objc func cloneVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.cloneVM(instance)
    }

    @objc func deleteVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.confirmDelete(instance)
    }

    // MARK: - Serial Console

    @objc func showSerialConsole(_ sender: Any?) {
        guard let instance = activeInstance,
              instance.canShowSerialConsole else { return }

        if let existing = serialConsoleWindows[instance.instanceID] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = SerialConsoleWindowController(instance: instance)
        let vmID = instance.instanceID
        serialConsoleWindows[vmID] = controller

        // Clean up when window closes
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                if let token = self?.serialConsoleObservers.removeValue(forKey: vmID) {
                    NotificationCenter.default.removeObserver(token)
                }
                self?.serialConsoleWindows.removeValue(forKey: vmID)
                self?.terminateIfIdle()
            }
        }
        serialConsoleObservers[vmID] = token

        controller.showWindow(nil)
    }

    // MARK: - Clipboard

    @objc func showClipboard(_ sender: Any?) {
        guard let instance = activeInstance,
              instance.canShowClipboard else { return }

        if let existing = clipboardWindows[instance.instanceID] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = ClipboardWindowController(instance: instance)
        let vmID = instance.instanceID
        clipboardWindows[vmID] = controller

        // Clean up when window closes
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                if let token = self?.clipboardObservers.removeValue(forKey: vmID) {
                    NotificationCenter.default.removeObserver(token)
                }
                self?.clipboardWindows.removeValue(forKey: vmID)
                self?.terminateIfIdle()
            }
        }
        clipboardObservers[vmID] = token

        controller.showWindow(nil)
    }

    // MARK: - Removable Media

    @objc func showRemovableMedia(_ sender: Any?) {
        guard let instance = activeInstance,
              instance.canAttachUSBDevices else { return }

        let menu = NSMenu()
        let menuItem = NSMenuItem()
        menuItem.view = NSHostingView(
            rootView: RemovableMediaPopoverView(instance: instance, viewModel: viewModel)
        )
        menu.addItem(menuItem)

        // Position the menu at the click location. NSMenu handles coordinate
        // transformation internally, avoiding the toolbar view hierarchy issues
        // that made NSPopover positioning unreliable.
        if let event = NSApp.currentEvent, let contentView = event.window?.contentView {
            menu.popUp(positioning: nil, at: event.locationInWindow, in: contentView)
        }
    }

    // MARK: - Display Window (Pop-Out / Fullscreen)

    @objc func togglePopOut(_ sender: Any?) {
        guard let instance = activeInstance else { return }

        if let existing = displayWindows[instance.instanceID] {
            existing.window?.close()
            return
        }

        instance.configuration.displayPreference = .popOut
        viewModel.saveConfiguration(for: instance)
        openDisplayWindow(for: instance, enterFullscreen: false)
    }

    @objc func toggleFullscreen(_ sender: Any?) {
        guard let instance = activeInstance else { return }

        if let existing = displayWindows[instance.instanceID] {
            existing.window?.toggleFullScreen(nil)
            return
        }

        instance.configuration.displayPreference = .fullscreen
        viewModel.saveConfiguration(for: instance)
        openDisplayWindow(for: instance, enterFullscreen: true)
    }

    private func openDisplayWindow(for instance: VMInstance) {
        openDisplayWindow(for: instance, enterFullscreen: instance.configuration.displayPreference == .fullscreen)
    }

    private func openDisplayWindow(for instance: VMInstance, enterFullscreen: Bool) {
        let vmID = instance.instanceID

        // Already showing a display window for this VM
        guard displayWindows[vmID] == nil else { return }

        let controller = VMDisplayWindowController(
            instance: instance,
            enterFullscreen: enterFullscreen,
            onResume: { [weak self] in
                guard let self else { return }
                Task { await self.viewModel.resume(instance) }
            },
            onSaveConfiguration: { [weak self] in
                self?.viewModel.saveConfiguration(for: instance)
            }
        )
        displayWindows[vmID] = controller

        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self] notification in
            // Capture window state synchronously before the Task runs (it may change).
            // The observer closure is @Sendable (nonisolated), but queue: .main guarantees
            // main thread execution, making MainActor.assumeIsolated safe.
            let window = notification.object as? NSWindow
            dispatchPrecondition(condition: .onQueue(.main))
            let (wasKeyWindow, appWasActive) = MainActor.assumeIsolated {
                (window?.isKeyWindow ?? false, NSApp.isActive)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let token = self.displayWindowObservers.removeValue(forKey: vmID) {
                    NotificationCenter.default.removeObserver(token)
                }
                if let controller = self.displayWindows.removeValue(forKey: vmID) {
                    // Always remember which display the VM was on
                    if let displayID = controller.lastDisplayID {
                        instance.configuration.lastFullscreenDisplayID = displayID
                    }

                    if !controller.closedProgrammatically {
                        // User manually closed the display window
                        instance.configuration.displayPreference = .inline
                        Self.logger.debug("Cleared displayPreference for '\(instance.name, privacy: .public)' (user closed display window)")
                    }

                    self.viewModel.saveConfiguration(for: instance)

                    if controller.closedProgrammatically {
                        // VM stopped/errored/cold-paused — check if app should quit
                        self.terminateIfIdle()
                        return
                    }
                }
                self.viewModel.selectedID = vmID

                // Restore library window for user-initiated close:
                // - Key + active app: user deliberately closed display → focus library
                // - App not active: user closed display while elsewhere → show library in background
                // - Active but not key: user is in another Kernova window → no action needed
                if wasKeyWindow && appWasActive {
                    self.showLibrary(nil)
                } else if !appWasActive {
                    self.showLibraryWindow(bringToFront: false)
                }
            }
        }
        displayWindowObservers[vmID] = token

        // For fullscreen: position on the remembered display so toggleFullScreen picks the correct screen
        if enterFullscreen {
            if let screen = targetScreen(for: instance),
               let window = controller.window {
                let frame = screen.frame
                let centeredOrigin = NSPoint(
                    x: frame.midX - window.frame.width / 2,
                    y: frame.midY - window.frame.height / 2
                )
                window.setFrameOrigin(centeredOrigin)
            }
        }

        controller.showWindow(nil)
    }

    /// Returns the best screen for entering fullscreen, using a fallback chain:
    /// 1. The display the VM was last fullscreen on (persisted in configuration)
    /// 2. The library window's current display
    /// 3. The primary display
    private func targetScreen(for instance: VMInstance) -> NSScreen? {
        if let savedID = instance.configuration.lastFullscreenDisplayID {
            if let target = NSScreen.screens.first(where: { $0.displayID == savedID }) {
                Self.logger.debug("targetScreen for '\(instance.name, privacy: .public)': using saved display \(savedID, privacy: .public)")
                return target
            }
            Self.logger.debug("targetScreen for '\(instance.name, privacy: .public)': saved display \(savedID, privacy: .public) not found, falling back")
        }
        if let libraryScreen = mainWindowController?.window?.screen {
            return libraryScreen
        }
        return NSScreen.screens.first
    }

    // MARK: - Idle Termination

    /// Whether the main library window has been dismissed (closed by the user).
    /// Distinguishes closed from hidden (Cmd+H) and minimized (Cmd+M) via runtime inspection.
    /// Returns `false` if the window controller or its window is nil (no window to inspect).
    private var isMainWindowDismissed: Bool {
        guard let window = mainWindowController?.window else { return false }
        if NSApp.isHidden || window.isMiniaturized { return false }
        return !window.isVisible
    }

    /// Whether the app has no reason to stay alive: main window dismissed,
    /// no auxiliary windows remain, and no VMs are active.
    private var isIdle: Bool {
        guard isMainWindowDismissed else { return false }
        guard displayWindows.isEmpty else { return false }
        guard serialConsoleWindows.isEmpty else { return false }
        guard clipboardWindows.isEmpty else { return false }
        return !viewModel.instances.contains(where: \.isKeepingAppAlive)
    }

    /// Terminates the app if `isIdle` is true.
    private func terminateIfIdle() {
        guard isIdle else { return }
        Self.logger.notice("No visible windows and no active VMs — requesting termination")
        NSApp.terminate(nil)
    }

    /// Registers a one-shot observation on the instances list and each instance's
    /// `isKeepingAppAlive` state. Re-subscribes after each change for continuous observation.
    private func observeForTermination() {
        withObservationTracking {
            for instance in viewModel.instances {
                _ = instance.isKeepingAppAlive
            }
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self else {
                    Self.logger.warning("observeForTermination: observation chain ended (self deallocated)")
                    return
                }
                self.terminateIfIdle()
                self.observeForTermination()
            }
        }
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Preparing instances disable all VM menu bar actions (cancel is only available via sidebar context menu)
        if let instance = activeInstance, instance.isPreparing {
            switch menuItem.action {
            case #selector(showLibrary(_:)), #selector(newVM(_:)):
                return true
            default:
                return false
            }
        }

        switch menuItem.action {
        case #selector(startVM(_:)):
            return activeInstance?.status.canStart ?? false
        case #selector(pauseVM(_:)):
            return activeInstance?.status.canPause ?? false
        case #selector(resumeVM(_:)):
            return activeInstance?.status.canResume ?? false
        case #selector(stopVM(_:)):
            guard let instance = activeInstance else { return false }
            return instance.canStop || instance.isColdPaused
        case #selector(forceStopVM(_:)):
            return activeInstance?.status.canForceStop ?? false
        case #selector(saveVM(_:)):
            return activeInstance?.canSave ?? false
        case #selector(renameVM(_:)):
            return activeInstance?.status.canEditSettings ?? false
        case #selector(cloneVM(_:)):
            guard let instance = activeInstance else { return false }
            return instance.status.canEditSettings && !viewModel.hasPreparing
        case #selector(deleteVM(_:)):
            return activeInstance?.status.canEditSettings ?? false
        // AppKit bypasses NSMenuItemValidation for windowsMenu items, so
        // menuNeedsUpdate(_:) handles visual state. This case covers keyboard
        // shortcut validation, which still routes through validateMenuItem(_:).
        case #selector(showSerialConsole(_:)):
            return activeInstance?.canShowSerialConsole ?? false
        case #selector(showClipboard(_:)):
            return activeInstance?.canShowClipboard ?? false
        case #selector(showRemovableMedia(_:)):
            return activeInstance?.canAttachUSBDevices ?? false
        case #selector(togglePopOut(_:)):
            guard let instance = activeInstance else { return false }
            let canUse = instance.canUseExternalDisplay
            menuItem.title = displayWindows[instance.instanceID] != nil ? "Pop In Display" : "Pop Out Display"
            return canUse
        case #selector(toggleFullscreen(_:)):
            guard let instance = activeInstance else { return false }
            let canUse = instance.canUseExternalDisplay
            let isFullscreen = displayWindows[instance.instanceID] != nil && instance.isInFullscreen
            menuItem.title = isFullscreen ? "Exit Fullscreen Display" : "Fullscreen Display"
            return canUse
        default:
            return true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === NSApp.windowsMenu {
            serialConsoleMenuItem.isEnabled = activeInstance?.canShowSerialConsole ?? false
            clipboardMenuItem.isEnabled = activeInstance?.canShowClipboard ?? false
        }
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Kernova", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Kernova", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Kernova", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Virtual Machine...", action: #selector(newVM(_:)), keyEquivalent: "n")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Virtual Machine menu
        let vmMenuItem = NSMenuItem()
        let vmMenu = NSMenu(title: "Virtual Machine")
        vmMenu.addItem(withTitle: "Start", action: #selector(startVM(_:)), keyEquivalent: "r")
        let pauseItem = vmMenu.addItem(withTitle: "Pause", action: #selector(pauseVM(_:)), keyEquivalent: "p")
        pauseItem.keyEquivalentModifierMask = [.command, .option]
        let resumeItem = vmMenu.addItem(withTitle: "Resume", action: #selector(resumeVM(_:)), keyEquivalent: "r")
        resumeItem.keyEquivalentModifierMask = [.command, .option]
        vmMenu.addItem(withTitle: "Stop", action: #selector(stopVM(_:)), keyEquivalent: "")
        vmMenu.addItem(withTitle: "Force Stop", action: #selector(forceStopVM(_:)), keyEquivalent: "")
        vmMenu.addItem(.separator())
        let saveItem = vmMenu.addItem(withTitle: "Save State", action: #selector(saveVM(_:)), keyEquivalent: "s")
        saveItem.keyEquivalentModifierMask = [.command, .option]
        vmMenu.addItem(.separator())
        let popOutItem = vmMenu.addItem(
            withTitle: "Pop Out Display",
            action: #selector(togglePopOut(_:)),
            keyEquivalent: "o"
        )
        popOutItem.keyEquivalentModifierMask = [.command, .shift]
        let fullscreenItem = vmMenu.addItem(
            withTitle: "Fullscreen Display",
            action: #selector(toggleFullscreen(_:)),
            keyEquivalent: "f"
        )
        fullscreenItem.keyEquivalentModifierMask = [.command, .shift]
        vmMenu.addItem(.separator())
        vmMenu.addItem(withTitle: "Rename...", action: #selector(renameVM(_:)), keyEquivalent: "")
        vmMenu.addItem(withTitle: "Clone", action: #selector(cloneVM(_:)), keyEquivalent: "d")
        let deleteItem = vmMenu.addItem(withTitle: "Move to Trash", action: #selector(deleteVM(_:)), keyEquivalent: "\u{08}")
        deleteItem.keyEquivalentModifierMask = [.command]
        vmMenuItem.submenu = vmMenu
        mainMenu.addItem(vmMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let showLibraryItem = NSMenuItem(
            title: "Show Library",
            action: #selector(showLibrary(_:)),
            keyEquivalent: "0"
        )
        windowMenu.addItem(showLibraryItem)
        windowMenu.addItem(.separator())
        let serialItem = NSMenuItem(
            title: "Serial Console",
            action: #selector(showSerialConsole(_:)),
            keyEquivalent: "t"
        )
        serialItem.keyEquivalentModifierMask = [.command, .shift]
        self.serialConsoleMenuItem = serialItem
        windowMenu.addItem(serialItem)
        let clipboardItem = NSMenuItem(
            title: "Clipboard",
            action: #selector(showClipboard(_:)),
            keyEquivalent: "v"
        )
        clipboardItem.keyEquivalentModifierMask = [.command, .shift]
        self.clipboardMenuItem = clipboardItem
        windowMenu.addItem(clipboardItem)
        let removableMediaItem = NSMenuItem(
            title: "Removable Media",
            action: #selector(showRemovableMedia(_:)),
            keyEquivalent: "u"
        )
        removableMediaItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(removableMediaItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        windowMenu.delegate = self
        mainMenu.addItem(windowMenuItem)

        // Help menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Kernova Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }
}
