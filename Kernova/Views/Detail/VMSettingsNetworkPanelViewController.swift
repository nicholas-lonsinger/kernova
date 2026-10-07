import AppKit
import KernovaKit

/// The Network category: the Mode picker — every network the VM can join, in
/// one menu — and the address and MAC rows behind it.
///
/// A single-section category, so the section draws no header of its own and
/// hands its lock hint to the panel header.
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
    /// The Network header's lock hint, hidden — unlike its `lockHints` peers —
    /// while the picker is the live-switch surface.
    private var networkLockHint: NSView?
    /// The MAC address row, hidden while the VM has no network device or has
    /// yet to be given an address.
    private var macAddressRow: GroupedFormCollapsibleRow?
    private var macAddressField = ModelValueField()
    private var ipAddressRow: GroupedFormCollapsibleRow?
    private var ipAddressValueLabel: NSTextField?
    private var ipAddressCopyButton: CopyValueButton?
    /// Holds the banner naming the other VMs sharing this one's MAC address.
    private var networkWarningContainer = NSStackView()

    /// The duplicate-MAC banner's rendered message, `nil` when no banner is
    /// shown, so a pass that changed nothing about it skips the rebuild.
    private var renderedNetworkMACWarning: String?
    /// What the Mode menu was last built from, so a `refresh()` pass that
    /// changed nothing about networking skips a rebuild.
    private var renderedNetworkMenu: NetworkMenuBasis?
    /// The host's bridgeable interfaces as the last picker open found them,
    /// `nil` until one has. Held so a rebuild triggered by the mode the user
    /// just picked from that list still knows the list — rebuilding blind would
    /// render their own choice as an unavailable entry.
    private var enumeratedInterfaces: [BridgedInterface]?

    // MARK: Network

    /// The Mode row's info: one paragraph per mode in `offered` — the modes
    /// the picker offers — and per kind of network it offers beyond a mode's
    /// common one, and nothing about one it cannot offer.
    ///
    /// "UI copy states only what is known": the Shared reach clause points at
    /// the IP address row only while that row shows a Shared guest's address
    /// (`sharedAddressShown`), and the Wi-Fi limitation is stated at the
    /// standard's strength, on the surface the user picks a mode from.
    static func modeInfoParagraphs(
        offered: Set<VMNetworkMode>, isolationOffered: Bool, namedNetworksOffered: Bool,
        sharedAddressShown: Bool, guestOS: VMGuestOS
    ) -> [InfoPopoverParagraph] {
        let sharedReachClause =
            sharedAddressShown
            ? "this Mac reaches it at the address in the IP address row"
            : "this Mac reaches it at its address on that subnet"
        var paragraphs: [InfoPopoverParagraph] = []
        if offered.contains(.shared) {
            paragraphs.append(
                .body(
                    "Shared Network: outbound access through this Mac. The guest gets a DHCP address on a private subnet that other machines on your network can't reach; \(sharedReachClause)."
                ))
        }
        if offered.contains(.hostOnly) {
            paragraphs.append(
                .body(
                    "Host Only: a private network shared with this Mac and other Host Only guests, with no access to your network or the internet."
                ))
        }
        if isolationOffered {
            paragraphs.append(
                .body(
                    "Isolated: a network of the guest's own instead of the one every other virtual machine in its mode joins. It keeps its mode's reach to this Mac — and, for Shared Network, to the internet — while no other virtual machine can reach it."
                ))
        }
        if namedNetworksOffered {
            paragraphs.append(
                .body(
                    "Named Networks: only the virtual machines on the same named network reach each other there, each in the mode the network was created with. Create, rename and delete them in Kernova > Settings > Networks."
                ))
        }
        if offered.contains(.bridged) {
            paragraphs += [
                .body(
                    "Bridged: joins your network through the chosen interface and requests its own address, like a separate machine."
                ),
                .body(
                    "Bridged traffic bypasses a VPN running on this Mac. Bridging over Wi-Fi is best-effort — the Wi-Fi standard does not bridge additional stations — so prefer a wired interface."
                ),
            ]
        }
        if guestOS == .linux {
            paragraphs.append(
                .body(
                    "The interface usually appears as `enp0s1`. If networking doesn't come up, make sure your distro's DHCP client or NetworkManager is running."
                ))
        }
        return paragraphs
    }

    private func buildNetworkSection() -> NSView {
        // Outside `lockableRows`: the picker is the live-switch surface while
        // the VM runs, so `refreshNetwork()` owns its enablement and its row's
        // dimming (and the section lock hint it makes moot).
        networkModePopUp = makeNetworkModePopUp()
        let modeRow = makeGroupedFormCardRow(
            "Mode", control: networkModePopUp, info: modeInfoParagraphs())
        // Read on each click: the Shared paragraph names the IP address row
        // only while it shows an address.
        modeRow.infoButton?.configure(label: "Mode") { [weak self] in self?.modeInfoParagraphs() ?? [] }

        let rows: [NSView] = [modeRow, makeIPAddressRow(), makeMACAddressRow()]
        networkWarningContainer = NSStackView()
        networkWarningContainer.orientation = .vertical
        networkWarningContainer.alignment = .leading
        networkWarningContainer.spacing = Spacing.small
        networkWarningContainer.translatesAutoresizingMaskIntoConstraints = false

        // The Network panel's only section, so its lock hint moves to the panel
        // header rather than repeating the category name inside the form.
        let hint = lockRegistry.makeLockHint { self.networkLockHint = $0 }
        chrome = VMSettingsPanelChrome(trailing: [hint])
        return makeGroupedFormSection([makeGroupedFormCard(rows: rows), networkWarningContainer])
    }

    /// The IP address row: the address the host last saw the guest use, with a
    /// copy affordance, or the prose `GuestIPAddress.displayText` states
    /// instead. `refreshIPAddressRow()` owns its content and visibility.
    private func makeIPAddressRow() -> GroupedFormCollapsibleRow {
        let value = makeGroupedFormValueLabel("")
        ipAddressValueLabel = value

        let copy = CopyValueButton(name: "Copy IP Address")
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
        ipAddressRow?.isHidden = address.displayText == nil
        ipAddressCopyButton?.value = address.address
        ipAddressValueLabel?.stringValue = address.displayText ?? ""
    }

    /// The Mode info for this VM as the panel shows it now.
    private func modeInfoParagraphs() -> [InfoPopoverParagraph] {
        Self.modeInfoParagraphs(
            offered: offeredModes,
            isolationOffered: VmnetNetworkKind.allCases.contains {
                offers(.vmnet($0, .isolated))
            },
            namedNetworksOffered: SettingsPane.networks.isOffered(by: entitlements),
            sharedAddressShown: instance.configuration.networkMode == .shared
                && resolved.ipAddress.address != nil,
            guestOS: instance.configuration.guestOS)
    }

    // MARK: MAC Address

    /// The MAC address row: an editable, VZ-validated field and a Generate
    /// button. `refreshMACAddressRow()` owns its content and visibility.
    private func makeMACAddressRow() -> GroupedFormCollapsibleRow {
        macAddressField = ModelValueField()
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
        macAddressField.show(instance.configuration.macAddress ?? "")
    }

    /// What the Mode picker takes right now: which kinds of change, so each
    /// entry enables by the change choosing it would make.
    private struct NetworkPickerReach: Equatable {
        /// A move to another mode, or another bridged interface.
        var mode: Bool
        /// A move to another network of the VM's mode.
        var membership: Bool
        /// Removing the network device, which no running session takes.
        var none: Bool

        static let all = NetworkPickerReach(mode: true, membership: true, none: true)
    }

    /// The change each picker entry makes and whether it is taken now.
    ///
    /// While the pane is read-only, both live terms come from the catalog, so
    /// the picker and the verb behind it agree: the change takes an edit, and
    /// not because the VM is at rest — that case is the one the pane's own lock
    /// already covers. A running VM hot-swaps either; a suspended one whose
    /// saved state survives a move takes a membership change and no other.
    private var networkPickerReach: NetworkPickerReach {
        guard isReadOnly else { return .all }
        let capabilities = viewModel.capabilities
        let atRest = capabilities.isAvailable(.editConfiguration, on: instance)
        return NetworkPickerReach(
            mode: !atRest && capabilities.isAvailable(.switchNetworkMode, on: instance),
            membership: !atRest && capabilities.isAvailable(.switchNetworkMembership, on: instance),
            none: false)
    }

    /// Everything the Mode menu is built from but the bridgeable interfaces,
    /// whose enumeration rebuilds it on its own.
    private struct NetworkMenuBasis: Equatable {
        let choice: NetworkModeChoice
        let reach: NetworkPickerReach
        let networks: VMNetworkDirectory.State
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
    /// Each mode's common network, then the VM's own, for Shared Network and
    /// Host Only; None; the library's named networks, ending with the entry
    /// that opens them in Settings; and Bridged's interfaces. An entry this build cannot attach is left off, except the
    /// one the VM is on, which shows without being offered so it still
    /// selects.
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
        let basis = NetworkMenuBasis(
            choice: NetworkModeChoice(instance.configuration), reach: networkPickerReach,
            networks: viewModel.networks.state)
        renderedNetworkMenu = basis
        let current = basis.choice

        for kind in VmnetNetworkKind.menuOrder {
            for membership in [VMNetworkMembership.common, .isolated] {
                addNetworkEntry(.vmnet(kind, membership), basis: basis, to: menu)
            }
        }
        addNetworkModeItem(
            NetworkChoiceLabel("None"), choice: .none, to: menu, enabled: isTaken(.none, basis: basis))

        // The edit entry goes wherever the Settings window has a Networks pane
        // for it to open.
        let editable = SettingsPane.networks.isOffered(by: entitlements)
        switch basis.networks {
        case .listed(let networks):
            addNamedNetworkEntries(networks, basis: basis, editable: editable, to: menu)
        case .unreadable:
            // No named network can be offered, and the one the VM may be on
            // has no name to show: one entry says why, standing for the VM's
            // current choice when that is a named network, so it still selects.
            menu.addItem(.sectionHeader(title: "Named Networks"))
            if case .vmnet(_, .network) = current {
                addNetworkModeItem(
                    current.label(attachable: true, interfaces: [], networks: basis.networks),
                    choice: current, to: menu, enabled: false)
            } else {
                addNetworkModePlaceholder(NetworkModeChoice.unreadableNetworkListTitle, to: menu)
            }
            if editable { addEditNamedNetworksItem(selecting: nil, to: menu) }
        }

        if offers(.bridged) {
            menu.addItem(.sectionHeader(title: "Bridged"))
            for choice in [.bridged(nil)] + (interfaces ?? []).map({ NetworkModeChoice.bridged($0.identifier) }) {
                addNetworkModeItem(
                    choice.label(attachable: true, interfaces: interfaces ?? [], networks: .listed([])),
                    choice: choice, to: menu, enabled: isTaken(choice, basis: basis))
            }
            if interfaces?.isEmpty == true {
                addNetworkModePlaceholder("No Bridgeable Interfaces", to: menu)
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
                    NetworkChoiceLabel(resolved.networkModeTitle ?? persisted), choice: .bridged(persisted),
                    to: menu, enabled: false)
            }
        } else if case .bridged = current {
            // A bridged VM in a build the entitlement doesn't cover: the picker
            // offers no Bridged entry, so this one shows the mode without
            // offering it — carrying the current choice so it still selects.
            addNetworkModeItem(
                current.label(attachable: false, interfaces: [], networks: .listed([])), choice: current,
                to: menu, enabled: false)
        }

        selectNetworkModeItem()
    }

    /// Appends the Named Networks section over the listed `networks`: each one
    /// the picker offers or the VM is on, a disabled entry for a network the VM
    /// is on that the library does not list, and — when `editable` — the entry
    /// that opens them in Settings.
    private func addNamedNetworkEntries(
        _ networks: [VMNamedNetwork], basis: NetworkMenuBasis, editable: Bool, to menu: NSMenu
    ) {
        let current = basis.choice
        let named = networks.filter {
            offers(.vmnet($0.kind, .network($0.id))) || current == .vmnet($0.kind, .network($0.id))
        }
        // The VM's named network, split by whether the library lists it.
        var listedCurrent: UUID?
        var unlisted = false
        if case .vmnet(let kind, .network(let id)) = current {
            if networks.contains(where: { $0.id == id && $0.kind == kind }) {
                listedCurrent = id
            } else {
                unlisted = true
            }
        }
        guard editable || !named.isEmpty || unlisted else { return }
        menu.addItem(.sectionHeader(title: "Named Networks"))
        for network in named {
            addNetworkEntry(.vmnet(network.kind, .network(network.id)), basis: basis, to: menu)
        }
        if unlisted {
            // A network another library listed — an import, or a revert to a
            // snapshot taken before a delete: the VM still joins it, and no
            // surface here can choose it.
            addNetworkModeItem(
                current.label(attachable: true, interfaces: [], networks: basis.networks),
                choice: current, to: menu, enabled: false)
        }
        if editable { addEditNamedNetworksItem(selecting: listedCurrent, to: menu) }
    }

    /// Appends the entry that opens the library's named networks in Settings,
    /// with the network `id` identifies selected when there is one.
    private func addEditNamedNetworksItem(selecting id: UUID?, to menu: NSMenu) {
        let edit = NSMenuItem(title: "Edit Named Networks\u{2026}", action: nil, keyEquivalent: "")
        edit.representedObject = id.map(SettingsDestination.network) ?? .pane(.networks)
        menu.addItem(edit)
    }

    /// Appends `choice`'s entry when the picker offers it, and otherwise —
    /// when it is the VM's current network — a disabled one standing for it.
    private func addNetworkEntry(_ choice: NetworkModeChoice, basis: NetworkMenuBasis, to menu: NSMenu) {
        let offered = offers(choice)
        guard offered || choice == basis.choice else { return }
        addNetworkModeItem(
            choice.label(attachable: offered, interfaces: [], networks: basis.networks),
            choice: choice, to: menu, enabled: offered && isTaken(choice, basis: basis))
    }

    /// Whether choosing `choice` makes a change the picker takes now.
    private func isTaken(_ choice: NetworkModeChoice, basis: NetworkMenuBasis) -> Bool {
        guard choice != basis.choice else { return true }
        switch (choice, basis.choice) {
        case (.none, _):
            return basis.reach.none
        case (.vmnet(let kind, _), .vmnet(let currentKind, _)) where kind == currentKind:
            return basis.reach.membership
        default:
            return basis.reach.mode
        }
    }

    /// The modes the picker offers: Shared Network always, and each other mode
    /// whose network this build can attach.
    private var offeredModes: Set<VMNetworkMode> {
        Set(VMNetworkMode.allCases.filter { $0 == .shared || offers($0) })
    }

    /// Whether the picker offers `mode`: the network choosing it puts the VM
    /// on is one this build can attach — what the mode key's write checks.
    private func offers(_ mode: VMNetworkMode) -> Bool {
        offers { $0.applyNetworkMode(mode) }
    }

    /// Whether the picker offers `choice`: the network it puts the VM on is
    /// one this build can attach — what the network keys' writes check.
    private func offers(_ choice: NetworkModeChoice) -> Bool {
        offers { config in
            switch choice {
            case .vmnet(let kind, let membership):
                config.applyNetworkMode(kind.mode)
                config.networkMembership = membership
            case .none:
                config.applyNetworkMode(nil)
            case .bridged(let identifier):
                config.applyNetworkMode(.bridged)
                config.bridgedInterfaceIdentifier = identifier
            }
        }
    }

    /// Whether the network `change` puts the VM on is one this build can
    /// attach.
    private func offers(_ change: (inout VMConfiguration) -> Void) -> Bool {
        var candidate = instance.configuration
        change(&candidate)
        return candidate.joinedNetwork.map(entitlements.canAttach) ?? false
    }

    /// Appends one Mode entry.
    ///
    /// `choice` is non-optional: in an optional context Swift reads the
    /// `.none` case as `nil`, which would strip the None entry's identity.
    private func addNetworkModeItem(
        _ label: NetworkChoiceLabel, choice: NetworkModeChoice, to menu: NSMenu, enabled: Bool = true
    ) {
        let item = NSMenuItem(title: label.text, action: nil, keyEquivalent: "")
        if label.qualifier != nil {
            item.attributedTitle = label.menuTitle(
                font: networkModePopUp.font ?? .menuFont(ofSize: 0), enabled: enabled)
            // Assigning `attributedTitle` overwrites `title` with its bare
            // characters, and `title` is what VoiceOver and the popup's title
            // reads take — so it goes back to the joined label after.
            item.title = label.text
        }
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
        let reach = networkPickerReach
        let live = reach.mode || reach.membership
        applyGroupedFormRowEnabled(live, control: networkModePopUp)
        // `apply()` just showed every lock hint for the read-only pane; a live
        // picker makes this section's hint a false claim, so re-hide it.
        networkLockHint?.isHidden = live
        let basis = NetworkMenuBasis(
            choice: NetworkModeChoice(instance.configuration), reach: reach,
            networks: viewModel.networks.state)
        if basis != renderedNetworkMenu {
            rebuildNetworkModeMenu()
        }
        refreshMACAddressRow()
        refreshMACAddressWarning()
        refreshIPAddressRow()
    }

    /// Discloses that another VM in the library carries this one's MAC address.
    ///
    /// Import, load and reconcile admit a bundle whatever address it arrives
    /// with, so the shared address is visible here rather than refused at the
    /// door, with the address still editable.
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

    /// Acts on the entry just chosen, then puts the selection back on the
    /// configured network.
    ///
    /// AppKit has already selected the chosen entry, and a choice can leave
    /// the configuration where it was — a refused write, or Edit Named
    /// Networks…, which writes nothing — so the popup's selection is re-read
    /// from the configuration after every choice rather than left as clicked.
    @objc private func networkModeChanged() {
        defer { selectNetworkModeItem() }
        guard let entry = networkModePopUp.selectedItem?.representedObject else { return }
        switch entry {
        case let choice as NetworkModeChoice:
            apply(choice)
            // The write flips the card's row visibility; refresh in case the
            // value was already what the model held.
            refreshResolved()
            refreshNetwork()
        case let destination as SettingsDestination:
            context.showAppSettings(destination)
        default:
            break
        }
    }

    /// Writes the configuration keys `choice` moves.
    private func apply(_ choice: NetworkModeChoice) {
        let config = instance.configuration
        let mode = VMConfigurationKeyRegistry.networkMode
        switch choice {
        case .vmnet(let kind, let membership):
            // Both keys in one write, so a move to a named network of the
            // other mode lands whole; a key whose value stays is left out.
            write(
                contentsOf: [
                    config.effectiveNetworkMode == kind.mode
                        ? nil : mode.assigning(kind.mode.rawValue),
                    config.networkMembership == membership
                        ? nil
                        : VMConfigurationKeyRegistry.networkMembership.assigning(
                            membership.rawValue),
                ].compactMap { $0 })
        case .none:
            _ = write(mode.assigning(VMConfigurationKeyRegistry.noNetworkValue))
        case .bridged(let identifier):
            // The interface before the mode, so a picker choice that only
            // changes the interface still lands.
            _ = write(
                VMConfigurationKeyRegistry.networkBridgedInterface.assigning(identifier ?? ""),
                mode.assigning(VMNetworkMode.bridged.rawValue))
        }
    }

    /// Persists the typed MAC in canonical form, then shows the address the VM
    /// ended up with — so text naming no address a guest can use, and an
    /// address refused because another VM holds it or the VM's state pins it,
    /// both snap the field back. The tooltip names the accepted spelling; the
    /// refusal carries its own alert.
    private func applyMACAddressFieldEdit() {
        if macAddressField.holdsUserEdit,
            let normalized = GuestMACAddress.normalized(macAddressField.stringValue)
        {
            write(VMConfigurationKeyRegistry.networkMAC.assigning(normalized))
        }
        macAddressField.showDiscardingEdit(instance.configuration.macAddress ?? "")
    }

    // MARK: - Panel

    func rebuild() {
        loadViewIfNeeded()
        panelStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        lockRegistry.removeAll()
        renderedNetworkMACWarning = nil
        renderedNetworkMenu = nil
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

extension NetworkChoiceLabel {
    /// The label as a Mode entry draws it: the name in `font`, then the
    /// qualifier on the same line, smaller and in the secondary tint.
    ///
    /// An enabled entry's name carries no color, so AppKit colors it for the
    /// entry's state; a disabled entry dims both runs.
    func menuTitle(font: NSFont, enabled: Bool) -> NSAttributedString {
        var nameAttributes: [NSAttributedString.Key: Any] = [.font: font]
        if !enabled { nameAttributes[.foregroundColor] = NSColor.disabledControlTextColor }
        let title = NSMutableAttributedString(string: name, attributes: nameAttributes)
        guard let qualifier else { return title }
        title.append(NSAttributedString(string: " ", attributes: nameAttributes))
        title.append(
            NSAttributedString(
                string: qualifier,
                attributes: [
                    .font: NSFont.systemFont(ofSize: font.pointSize - 2),
                    .foregroundColor: enabled ? NSColor.secondaryLabelColor : .disabledControlTextColor,
                ]))
        return title
    }
}

extension VmnetNetworkKind {
    /// The order the Mode picker lists each kind's networks in.
    fileprivate static let menuOrder: [VmnetNetworkKind] = [.shared, .hostOnly]
}
