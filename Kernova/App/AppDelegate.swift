import Cocoa
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private var mainWindowController: MainWindowController?
    private var viewModel: VMLibraryViewModel!
    private var pendingOpenURLs: [URL] = []
    private var serialConsoleWindows: [UUID: SerialConsoleWindowController] = [:]
    private var serialConsoleObservers: [UUID: Any] = [:]
    private var fullscreenWindows: [UUID: FullscreenWindowController] = [:]
    private var fullscreenObservers: [UUID: Any] = [:]

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
        setupMainMenu()

        let windowController = MainWindowController(viewModel: viewModel)
        windowController.showWindow(nil)
        mainWindowController = windowController

        // Process any URLs received before the view model was ready
        for url in pendingOpenURLs {
            viewModel.importVM(from: url)
        }
        pendingOpenURLs.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
                    // Best-effort save; force-stop if save fails
                    try? await viewModel.tryForceStop(instance)
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

    // MARK: - VM Actions

    @objc func startVM(_ sender: Any?) {
        guard let instance = viewModel.selectedInstance else { return }
        Task {
            await viewModel.start(instance)
            if instance.status == .running && instance.configuration.prefersFullscreen {
                enterFullscreen(for: instance)
            }
        }
    }

    @objc func pauseVM(_ sender: Any?) {
        guard let instance = viewModel.selectedInstance else { return }
        Task { await viewModel.pause(instance) }
    }

    @objc func resumeVM(_ sender: Any?) {
        guard let instance = viewModel.selectedInstance else { return }
        Task {
            await viewModel.resume(instance)
            if instance.status == .running && instance.configuration.prefersFullscreen {
                enterFullscreen(for: instance)
            }
        }
    }

    @objc func stopVM(_ sender: Any?) {
        guard let instance = viewModel.selectedInstance else { return }
        viewModel.stop(instance)
    }

    @objc func saveVM(_ sender: Any?) {
        guard let instance = viewModel.selectedInstance else { return }
        Task { await viewModel.save(instance) }
    }

    @objc func renameVM(_ sender: Any?) {
        guard let instance = viewModel.selectedInstance else { return }
        viewModel.renameVM(instance)
    }

    @objc func cloneVM(_ sender: Any?) {
        guard let instance = viewModel.selectedInstance else { return }
        Task { await viewModel.cloneVM(instance) }
    }

    @objc func deleteVM(_ sender: Any?) {
        guard let instance = viewModel.selectedInstance else { return }
        viewModel.confirmDelete(instance)
    }

    // MARK: - Serial Console

    @objc func showSerialConsole(_ sender: Any?) {
        guard let instance = viewModel.selectedInstance else { return }

        if let existing = serialConsoleWindows[instance.instanceID] {
            existing.showWindow(nil)
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
            }
        }
        serialConsoleObservers[vmID] = token

        controller.showWindow(nil)
    }

    // MARK: - Fullscreen Display

    @objc func toggleFullscreenDisplay(_ sender: Any?) {
        guard let instance = viewModel.selectedInstance else { return }

        if let existing = fullscreenWindows[instance.instanceID] {
            existing.window?.close()
            return
        }

        instance.configuration.prefersFullscreen = true
        viewModel.saveConfiguration(for: instance)
        enterFullscreen(for: instance)
    }

    private func enterFullscreen(for instance: VMInstance) {
        let vmID = instance.instanceID

        // Already showing fullscreen for this VM
        guard fullscreenWindows[vmID] == nil else { return }

        let controller = FullscreenWindowController(instance: instance)
        fullscreenWindows[vmID] = controller

        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let token = self.fullscreenObservers.removeValue(forKey: vmID) {
                    NotificationCenter.default.removeObserver(token)
                }
                if let controller = self.fullscreenWindows.removeValue(forKey: vmID),
                   !controller.closedByVMStop {
                    instance.configuration.prefersFullscreen = false
                    self.viewModel.saveConfiguration(for: instance)
                }
            }
        }
        fullscreenObservers[vmID] = token

        controller.showWindow(nil)
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(startVM(_:)):
            return viewModel.selectedInstance?.status.canStart ?? false
        case #selector(pauseVM(_:)):
            return viewModel.selectedInstance?.status.canPause ?? false
        case #selector(resumeVM(_:)):
            return viewModel.selectedInstance?.status.canResume ?? false
        case #selector(stopVM(_:)):
            return viewModel.selectedInstance?.status.canStop ?? false
        case #selector(saveVM(_:)):
            return viewModel.selectedInstance?.status.canSave ?? false
        case #selector(renameVM(_:)):
            return viewModel.selectedInstance?.status.canEditSettings ?? false
        case #selector(cloneVM(_:)):
            guard let instance = viewModel.selectedInstance else { return false }
            return instance.status.canEditSettings && !viewModel.isCloning
        case #selector(deleteVM(_:)):
            return viewModel.selectedInstance?.status.canEditSettings ?? false
        case #selector(showSerialConsole(_:)):
            return viewModel.selectedInstance != nil
        case #selector(toggleFullscreenDisplay(_:)):
            guard let instance = viewModel.selectedInstance else { return false }
            // Only allow fullscreen when the VM has a live VZVirtualMachine
            let canFullscreen = (instance.status == .running || instance.status == .paused)
                && instance.virtualMachine != nil
            if canFullscreen, fullscreenWindows[instance.instanceID] != nil {
                menuItem.title = "Exit Fullscreen Display"
            } else {
                menuItem.title = "Fullscreen Display"
            }
            return canFullscreen
        default:
            return true
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
        vmMenu.addItem(.separator())
        let saveItem = vmMenu.addItem(withTitle: "Save State", action: #selector(saveVM(_:)), keyEquivalent: "s")
        saveItem.keyEquivalentModifierMask = [.command, .option]
        vmMenu.addItem(.separator())
        let fullscreenItem = vmMenu.addItem(
            withTitle: "Fullscreen Display",
            action: #selector(toggleFullscreenDisplay(_:)),
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
        let serialItem = NSMenuItem(
            title: "Serial Console",
            action: #selector(showSerialConsole(_:)),
            keyEquivalent: "t"
        )
        serialItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(serialItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
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
