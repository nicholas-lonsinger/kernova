import Cocoa
import os
import SwiftUI
import Virtualization

/// Manages a dedicated window displaying a single VM's screen, either as a
/// resizable pop-out window or in native macOS fullscreen.
///
/// On show the inline `VMDisplayView` in the main window is replaced by a placeholder
/// (via `VMInstance.displayMode`), and this controller creates its own
/// `VZVirtualMachineView` bound to the same `VZVirtualMachine`. On close the process
/// reverses so the inline display re-appears.
@MainActor
final class VMDisplayWindowController: NSWindowController, NSWindowDelegate {

    let vmID: UUID
    private(set) var closedProgrammatically = false
    private(set) var lastDisplayID: CGDirectDisplayID?
    let instance: VMInstance
    private let enterFullscreen: Bool
    private var observingInstance = false

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMDisplayWindowController")

    // MARK: - Toolbar Item Identifiers

    private static let toolbarLifecycle = NSToolbarItem.Identifier("displayLifecycle")
    private static let toolbarSaveState = NSToolbarItem.Identifier("displaySaveState")
    private static let saveStateToolTip = "Save the virtual machine state to disk"
    private static let toolbarDisplay = NSToolbarItem.Identifier("displayDisplay")

    private enum LifecycleSegment: Int {
        case play = 0, pause = 1, stop = 2

        static let startToolTip = "Start the virtual machine"
        static let resumeToolTip = "Resume the virtual machine"
        static let pauseToolTip = "Pause the virtual machine"
        static let stopToolTip = "Stop the virtual machine"
    }

    private enum DisplaySegment: Int {
        case popIn = 0, fullscreen = 1

        static let popOutToolTip = "Open display in a separate window"
        static let popInToolTip = "Return display to the main window"
        static let fullscreenToolTip = "Enter fullscreen display"
        static let exitFullscreenToolTip = "Exit fullscreen display"
    }

    init(instance: VMInstance, enterFullscreen: Bool, onResume: @escaping () -> Void) {
        self.vmID = instance.instanceID
        self.instance = instance
        self.enterFullscreen = enterFullscreen

        let contentView = DetachedVMView(instance: instance, onResume: onResume)
        let hostingController = NSHostingController(rootView: contentView)
        hostingController.sizingOptions = []

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "\(instance.name) — Display"
        window.collectionBehavior = [.fullScreenPrimary]
        window.restoreFrame(named: "VMDisplay-\(instance.instanceID)")

        super.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "VMDisplayToolbar-\(instance.instanceID)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func showWindow(_ sender: Any?) {
        instance.displayMode = enterFullscreen ? .fullscreen : .popOut
        super.showWindow(sender)
        if enterFullscreen {
            window?.toggleFullScreen(nil)
        }
        updateToolbarItems()
        observeInstance()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // Capture display ID if not already set by the programmatic-close path
        if lastDisplayID == nil {
            lastDisplayID = window?.screen?.displayID
        }
        observingInstance = false
        window?.toolbar?.isVisible = true
        instance.displayMode = .inline
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        instance.displayMode = .fullscreen
        window?.toolbar?.isVisible = false
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard instance.displayMode == .fullscreen else { return }
        instance.displayMode = .popOut
        window?.toolbar?.isVisible = true
    }

    // MARK: - Instance Observation

    /// Observes VM state changes to auto-close the window when the VM stops/errors/saves
    /// and to keep toolbar items in sync with current status.
    private func observeInstance() {
        observingInstance = true
        withObservationTracking {
            _ = self.instance.status
            _ = self.instance.virtualMachine
            _ = self.instance.displayMode
        } onChange: {
            Task { @MainActor [weak self] in
                guard let self, self.observingInstance else { return }
                let status = self.instance.status
                if status == .stopped || status == .error || self.instance.isColdPaused {
                    self.lastDisplayID = self.window?.screen?.displayID
                    self.closedProgrammatically = true
                    self.window?.close()
                } else {
                    self.updateToolbarItems()
                    self.observeInstance()
                }
            }
        }
    }

    // MARK: - Toolbar State

    private func updateToolbarItems() {
        guard let toolbar = window?.toolbar else { return }

        updateLifecycleGroup(in: toolbar)
        updateSaveStateItem(in: toolbar)
        updateDisplayGroup(in: toolbar)
    }

    private func updateLifecycleGroup(in toolbar: NSToolbar) {
        guard let group = toolbar.items.first(where: { $0.itemIdentifier == Self.toolbarLifecycle }) as? NSToolbarItemGroup,
              group.subitems.count == 3 else { return }

        let canResume = instance.status.canResume
        let playLabel = canResume ? "Resume" : "Start"

        let play = group.subitems[LifecycleSegment.play.rawValue]
        if play.label != playLabel {
            play.label = playLabel
            play.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: playLabel)
            play.toolTip = canResume ? LifecycleSegment.resumeToolTip : LifecycleSegment.startToolTip
        }

        play.isEnabled = instance.status.canStart || canResume
        group.subitems[LifecycleSegment.pause.rawValue].isEnabled = instance.status.canPause
        group.subitems[LifecycleSegment.stop.rawValue].isEnabled = instance.canStop || instance.isColdPaused
    }

    private func updateSaveStateItem(in toolbar: NSToolbar) {
        guard let group = toolbar.items.first(where: { $0.itemIdentifier == Self.toolbarSaveState }) as? NSToolbarItemGroup,
              let subitem = group.subitems.first else { return }
        subitem.isEnabled = instance.canSave
    }

    private func updateDisplayGroup(in toolbar: NSToolbar) {
        guard let group = toolbar.items.first(where: { $0.itemIdentifier == Self.toolbarDisplay }) as? NSToolbarItemGroup,
              group.subitems.count == 2 else { return }

        let popInItem = group.subitems[DisplaySegment.popIn.rawValue]
        let fullscreenItem = group.subitems[DisplaySegment.fullscreen.rawValue]

        popInItem.isEnabled = true
        fullscreenItem.isEnabled = true

        let popLabel = instance.isInSeparateWindow ? "Pop In" : "Pop Out"
        if popInItem.label != popLabel {
            popInItem.label = popLabel
            popInItem.image = NSImage(
                systemSymbolName: instance.isInSeparateWindow ? "pip.enter" : "pip.exit",
                accessibilityDescription: popLabel
            )
            popInItem.toolTip = instance.isInSeparateWindow
                ? DisplaySegment.popInToolTip
                : DisplaySegment.popOutToolTip
        }

        let fsLabel = instance.isInFullscreen ? "Exit Fullscreen" : "Fullscreen"
        if fullscreenItem.label != fsLabel {
            fullscreenItem.label = fsLabel
            fullscreenItem.image = NSImage(
                systemSymbolName: instance.isInFullscreen
                    ? "arrow.down.right.and.arrow.up.left"
                    : "arrow.up.left.and.arrow.down.right",
                accessibilityDescription: fsLabel
            )
            fullscreenItem.toolTip = instance.isInFullscreen
                ? DisplaySegment.exitFullscreenToolTip
                : DisplaySegment.fullscreenToolTip
        }
    }

    // MARK: - Toolbar Actions

    @objc private func lifecycleAction(_ group: NSToolbarItemGroup) {
        guard let segment = LifecycleSegment(rawValue: group.selectedIndex) else {
            Self.logger.warning("lifecycleAction: unexpected selectedIndex \(group.selectedIndex)")
            return
        }
        switch segment {
        case .play:
            if instance.status.canResume {
                NSApp.sendAction(#selector(AppDelegate.resumeVM(_:)), to: nil, from: nil)
            } else {
                NSApp.sendAction(#selector(AppDelegate.startVM(_:)), to: nil, from: nil)
            }
        case .pause:
            NSApp.sendAction(#selector(AppDelegate.pauseVM(_:)), to: nil, from: nil)
        case .stop:
            NSApp.sendAction(#selector(AppDelegate.stopVM(_:)), to: nil, from: nil)
        }
    }

    @objc private func displayAction(_ group: NSToolbarItemGroup) {
        guard let segment = DisplaySegment(rawValue: group.selectedIndex) else {
            Self.logger.warning("displayAction: unexpected selectedIndex \(group.selectedIndex)")
            return
        }
        switch segment {
        case .popIn:
            NSApp.sendAction(#selector(AppDelegate.togglePopOut(_:)), to: nil, from: nil)
        case .fullscreen:
            NSApp.sendAction(#selector(AppDelegate.toggleFullscreen(_:)), to: nil, from: nil)
        }
    }
}

// MARK: - NSToolbarDelegate

extension VMDisplayWindowController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            Self.toolbarLifecycle,
            Self.toolbarSaveState,
            Self.toolbarDisplay,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            Self.toolbarLifecycle,
            Self.toolbarSaveState,
            Self.toolbarDisplay,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.toolbarLifecycle:
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: [
                    NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Start")!,
                    NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")!,
                    NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")!,
                ],
                selectionMode: .momentary,
                labels: ["Start", "Pause", "Stop"],
                target: self,
                action: #selector(lifecycleAction(_:))
            )
            group.label = "State Controls"
            group.subitems[LifecycleSegment.play.rawValue].toolTip = LifecycleSegment.startToolTip
            group.subitems[LifecycleSegment.pause.rawValue].toolTip = LifecycleSegment.pauseToolTip
            group.subitems[LifecycleSegment.stop.rawValue].toolTip = LifecycleSegment.stopToolTip
            group.autovalidates = false
            return group

        case Self.toolbarSaveState:
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: [NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: "Save State")!],
                selectionMode: .momentary,
                labels: ["Save State"],
                target: nil,
                action: #selector(AppDelegate.saveVM(_:))
            )
            group.label = "Save State"
            group.subitems.first?.toolTip = Self.saveStateToolTip
            group.autovalidates = false
            return group

        case Self.toolbarDisplay:
            let group = NSToolbarItemGroup(
                itemIdentifier: itemIdentifier,
                images: [
                    NSImage(systemSymbolName: "pip.enter", accessibilityDescription: "Pop In")!,
                    NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Fullscreen")!,
                ],
                selectionMode: .momentary,
                labels: ["Pop In", "Fullscreen"],
                target: self,
                action: #selector(displayAction(_:))
            )
            group.label = "Display"
            group.subitems[DisplaySegment.popIn.rawValue].toolTip = DisplaySegment.popInToolTip
            group.subitems[DisplaySegment.fullscreen.rawValue].toolTip = DisplaySegment.fullscreenToolTip
            group.autovalidates = false
            return group

        default:
            return nil
        }
    }
}

// MARK: - NSScreen Display ID

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

// MARK: - Detached VM SwiftUI View

/// SwiftUI view used inside the display window. Shows the VM display when a
/// `VZVirtualMachine` is available (with a pause overlay when live-paused), or a placeholder otherwise.
private struct DetachedVMView: View {
    let instance: VMInstance
    var onResume: () -> Void

    var body: some View {
        if let vm = instance.virtualMachine {
            VMDisplayView(virtualMachine: vm)
                .ignoresSafeArea()
                .vmPauseOverlay(isPaused: instance.status == .paused, onResume: onResume)
                .vmTransitionOverlay(status: instance.status)
        } else if instance.status.isTransitioning || instance.isColdPaused {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text(instance.isColdPaused ? "Restoring" : instance.status.displayName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
        } else {
            ContentUnavailableView(
                "No Display",
                systemImage: "display",
                description: Text("The virtual machine display is not available.")
            )
        }
    }
}
