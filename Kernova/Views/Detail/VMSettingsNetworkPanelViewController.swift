import AppKit
import KernovaKit

/// The Network category: the Mode picker and the address and MAC rows behind
/// it.
///
/// A single-section category, so the section draws no header of its own and
/// hands its info affordance and lock hint to the panel header.
@MainActor
final class VMSettingsNetworkPanelViewController: NSViewController, VMSettingsPanel {
    let context: VMSettingsPanelContext
    let category = VMSettingsCategory.network
    private(set) var chrome = VMSettingsPanelChrome()
    private var lockRegistry = VMSettingsLockRegistry()

    private let panelStack = NSStackView()

    /// Injected host state, read through the context.
    private var bridgedInterfaces: any BridgedInterfaceProviding { context.bridgedInterfaces }
    private var entitlements: EntitlementService { context.viewModel.entitlements }

    private var networkModePopUp = NSPopUpButton()
    /// The Network Mode row, dimmed on the same terms its header hint is shown.
    private var networkModeRow: NSView?
    /// The Network header's lock hint, hidden — unlike its `lockHints` peers —
    /// while the picker is the live-switch surface.
    private var networkLockHint: NSView?
    /// The MAC address row, hidden while the VM has no network device or has
    /// yet to be given an address.
    private var macAddressRow: GroupedFormCollapsibleRow?
    private var macAddressField = NSTextField()
    private var ipAddressRow: GroupedFormCollapsibleRow?
    private var ipAddressValueLabel: NSTextField?
    private var ipAddressCopyButton: NSButton?
    /// What the copy button copies — the observed address, `nil` while the
    /// row shows anything else.
    private var ipAddressCopyValue: String?
    /// Stands in for the card's rows while the mode is None.
    private var networkNoDeviceCaption = NSTextField()
    /// Holds the banner naming the other VMs sharing this one's MAC address.
    private var networkWarningContainer = NSStackView()

    /// The duplicate-MAC banner's rendered message, `nil` when no banner is
    /// shown, so a pass that changed nothing about it skips the rebuild.
    private var renderedNetworkMACWarning: String?
    /// The Mode menu's rendered selection, so a `refresh()` pass that changed
    /// nothing about networking skips a rebuild.
    private var renderedNetworkChoice: NetworkModeChoice?
    /// The live-switch state the Mode menu was last built for; a change rebuilds
    /// so the None entry's enablement tracks it.
    private var renderedNetworkLiveSwitchable = false
    /// The host's bridgeable interfaces as the last picker open found them,
    /// `nil` until one has. Held so a rebuild triggered by the mode the user
    /// just picked from that list still knows the list — rebuilding blind would
    /// render their own choice as an unavailable entry.
    private var enumeratedInterfaces: [BridgedInterface]?

    // MARK: Network

    /// The Network section and the info popover carrying the panel's whole
    /// claim about what networking does.
    ///
    /// "UI copy states only what is known": every paragraph is built from what
    /// this build and this host can actually deliver — the Shared reach clause
    /// points at the IP address row only where that row can show an address,
    /// and the Wi-Fi limitation is stated at the standard's strength, on the
    /// surface the user picks a mode from.
    private func buildNetworkSection() -> NSView {
        // Outside `lockableRows`: the picker is the live-switch surface while
        // the VM runs, so `refreshNetwork()` owns its enablement and its row's
        // dimming (and the section lock hint it makes moot).
        networkModePopUp = makeNetworkModePopUp()
        let modeRow = makeGroupedFormCardRow("Mode", control: networkModePopUp)
        networkModeRow = modeRow

        var rows: [NSView] = [modeRow]
        rows.append(makeIPAddressRow())
        rows.append(makeMACAddressRow())
        networkNoDeviceCaption = makeGroupedFormCaption("This virtual machine has no network device.")
        networkWarningContainer = NSStackView()
        networkWarningContainer.orientation = .vertical
        networkWarningContainer.alignment = .leading
        networkWarningContainer.spacing = Spacing.small
        networkWarningContainer.translatesAutoresizingMaskIntoConstraints = false

        // The IP address row shows a running Shared guest's address only where
        // the guest rides the app-managed network and the host's table can be
        // read, so only there does the copy point at it.
        let sharedReachClause =
            entitlements.hasVMNetworking && entitlements.supportsGuestAddressObservation
            ? "this Mac reaches it at the address in the IP address row"
            : "this Mac reaches it at its address on that subnet"
        var paragraphs: [InfoPopoverParagraph] = [
            .body(
                "The mode sets how the guest reaches the network. Shared Network gives it outbound access through the host: the guest gets a DHCP address on a private subnet, other machines on your network cannot reach it, and \(sharedReachClause). Host Only puts the guest on a private network reachable only from this Mac: it can talk to the host and to other Host Only guests, with no access to your network or the internet. Bridged puts the guest on your network through the chosen host interface, where it requests its own address like a separate machine."
            ),
            .body(
                "Bridged traffic bypasses a VPN running on the host. Bridging over Wi-Fi is best-effort — the Wi-Fi standard does not bridge additional stations and there is no client-side fix, so prefer a wired interface."
            ),
        ]
        if instance.configuration.guestOS == .linux {
            paragraphs.append(
                .body(
                    "The interface usually appears as `enp0s1`. If networking doesn't come up, make sure your distro's DHCP client or NetworkManager is running."
                ))
        }
        // The Network panel's only section, so its header moves to the panel
        // header: the info affordance and the lock hint go there rather than
        // repeating the category name inside the form.
        let hint = lockRegistry.makeLockHint { self.networkLockHint = $0 }
        chrome = VMSettingsPanelChrome(
            leading: [makeGroupedFormInfoButton(label: "Network", paragraphs: paragraphs)],
            trailing: [hint])
        return makeGroupedFormSection([
            makeGroupedFormCard(rows: rows),
            networkWarningContainer,
            networkNoDeviceCaption,
        ])
    }

    /// The IP address row: the address the host last saw the guest use, with a
    /// copy affordance, or the prose `GuestIPAddress.displayText` states
    /// instead. `refreshIPAddressRow()` owns its content and visibility.
    private func makeIPAddressRow() -> GroupedFormCollapsibleRow {
        let value = makeGroupedFormValueLabel("")
        ipAddressValueLabel = value

        let copy = NSButton()
        copy.image = .systemSymbol("doc.on.doc", accessibilityDescription: "Copy IP Address")
        copy.imagePosition = .imageOnly
        copy.isBordered = false
        copy.contentTintColor = .secondaryLabelColor
        copy.toolTip = "Copy IP Address"
        copy.target = self
        copy.action = #selector(copyIPAddressTapped)
        ipAddressCopyButton = copy

        let control = NSStackView(views: [value, copy])
        control.orientation = .horizontal
        control.spacing = Spacing.tight
        let row = GroupedFormCollapsibleRow(
            row: makeGroupedFormCardRow("IP address", control: control))
        ipAddressRow = row
        return row
    }

    /// Renders the IP address row from the address the pane resolved — absence
    /// over a visible-but-empty control wherever there is nothing to state.
    private func refreshIPAddressRow() {
        let address = resolved.ipAddress
        ipAddressCopyValue = address.address
        ipAddressRow?.isHidden = address.displayText == nil
        ipAddressCopyButton?.isHidden = address.address == nil
        ipAddressValueLabel?.stringValue = address.displayText ?? ""
    }

    @objc private func copyIPAddressTapped() {
        guard let value = ipAddressCopyValue else { return }
        copyToPasteboard(value)
    }

    // MARK: MAC Address

    /// The MAC address row: an editable, VZ-validated field and a Generate
    /// button. `refreshMACAddressRow()` owns its content and visibility.
    private func makeMACAddressRow() -> GroupedFormCollapsibleRow {
        macAddressField = NSTextField()
        macAddressField.alignment = .right
        macAddressField.delegate = self
        macAddressField.toolTip =
            "Six pairs of hexadecimal digits separated by colons, for example 3a:5f:20:11:88:c4."
        macAddressField.widthAnchor.constraint(equalToConstant: 140).isActive = true

        let generate = makeGroupedFormPushButton("Generate", target: self, action: #selector(generateMACAddressTapped))
        generate.controlSize = .small

        let control = NSStackView(views: [macAddressField, generate])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = Spacing.tight
        // Unlike the Mode picker above it, the address is read once at start and
        // fixed for the session, so this row locks with the section.
        let row = GroupedFormCollapsibleRow(
            row: lockRegistry.lockable(
                makeGroupedFormCardRow("MAC address", control: control),
                macAddressField, generate))
        macAddressRow = row
        return row
    }

    private func refreshMACAddressRow() {
        let config = instance.configuration
        let hidden = !config.networkEnabled || config.macAddress == nil
        // End an open editor before the row goes: AppKit doesn't resign a
        // hidden field, so the mode picker — which takes no first responder of
        // its own — would leave it focused and invisible, swallowing keystrokes.
        if hidden, macAddressField.currentEditor() != nil {
            view.window?.makeFirstResponder(nil)
        }
        macAddressRow?.isHidden = hidden
        // A field with an open editor is mid-edit: any refresh — a status change
        // started from the toolbar, say — would otherwise discard the keystrokes
        // typed so far.
        if macAddressField.currentEditor() == nil {
            macAddressField.stringValue = instance.configuration.macAddress ?? ""
        }
    }

    /// While the pane is read-only, whether the Mode picker stays live as the
    /// hot-swap surface.
    ///
    /// Both terms come from the catalog, so the picker and the verb behind it
    /// agree: the mode takes an edit, and not because the VM is at rest — that
    /// case is the one the pane's own lock already covers.
    private var networkModeIsLiveSwitchable: Bool {
        guard isReadOnly else { return false }
        let capabilities = viewModel.capabilities
        return capabilities.isAvailable(.switchNetworkMode, on: instance)
            && !capabilities.isAvailable(.editConfiguration, on: instance)
    }

    private func makeNetworkModePopUp() -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.controlSize = .small
        // Otherwise AppKit re-derives each item's enabled state on every event,
        // undoing the entries disabled below.
        popUp.autoenablesItems = false
        popUp.target = self
        popUp.action = #selector(networkModeChanged)
        popUp.menu?.delegate = self
        return popUp
    }

    /// Rebuilds the Mode menu and selects the entry matching the configuration.
    ///
    /// The bridgeable list comes from ``enumeratedInterfaces``, which only
    /// ``menuNeedsUpdate(_:)`` fills in — an enumeration is host state that goes
    /// stale, so it runs when the picker opens and nowhere else. Before the
    /// first open the menu still carries every fixed entry plus one standing for
    /// the current choice, which is what the row and the card read the mode's
    /// title from.
    private func rebuildNetworkModeMenu() {
        let interfaces = enumeratedInterfaces
        guard let menu = networkModePopUp.menu else { return }
        menu.removeAllItems()
        let liveSwitchable = networkModeIsLiveSwitchable
        let current = NetworkModeChoice(instance.configuration)
        addNetworkModeItem("Shared Network", choice: .shared, to: menu)
        if entitlements.hasVMNetworking {
            addNetworkModeItem("Host Only", choice: .hostOnly, to: menu)
        } else if current == .hostOnly {
            // A host-only VM in a build the entitlement doesn't cover: the
            // picker offers no Host Only entry, so this one shows the mode
            // without offering it — carrying the current choice so it still
            // selects.
            addNetworkModeItem("Host Only (unavailable)", choice: .hostOnly, to: menu, enabled: false)
        }
        // While the session runs, every attachable mode can hot-swap; None
        // cannot — network devices cannot be added or removed at runtime.
        addNetworkModeItem("None", choice: .none, to: menu, enabled: !liveSwitchable)

        renderedNetworkChoice = current
        renderedNetworkLiveSwitchable = liveSwitchable
        if entitlements.hasVMNetworking {
            menu.addItem(.sectionHeader(title: "Bridged"))
            addNetworkModeItem("Automatic", choice: .bridged(nil), to: menu)
            if let interfaces {
                if interfaces.isEmpty {
                    addNetworkModePlaceholder("No Bridgeable Interfaces", to: menu)
                }
                for interface in interfaces {
                    addNetworkModeItem(
                        NetworkModeChoice.interfaceTitle(interface),
                        choice: .bridged(interface.identifier), to: menu)
                }
            }
            // Keep the interface the VM is bridged over on the list when the
            // entries above don't already carry it — the whole of the Bridged
            // list until the picker is first opened, and after that only an
            // interface the host has stopped offering. An identifier merely
            // remembered from an earlier bridged choice adds no entry.
            if case .bridged(.some(let persisted)) = current,
                !(interfaces ?? []).contains(where: { $0.identifier == persisted })
            {
                addNetworkModeItem(
                    resolved.networkModeTitle ?? persisted, choice: .bridged(persisted),
                    to: menu, enabled: false)
            }
        } else if case .bridged = current {
            // A bridged VM in a build the entitlement doesn't cover: the picker
            // offers no Bridged entry, so this one shows the mode without
            // offering it — carrying the current choice so it still selects.
            addNetworkModeItem("Bridged (unavailable)", choice: current, to: menu, enabled: false)
        }

        selectNetworkModeItem()
    }

    /// Appends one Mode entry.
    ///
    /// `choice` is non-optional: in an optional context Swift reads the
    /// `.none` case as `nil`, which would strip the None entry's identity.
    private func addNetworkModeItem(
        _ title: String, choice: NetworkModeChoice, to menu: NSMenu, enabled: Bool = true
    ) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = choice
        item.isEnabled = enabled
        menu.addItem(item)
    }

    /// Appends an entry that stands for no mode at all — readable, never chosen.
    private func addNetworkModePlaceholder(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func selectNetworkModeItem() {
        let choice = NetworkModeChoice(instance.configuration)
        guard
            let item = networkModePopUp.menu?.items.first(where: {
                $0.representedObject as? NetworkModeChoice == choice
            })
        else { return }
        networkModePopUp.select(item)
    }

    private func refreshNetwork() {
        let liveSwitchable = networkModeIsLiveSwitchable
        let modeEditable = !isReadOnly || liveSwitchable
        networkModePopUp.isEnabled = modeEditable
        networkModeRow?.alphaValue = modeEditable ? 1 : Alpha.disabled
        // `apply()` just showed every lock hint for the read-only pane; a live
        // picker makes this section's hint a false claim, so re-hide it.
        networkLockHint?.isHidden = modeEditable
        if NetworkModeChoice(instance.configuration) != renderedNetworkChoice
            || liveSwitchable != renderedNetworkLiveSwitchable
        {
            rebuildNetworkModeMenu()
        }
        // None leaves no device to describe, so the card's remaining rows give way
        // to a caption saying so.
        let hasDevice = instance.configuration.networkEnabled
        refreshMACAddressRow()
        refreshMACAddressWarning()
        networkNoDeviceCaption.isHidden = hasDevice
        refreshIPAddressRow()
    }

    /// Discloses that another VM in the library carries this one's MAC address.
    ///
    /// Import, load and reconcile admit a bundle whatever address it arrives
    /// with, so the pair is visible here rather than refused at the door — the
    /// address stays editable, and Generate above the banner moves this VM off
    /// it.
    private func refreshMACAddressWarning() {
        let message = resolved.warnings[.network]
        guard message != renderedNetworkMACWarning else { return }
        renderedNetworkMACWarning = message
        networkWarningContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let message else { return }
        let banner = makeGroupedFormBanner(
            symbolName: "exclamationmark.triangle.fill", tint: .systemYellow, message: message)
        addGroupedFormFullWidth(banner, to: networkWarningContainer)
    }

    @objc private func generateMACAddressTapped() {
        // Clicking a push button takes no first responder, so an edit open in
        // the field would outlive the write and commit over it on the way out.
        // Discard it rather than settling it: the generated address supersedes
        // whatever was typed, so committing first would only refuse a typed
        // duplicate with an alert about an address no longer in play.
        macAddressField.abortEditing()
        write(VMConfigurationKeyRegistry.networkMAC.assigning(GuestMACAddress.random()))
        refreshResolved()
        refreshNetwork()
    }

    @objc private func networkModeChanged() {
        guard let choice = networkModePopUp.selectedItem?.representedObject as? NetworkModeChoice
        else { return }
        let mode = VMConfigurationKeyRegistry.networkMode
        let accepted =
            switch choice {
            case .shared:
                write(mode.assigning(VMNetworkMode.shared.rawValue))
            case .hostOnly:
                write(mode.assigning(VMNetworkMode.hostOnly.rawValue))
            case .none:
                write(mode.assigning(VMConfigurationKeyRegistry.noNetworkValue))
            case .bridged(let identifier):
                // The interface before the mode, so a picker choice that only
                // changes the interface still lands.
                write(
                    VMConfigurationKeyRegistry.networkBridgedInterface.assigning(identifier ?? ""),
                    mode.assigning(VMNetworkMode.bridged.rawValue))
            }
        // A refused switch leaves the configuration untouched, so nothing marks
        // the menu stale and the picker would go on showing a mode the VM is not
        // on. Rebuilding re-selects the configured one.
        if !accepted { rebuildNetworkModeMenu() }
        // The write flips the card's row visibility; refresh in case the value was
        // already what the model held.
        refreshResolved()
        refreshNetwork()
    }

    /// Persists the typed MAC in canonical form, then shows the address the VM
    /// ended up with — so text naming no address a guest can use, and an
    /// address refused because another VM holds it or the VM's state pins it,
    /// both snap the field back. The tooltip names the accepted spelling; the
    /// refusal carries its own alert.
    ///
    /// The field is written directly rather than through
    /// `refreshMACAddressRow()`: editing is still ending here, so the editor the
    /// refresh defers to is the very one being reconciled away.
    private func applyMACAddressFieldEdit() {
        if let normalized = GuestMACAddress.normalized(macAddressField.stringValue) {
            write(VMConfigurationKeyRegistry.networkMAC.assigning(normalized))
        }
        macAddressField.stringValue = instance.configuration.macAddress ?? ""
    }

    // MARK: - Panel

    func rebuild() {
        loadViewIfNeeded()
        panelStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        lockRegistry.removeAll()
        renderedNetworkMACWarning = nil
        renderedNetworkChoice = nil
        let section = buildNetworkSection()
        panelStack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: panelStack.widthAnchor).isActive = true
    }

    func refresh() {
        lockRegistry.apply(isReadOnly: isReadOnly)
        refreshNetwork()
    }

    override func loadView() {
        panelStack.orientation = .vertical
        panelStack.alignment = .leading
        panelStack.spacing = Spacing.section
        panelStack.translatesAutoresizingMaskIntoConstraints = false
        view = panelStack
    }

    init(context: VMSettingsPanelContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMSettingsNetworkPanelViewController does not support NSCoder")
    }
}

// MARK: - NSMenuDelegate

extension VMSettingsNetworkPanelViewController: NSMenuDelegate {
    /// Re-reads the host's bridgeable interfaces each time the Mode picker
    /// opens — the one place that enumeration runs.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === networkModePopUp.menu else { return }
        enumeratedInterfaces = bridgedInterfaces.interfaces()
        rebuildNetworkModeMenu()
    }
}

// MARK: - NSTextFieldDelegate

extension VMSettingsNetworkPanelViewController: NSTextFieldDelegate {
    /// The MAC field's end-editing commit; the panel is the field's delegate.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === macAddressField else { return }
        applyMACAddressFieldEdit()
    }
}
