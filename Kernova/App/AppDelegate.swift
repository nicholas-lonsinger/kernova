import Cocoa
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindowController: MainWindowController?
    private var viewModel: VMLibraryViewModel!

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
                    try await viewModel.virtualizationService.save(instance)
                    try viewModel.storageService.saveConfiguration(
                        instance.configuration,
                        to: instance.bundleURL
                    )
                } catch {
                    // Best-effort save; force-stop if save fails
                    try? await viewModel.virtualizationService.forceStop(instance)
                }
            }
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    // MARK: - Menu Actions

    @objc func newVM(_ sender: Any?) {
        viewModel.showCreationWizard = true
    }

    // MARK: - VM Actions

    @objc func startVM(_ sender: Any?) {
        guard let instance = viewModel.selectedInstance else { return }
        Task { await viewModel.start(instance) }
    }

    @objc func pauseVM(_ sender: Any?) {
        guard let instance = viewModel.selectedInstance else { return }
        Task { await viewModel.pause(instance) }
    }

    @objc func resumeVM(_ sender: Any?) {
        guard let instance = viewModel.selectedInstance else { return }
        Task { await viewModel.resume(instance) }
    }

    @objc func stopVM(_ sender: Any?) {
        guard let instance = viewModel.selectedInstance else { return }
        viewModel.stop(instance)
    }

    @objc func saveVM(_ sender: Any?) {
        guard let instance = viewModel.selectedInstance else { return }
        Task { await viewModel.save(instance) }
    }

    @objc func deleteVM(_ sender: Any?) {
        guard let instance = viewModel.selectedInstance else { return }
        viewModel.confirmDelete(instance)
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

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
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
