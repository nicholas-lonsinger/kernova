import AppKit
import os

/// Owns the resident agent's menu-bar `NSStatusItem` and its dropdown.
///
/// Present for the whole life of the background-agent process — the always-visible
/// "Kernova is running" affordance, and the discoverable way to summon the GUI
/// when the app is headless (`.accessory`, no Dock icon). The dropdown leads with
/// "Open Kernova", lists the VMs running headless (click one to open the library
/// on it), and ends with Quit; it is rebuilt from live view-model state each time
/// it opens. A live tooltip reflects the running count. Mirrors the guest agent's
/// `GuestAgentStatusItemController`.
@MainActor
final class HostAgentStatusItemController: NSObject, NSMenuDelegate {
    private static let logger = Logger(subsystem: "app.kernova", category: "HostAgentStatusItem")
    private static let iconSymbol = "macwindow"

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let viewModel: VMLibraryViewModel
    /// Summons the GUI; a non-`nil` id selects that VM first.
    private let onOpen: (UUID?) -> Void
    private let onQuit: () -> Void

    /// Keeps the tooltip in sync with how many VMs are running headless.
    private var runningObservation: ObservationLoop?

    init(
        viewModel: VMLibraryViewModel,
        onOpen: @escaping (UUID?) -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.viewModel = viewModel
        self.onOpen = onOpen
        self.onQuit = onQuit
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        setIcon()
        updateTooltip()

        // Refresh the tooltip as VMs start/stop, so the at-a-glance running count
        // stays current even while the menu is closed.
        runningObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                for instance in self.viewModel.instances { _ = instance.isKeepingAppAlive }
            },
            apply: { [weak self] in self?.updateTooltip() }
        )
    }

    // MARK: - Icon / tooltip

    private func setIcon() {
        // RATIONALE: deliberately not the shared `NSImage.systemSymbol(_:…)` helper.
        // Its release fallback is a zero-size `NSImage()`, which would render the
        // status-item button invisible — and the status item is the *only* way to
        // find (or quit) the headless agent. This hand-rolled guard degrades to a
        // visible "K" title instead, so the affordance never disappears.
        guard
            let image = NSImage(
                systemSymbolName: Self.iconSymbol, accessibilityDescription: "Kernova")
        else {
            // The SF Symbol name is a compile-time constant; a miss is a typo or a
            // deployment-target mismatch. Crash in debug, degrade to a glyph in release.
            Self.logger.fault(
                "Missing SF Symbol '\(Self.iconSymbol, privacy: .public)' for status item")
            assertionFailure("Missing SF Symbol '\(Self.iconSymbol)'")
            statusItem.button?.title = "K"
            return
        }
        image.isTemplate = true
        statusItem.button?.image = image
    }

    private func updateTooltip() {
        let count = viewModel.instances.lazy.filter(\.isKeepingAppAlive).count
        switch count {
        case 0: statusItem.button?.toolTip = "Kernova"
        case 1: statusItem.button?.toolTip = "Kernova — 1 virtual machine running"
        default: statusItem.button?.toolTip = "Kernova — \(count) virtual machines running"
        }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = NSMenuItem(title: "Open Kernova", action: #selector(openTapped), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let running = viewModel.instances.filter(\.isKeepingAppAlive)
        if running.isEmpty {
            let none = NSMenuItem(
                title: "No virtual machines running", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for instance in running {
                let item = NSMenuItem(
                    title: "\(instance.name) — \(instance.status.displayName)",
                    action: #selector(openVMTapped(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = instance.instanceID
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Kernova", action: #selector(quitTapped), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func openTapped() { onOpen(nil) }

    @objc private func openVMTapped(_ sender: NSMenuItem) {
        onOpen(sender.representedObject as? UUID)
    }

    @objc private func quitTapped() { onQuit() }
}
