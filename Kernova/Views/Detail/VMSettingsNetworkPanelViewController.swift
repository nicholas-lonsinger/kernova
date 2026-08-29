import AppKit
import Virtualization

/// The Network category: the Mode picker and the address, MAC and
/// port-forwarding rows behind it.
///
/// A single-section category, so the section draws no header of its own and
/// hands its info affordance and lock hint to the panel header.
@MainActor
final class VMSettingsNetworkPanelViewController: NSViewController, VMSettingsPanel {
    let context: VMSettingsPanelContext
    let category = VMSettingsCategory.network
    private(set) var chrome = VMSettingsPanelChrome()
    private var lockRegistry = VMSettingsLockRegistry()

    private let portForwardingSheetPresenter = SheetPresenter()
    private let panelStack = NSStackView()

    /// Injected host state, read through the context.
    private var bridgedInterfaces: any BridgedInterfaceProviding { context.bridgedInterfaces }
    private var entitlements: EntitlementService { context.entitlements }

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
    /// What the copy button copies — the reserved address, `nil` while the
    /// row shows anything else.
    private var ipAddressCopyValue: String?
    /// The Port forwarding block — the rule rows and the Add Rule row — hidden
    /// wherever forwarding cannot apply.
    private var portForwardingRow: GroupedFormCollapsibleRow?
    /// Holds the rule rows and the trailing Add Rule row, rebuilt on change.
    private var portForwardingListStack = NSStackView()
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
    /// The rules (and lock state) the Port forwarding rows were last built for,
    /// so a rebuild happens exactly when one of them changed.
    private var renderedPortForwardingRows: RenderedPortForwardingRows?
    /// The live-switch state the Mode menu was last built for; a change rebuilds
    /// so the None entry's enablement tracks it.
    private var renderedNetworkLiveSwitchable = false
    /// The host's bridgeable interfaces as the last picker open found them,
    /// `nil` until one has. Held so a rebuild triggered by the mode the user
    /// just picked from that list still knows the list — rebuilding blind would
    /// render their own choice as an unavailable entry.
    private var enumeratedInterfaces: [BridgedInterface]?

    /// Value snapshot of the Port forwarding rows' rendered appearance.
    private struct RenderedPortForwardingRows: Equatable {
        let rules: [PortForwardingRule]
        let controlsEnabled: Bool
    }
    // MARK: Network

    private func buildNetworkSection() -> NSView {
        // Deliberately outside `lockableRows`: the picker is the live-switch
        // surface while the VM runs, so `refreshNetwork()` owns its enablement
        // and its row's dimming (and the section lock hint it makes moot).
        networkModePopUp = makeNetworkModePopUp()
        let modeRow = makeGroupedFormCardRow("Mode", control: networkModePopUp)
        networkModeRow = modeRow

        var rows: [NSView] = [modeRow]
        rows.append(makeIPAddressRow())
        rows.append(makeMACAddressRow())
        rows.append(makePortForwardingRow())
        networkNoDeviceCaption = makeGroupedFormCaption("This virtual machine has no network device.")
        networkWarningContainer = NSStackView()
        networkWarningContainer.orientation = .vertical
        networkWarningContainer.alignment = .leading
        networkWarningContainer.spacing = Spacing.small
        networkWarningContainer.translatesAutoresizingMaskIntoConstraints = false

        // With the entitlement, Shared and Host Only assign each guest a
        // deterministic address the IP address row shows, and Shared can forward
        // host ports to it; without it there is neither, so the copy concedes
        // the gap instead.
        let sharedReachClause =
            entitlements.hasVMNetworking
            ? "other machines on your network reach it only on the ports you forward, and this Mac reaches it at the address in the IP address row"
            : "there is no port forwarding from host to guest — incoming connections require knowing the guest's IP"
        var paragraphs: [InfoPopoverParagraph] = [
            .body(
                "The mode sets how the guest reaches the network. Shared Network gives it outbound access through the host: the guest gets a DHCP address on a private subnet, other machines on your network cannot reach it, and \(sharedReachClause). Host Only puts the guest on a private network reachable only from this Mac: it can talk to the host and to other Host Only guests, with no access to your network or the internet. Bridged puts the guest on your network through the chosen host interface, where it requests its own address like a separate machine."
            ),
            .body(
                "Bridged traffic bypasses a VPN running on the host. Bridging over Wi-Fi is best-effort — the Wi-Fi standard does not bridge additional stations and there is no client-side fix, so prefer a wired interface."
            ),
        ]
        if entitlements.hasVMNetworking {
            paragraphs.append(
                .body(
                    "A forwarded port is reachable from other devices on your network. Rule changes take effect the next time a Shared Network virtual machine starts."
                ))
            if #unavailable(macOS 27) {
                paragraphs.append(
                    .body(
                        "On this version of macOS a forwarded port is not reachable from this Mac itself through localhost. Apple documents this as a known limitation of vmnet."
                    ))
            }
        }
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

    /// The IP address row: the reserved address with a copy affordance for
    /// the modes the app assigns addressing in, "Assigned by your network"
    /// for Bridged (external DHCP — nothing deterministic to show).
    /// `refreshIPAddressRow()` owns its content and visibility.
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
    /// over a visible-but-empty control wherever nothing assigns one.
    private func refreshIPAddressRow() {
        ipAddressCopyValue = nil
        switch resolved.ipAddress {
        case .unavailable:
            ipAddressRow?.isHidden = true
        case .externallyAssigned:
            ipAddressRow?.isHidden = false
            ipAddressCopyButton?.isHidden = true
            ipAddressValueLabel?.stringValue = "Assigned by your network"
        case .pending:
            ipAddressRow?.isHidden = false
            ipAddressCopyButton?.isHidden = true
            ipAddressValueLabel?.stringValue = "—"
        case .reserved(let address):
            ipAddressRow?.isHidden = false
            ipAddressCopyValue = address
            ipAddressCopyButton?.isHidden = false
            ipAddressValueLabel?.stringValue = address
        }
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

    // MARK: Port Forwarding

    /// The Port forwarding block: a title, one row per rule, and the trailing
    /// Add Rule row. `refreshPortForwardingRows()` owns its contents;
    /// `refreshNetwork()` owns its visibility.
    private func makePortForwardingRow() -> GroupedFormCollapsibleRow {
        let title = NSTextField(labelWithString: "Port forwarding")
        title.font = Typography.body
        title.isSelectable = false

        portForwardingListStack = makeGroupedFormListStack()
        portForwardingListStack.spacing = Spacing.small

        let content = NSStackView(views: [title, portForwardingListStack])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Spacing.small
        content.translatesAutoresizingMaskIntoConstraints = false
        portForwardingListStack.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let row = GroupedFormCollapsibleRow(row: content)
        portForwardingRow = row
        return row
    }

    /// Rebuilds the rule rows when the rules — or the lock state their controls
    /// carry — changed.
    private func refreshPortForwardingRows() {
        let rendered = RenderedPortForwardingRows(
            rules: instance.configuration.portForwardingRules, controlsEnabled: !isReadOnly)
        guard rendered != renderedPortForwardingRows else { return }
        renderedPortForwardingRows = rendered
        clearGroupedFormStack(portForwardingListStack)
        for (index, rule) in rendered.rules.enumerated() {
            addGroupedFormFullWidth(
                makePortForwardingRuleRow(rule, index: index, enabled: rendered.controlsEnabled),
                to: portForwardingListStack)
        }
        addGroupedFormFullWidth(
            makeAddPortForwardingRuleRow(enabled: rendered.controlsEnabled),
            to: portForwardingListStack)
    }

    /// How one rule's ports read in the card — the guest side of the arrow is
    /// where traffic lands.
    private static func portForwardingRuleText(_ rule: PortForwardingRule) -> String {
        "Host \(rule.hostPort) → Guest \(rule.guestPort)"
    }

    private func makePortForwardingRuleRow(
        _ rule: PortForwardingRule, index: Int, enabled: Bool
    ) -> NSView {
        let transport = NSTextField(labelWithString: rule.transport.displayName)
        transport.font = Typography.body
        transport.textColor = .secondaryLabelColor
        transport.isSelectable = false
        transport.setContentHuggingPriority(.required, for: .horizontal)
        transport.widthAnchor.constraint(equalToConstant: 38).isActive = true

        let ports = NSTextField(labelWithString: Self.portForwardingRuleText(rule))
        ports.font = Typography.body
        ports.isSelectable = false
        ports.lineBreakMode = .byTruncatingTail

        let remove = NSButton()
        remove.image = .systemSymbol("minus.circle", accessibilityDescription: "Remove Rule")
        remove.imagePosition = .imageOnly
        remove.isBordered = false
        remove.contentTintColor = .secondaryLabelColor
        remove.toolTip = "Remove Rule"
        remove.isEnabled = enabled
        remove.tag = index
        remove.target = self
        remove.action = #selector(removePortForwardingRuleTapped)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [transport, ports, spacer, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.standard
        return row
    }

    private func makeAddPortForwardingRuleRow(enabled: Bool) -> NSView {
        let add = NSButton(
            title: "Add Rule…", target: self, action: #selector(addPortForwardingRuleTapped))
        add.image = .systemSymbol("plus.circle", accessibilityDescription: "")
        add.imagePosition = .imageLeading
        add.isBordered = false
        add.bezelStyle = .badge
        add.contentTintColor = .controlAccentColor
        add.isEnabled = enabled
        add.setContentHuggingPriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [add, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.standard
        return row
    }

    /// Every (transport, host port) pair any VM in the library claims.
    ///
    /// The claim is held by the persisted configuration, not by the mode: a rule
    /// survives a switch away from Shared Network and takes its host port back
    /// on the way in, so a VM in another mode counts too — otherwise two VMs end
    /// up holding the same port and one of them silently stops forwarding.
    private func takenHostPortClaims() -> Set<PortForwardingHostClaim> {
        var claims = Set(instance.configuration.portForwardingRules.map(\.hostClaim))
        for other in viewModel.instances where other.id != instance.id {
            claims.formUnion(other.configuration.portForwardingRules.map(\.hostClaim))
        }
        return claims
    }

    #if DEBUG
    /// The claim set the Add Rule sheet is built with, for tests.
    var takenHostPortClaimsForTesting: Set<PortForwardingHostClaim> { takenHostPortClaims() }
    #endif

    private func writePortForwardingRules(_ rules: [PortForwardingRule]) {
        viewModel.updateConfiguration(of: instance) { $0.portForwardingRules = rules }
        // The rows are built from the configuration, so re-render with the
        // write rather than waiting for the model-observation pass — and the
        // card counts the same rules.
        refreshResolved()
        refreshPortForwardingRows()
    }

    /// While the pane is read-only, whether the Mode picker stays live as the
    /// hot-swap surface: swapping the attachment needs a running or live-paused
    /// session and a network device to swap on — None-mode VMs have no device,
    /// and devices cannot be added or removed at runtime.
    private var networkModeIsLiveSwitchable: Bool {
        guard isReadOnly else { return false }
        return instance.configuration.networkEnabled
            && (instance.status == .running || instance.isLivePaused)
    }

    private func makeNetworkModePopUp() -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.controlSize = .small
        // Otherwise AppKit re-derives each item's enabled state on every event,
        // undoing the deliberately-disabled entries below.
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
    /// `choice` is deliberately non-optional: in an optional context Swift reads
    /// the `.none` case as `nil`, which would strip the None entry's identity.
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
        let forwards = resolved.portForwardingRuleCount != nil
        portForwardingRow?.isHidden = !forwards
        if forwards { refreshPortForwardingRows() }
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

    /// Gives a VM turning networking on its first MAC address.
    ///
    /// A VM created with networking off carries none, and VZ then generates a
    /// fresh random one at every start — so the address the LAN sees, and any
    /// DHCP reservation keyed on it, would change from one boot to the next.
    private static func mintMACAddressIfNeeded(_ config: inout VMConfiguration) {
        guard config.macAddress == nil else { return }
        config.macAddress = VZMACAddress.randomLocallyAdministered().string
    }

    /// The canonical form of the MAC address `text` names — lowercase,
    /// colon-separated — or `nil` when it names none a guest can use.
    ///
    /// `VZMACAddress(string:)` takes six colon-separated hex pairs in either
    /// case and rejects every other spelling, so case is the only thing left to
    /// normalize. It also accepts the all-zero address and multicast/broadcast
    /// addresses, none of which a station can send from: a guest configured
    /// with one gets no link, and the app would key its reservation and
    /// forwarding rules on an address no frame can source
    /// (docs/NETWORKING.md principle 3 — refuse at entry what cannot take
    /// effect).
    static func normalizedMACAddress(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = VZMACAddress(string: trimmed), address.isUnicastAddress,
            address.string != Self.unspecifiedMACAddress
        else { return nil }
        return address.string
    }

    /// The all-zero address, which parses and reads as unicast but addresses
    /// nothing.
    private static let unspecifiedMACAddress = "00:00:00:00:00:00"

    @objc private func generateMACAddressTapped() {
        // Clicking a push button takes no first responder, so an edit open in
        // the field would outlive the write and commit over it on the way out.
        // Discard it rather than settling it: the generated address supersedes
        // whatever was typed, so committing first would only refuse a typed
        // duplicate with an alert about an address no longer in play.
        macAddressField.abortEditing()
        writeConfig { $0.macAddress = VZMACAddress.randomLocallyAdministered().string }
        refreshResolved()
        refreshNetwork()
    }

    @objc private func networkModeChanged() {
        guard let choice = networkModePopUp.selectedItem?.representedObject as? NetworkModeChoice
        else { return }
        let accepted: Bool
        switch choice {
        case .shared:
            // `bridgedInterfaceIdentifier` is left alone so switching back to
            // Bridged remembers the interface.
            accepted = writeConfig {
                $0.networkEnabled = true
                $0.networkMode = .shared
                Self.mintMACAddressIfNeeded(&$0)
            }
        case .hostOnly:
            accepted = writeConfig {
                $0.networkEnabled = true
                $0.networkMode = .hostOnly
                Self.mintMACAddressIfNeeded(&$0)
            }
        case .none:
            accepted = writeConfig { $0.networkEnabled = false }
        case .bridged(let identifier):
            accepted = writeConfig {
                $0.networkEnabled = true
                $0.networkMode = .bridged
                $0.bridgedInterfaceIdentifier = identifier
                Self.mintMACAddressIfNeeded(&$0)
            }
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

    @objc private func addPortForwardingRuleTapped() {
        guard !isReadOnly, let window = view.window, !portForwardingSheetPresenter.isShown else {
            return
        }
        let sheet = PortForwardingRuleSheetContentViewController(
            takenHostClaims: takenHostPortClaims())
        sheet.delegate = self
        portForwardingSheetPresenter.show(content: sheet, in: window)
    }

    @objc private func removePortForwardingRuleTapped(_ sender: NSButton) {
        guard !isReadOnly else { return }
        var rules = instance.configuration.portForwardingRules
        guard rules.indices.contains(sender.tag) else { return }
        rules.remove(at: sender.tag)
        writePortForwardingRules(rules)
    }

    /// Persists the typed MAC in canonical form, then shows the address the VM
    /// ended up with — so text naming no address a guest can use, and an address
    /// the library refused because another VM holds it, both snap the field back.
    /// The tooltip names the accepted spelling; the refusal carries its own alert.
    ///
    /// The field is written directly rather than through
    /// `refreshMACAddressRow()`: editing is still ending here, so the editor the
    /// refresh defers to is the very one being reconciled away.
    private func applyMACAddressFieldEdit() {
        if let normalized = Self.normalizedMACAddress(macAddressField.stringValue) {
            writeConfig { $0.macAddress = normalized }
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
        renderedPortForwardingRows = nil
        let section = buildNetworkSection()
        panelStack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalTo: panelStack.widthAnchor).isActive = true
    }

    func refresh() {
        lockRegistry.apply(isReadOnly: isReadOnly)
        refreshNetwork()
    }

    func prepareForDisappearance() {
        if portForwardingSheetPresenter.isShown { portForwardingSheetPresenter.close() }
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

// MARK: - PortForwardingRuleSheetContentViewControllerDelegate

extension VMSettingsNetworkPanelViewController:
    PortForwardingRuleSheetContentViewControllerDelegate
{
    func portForwardingRuleSheet(
        _ vc: PortForwardingRuleSheetContentViewController, didAdd rule: PortForwardingRule
    ) {
        portForwardingSheetPresenter.close()
        writePortForwardingRules(instance.configuration.portForwardingRules + [rule])
    }

    func portForwardingRuleSheetDidCancel(_ vc: PortForwardingRuleSheetContentViewController) {
        portForwardingSheetPresenter.close()
    }
}
