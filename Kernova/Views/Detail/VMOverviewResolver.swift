import AVFoundation
import Foundation

/// What a Mode menu item selects, and how every surface naming the mode names
/// it.
///
/// `bridged`'s payload is the host interface identifier, `nil` for Automatic.
enum NetworkModeChoice: Equatable {
    case shared
    case hostOnly
    case none
    case bridged(String?)

    init(_ configuration: VMConfiguration) {
        guard configuration.networkEnabled else {
            self = .none
            return
        }
        switch configuration.networkMode {
        case .shared: self = .shared
        case .hostOnly: self = .hostOnly
        case .bridged: self = .bridged(configuration.bridgedInterfaceIdentifier)
        }
    }

    /// Whether naming this choice takes the host's bridgeable interfaces, which
    /// only an enumeration answers.
    var namesAHostInterface: Bool {
        if case .bridged(.some) = self { return true }
        return false
    }

    /// The Mode picker's title for this choice, which is what the Network card
    /// states beside the address.
    ///
    /// A mode the signature does not authorize still names itself, marked
    /// unavailable: the picker offers no entry for it, so this is what shows a
    /// VM already on it what it is set to.
    func title(entitled: Bool, interfaces: [BridgedInterface]) -> String {
        switch self {
        case .shared:
            return "Shared Network"
        case .hostOnly:
            return entitled ? "Host Only" : "Host Only (unavailable)"
        case .none:
            return "None"
        case .bridged(let identifier):
            guard entitled else { return "Bridged (unavailable)" }
            guard let identifier else { return "Automatic" }
            guard let interface = interfaces.first(where: { $0.identifier == identifier }) else {
                return "\(identifier) (unavailable)"
            }
            return Self.interfaceTitle(interface)
        }
    }

    /// How one bridgeable interface reads in the picker — `Wi-Fi (en0)`, or the
    /// bare identifier when the host names it nothing else.
    static func interfaceTitle(_ interface: BridgedInterface) -> String {
        guard interface.localizedDisplayName != interface.identifier else {
            return interface.identifier
        }
        return "\(interface.localizedDisplayName) (\(interface.identifier))"
    }
}

/// What the guest's IPv4 address resolves to for the mode it is on.
enum VMOverviewIPAddress: Equatable, Sendable {
    /// Nothing assigns the guest an address the app can state — the row is
    /// absent rather than empty.
    case unavailable
    /// Bridged: the guest asks the network, so there is nothing deterministic.
    case externallyAssigned
    /// A reservation exists but the network's addressing is not known yet.
    case pending
    case reserved(String)

    /// The address as a surface states it, `nil` where there is nothing to say.
    var displayText: String? {
        switch self {
        case .unavailable, .pending: nil
        case .externallyAssigned: "Assigned by your network"
        case .reserved(let address): address
        }
    }
}

/// The settings pane's resolved values for one VM: everything its surfaces state
/// that the configuration alone cannot answer.
///
/// View-less, so switching VMs paints the overview's cards without the six
/// panels that would otherwise have to exist to answer for them, and the panel
/// showing the same figure reads it here rather than resolving it a second time.
///
/// Three reads land asynchronously — the boot disk's capacity, the snapshots'
/// footprint, and the vmnet materialization behind a pending address. Each is
/// keyed to the VM it was issued for and reported through ``onCategoryResolved``
/// so one card, or one row, repaints.
@MainActor
final class VMOverviewResolver {
    /// How many macOS guests macOS itself will run at the same time.
    ///
    /// The cap is the platform's, enforced by VZ — a start past it fails, which
    /// is what ``VMLibraryViewModel/explainedFailure(for:on:)`` explains after
    /// the fact. Here it is read ahead of time, off the marked set.
    static let concurrentMacOSGuestLimit = 2

    /// What the Audio banner — and the System card's warning glyph — say about a
    /// refused microphone.
    static let micPermissionDeniedWarning =
        "Microphone permission is denied. Enable it in System Settings for Kernova to pass your microphone to VMs."

    private(set) var resolved = VMOverviewResolved()

    /// Fires when an async read lands, naming the category whose value moved.
    var onCategoryResolved: ((VMSettingsCategory) -> Void)?

    private let entitlements: EntitlementService
    private let vmnetNetworks: any VmnetNetworkProviding
    private let bridgedInterfaces: any BridgedInterfaceProviding
    private let micPermissionStatus: @MainActor () -> AVAuthorizationStatus

    private var instance: VMInstance
    private var viewModel: VMLibraryViewModel

    /// The microphone permission as last read; re-read when the app comes
    /// forward, where System Settings may have changed it.
    private var micPermission: AVAuthorizationStatus

    /// The choice the mode title was named for, so naming it again — which
    /// enumerates the host's bridgeable interfaces — happens only when the mode
    /// moves.
    private var titledNetworkChoice: NetworkModeChoice?

    /// The VM and disk the capacity was last read for, so a re-resolve re-uses
    /// the figure instead of re-reading the file.
    private var bootDiskKey: BootDiskKey?
    private var bootDiskTask: Task<Void, Never>?

    /// The snapshot ids the size read was last issued for, so it re-runs when
    /// the set changes rather than on every pass.
    private var snapshotSizeIDs: [UUID]?
    private var snapshotSizeTask: Task<Void, Never>?

    private var ipMaterializeTask: Task<Void, Never>?

    private struct BootDiskKey: Equatable {
        let instanceID: UUID
        let path: String
        let isInternal: Bool
    }

    init(
        instance: VMInstance,
        viewModel: VMLibraryViewModel,
        entitlements: EntitlementService,
        vmnetNetworks: any VmnetNetworkProviding,
        bridgedInterfaces: any BridgedInterfaceProviding,
        micPermissionStatus: @escaping @MainActor () -> AVAuthorizationStatus
    ) {
        self.instance = instance
        self.viewModel = viewModel
        self.entitlements = entitlements
        self.vmnetNetworks = vmnetNetworks
        self.bridgedInterfaces = bridgedInterfaces
        self.micPermissionStatus = micPermissionStatus
        self.micPermission = micPermissionStatus()
    }

    // MARK: - Binding

    /// Rebinds to a (possibly different) VM; a different one drops every stored
    /// value and in-flight read, which described the outgoing one.
    func bind(instance: VMInstance, viewModel: VMLibraryViewModel) {
        let instanceChanged = instance.id != self.instance.id
        self.instance = instance
        self.viewModel = viewModel
        guard instanceChanged else { return }
        bootDiskTask?.cancel()
        bootDiskTask = nil
        bootDiskKey = nil
        snapshotSizeTask?.cancel()
        snapshotSizeTask = nil
        snapshotSizeIDs = nil
        ipMaterializeTask?.cancel()
        ipMaterializeTask = nil
        titledNetworkChoice = nil
        resolved = VMOverviewResolved()
    }

    /// The pane is going away: drop the reads that would paint it unseen.
    func prepareForDisappearance() {
        snapshotSizeTask?.cancel()
        snapshotSizeTask = nil
        // Re-read on the next pass: the sizes may have moved while away.
        snapshotSizeIDs = nil
    }

    /// Re-reads the microphone permission, which System Settings — or macOS's
    /// own prompt — may have changed since the last pass.
    func rereadMicPermission() {
        micPermission = micPermissionStatus()
    }

    // MARK: - Resolution

    /// Re-resolves every value from the model. Idempotent; the off-main reads
    /// re-issue only when what they answer for changed.
    func refresh() {
        let config = instance.configuration
        resolved.warnings[.general] = Self.autoStartCapacityWarning(
            isMacOSGuest: config.guestOS == .macOS,
            markedMacOSVMCount: viewModel.macOSVMNamesMarkedForAutoStart.count)
        resolved.warnings[.network] = duplicateMACWarning(config)
        resolved.micWarning = micPermissionPresentation(
            micPermission, audioInputEnabled: config.audioInputEnabled)
        resolved.warnings[.system] =
            resolved.micWarning == .denied ? Self.micPermissionDeniedWarning : nil
        resolved.canTakeSnapshot = viewModel.canTakeSnapshot(instance)
        refreshNetwork(config)
        refreshBootDisk()
        refreshSnapshotSizes()
    }

    /// Warning for a marked set macOS cannot run at once, or `nil` when it fits.
    ///
    /// Shown only on a macOS guest's own pane: it is the guests past the cap
    /// that fail, and the pane a user is looking at is the one they can act on.
    /// Linux guests do not count against the macOS cap and never see it.
    static func autoStartCapacityWarning(
        isMacOSGuest: Bool, markedMacOSVMCount: Int
    ) -> String? {
        guard isMacOSGuest, markedMacOSVMCount > concurrentMacOSGuestLimit else { return nil }
        return "\(markedMacOSVMCount) macOS virtual machines are set to start when Kernova opens. "
            + "macOS allows at most two macOS virtual machines to run at once, "
            + "so the ones after the first two won't start."
    }

    /// Discloses that another VM in the library carries this one's MAC address.
    ///
    /// Shown wherever the MAC row is: an address is held while networking is
    /// off, but nothing shows it there to contradict.
    private func duplicateMACWarning(_ config: VMConfiguration) -> String? {
        guard config.networkEnabled, config.macAddress != nil else { return nil }
        let names = viewModel.vmNamesSharingMACAddress(with: instance)
        guard !names.isEmpty else { return nil }
        return "This MAC address is also used by \(names.map { "“\($0)”" }.joined(separator: ", ")). "
            + "Each virtual machine needs its own."
    }

    private func refreshNetwork(_ config: VMConfiguration) {
        let choice = NetworkModeChoice(config)
        if choice != titledNetworkChoice {
            titledNetworkChoice = choice
            resolved.networkModeTitle = choice.title(
                entitled: entitlements.hasVMNetworking,
                interfaces: choice.namesAHostInterface ? bridgedInterfaces.interfaces() : [])
        }
        resolved.ipAddress = resolveIPAddress(config)
        // Rules ride the app-managed shared network, and reach the guest at the
        // address its MAC reserves: an unentitled build attaches system NAT,
        // which forwards nothing, the other modes carry no forwarding at all,
        // and without a MAC there is no reservation to forward to.
        let forwards =
            config.networkEnabled && config.networkMode == .shared
            && entitlements.hasVMNetworking && config.macAddress != nil
        resolved.portForwardingRuleCount = forwards ? config.portForwardingRules.count : nil
    }

    /// Names the address the app reserved for the guest, kicking a
    /// materialization when the network's addressing is not known yet — the
    /// reservation is meant to be shown even while the VM is stopped.
    private func resolveIPAddress(_ config: VMConfiguration) -> VMOverviewIPAddress {
        guard config.networkEnabled else { return .unavailable }
        let mode = config.networkMode
        switch mode {
        case .bridged:
            return .externallyAssigned
        case .shared, .hostOnly:
            // Without the entitlement (or a MAC to key on) there is no
            // reservation machinery behind the row.
            guard entitlements.hasVMNetworking, let mac = config.macAddress,
                let kind = VmnetNetworkKind(mode: mode)
            else { return .unavailable }
            vmnetNetworks.reserveAddressIfNeeded(for: mac, kind: kind)
            if let address = vmnetNetworks.reservedAddress(for: mac, kind: kind) {
                return .reserved(address)
            }
            materializeForIPAddress(kind)
            return .pending
        }
    }

    /// Materializes `kind`'s network off-main so a pending address can fill in.
    /// Single-flight — every pass over a still-pending address lands here, and
    /// one materialization serves them all.
    private func materializeForIPAddress(_ kind: VmnetNetworkKind) {
        guard ipMaterializeTask == nil else { return }
        let networks = vmnetNetworks
        ipMaterializeTask = Task { [weak self] in
            let materialized = await networks.materializeNetwork(for: kind)
            // A materialization does not honor cancellation, so a task
            // superseded by ``bind(instance:viewModel:)`` still resumes here:
            // without this it would paint for a VM the pane has left and clear
            // the token its successor holds, letting a duplicate start.
            guard !Task.isCancelled, let self else { return }
            // Re-resolve before clearing the single-flight token: a slot the
            // materialized network can't serve (subnet capacity, pending
            // reservation) leaves the address underivable, and re-arming from
            // that resolve would spin materialize→resolve forever.
            if materialized {
                self.resolved.ipAddress = self.resolveIPAddress(self.instance.configuration)
                self.onCategoryResolved?(.network)
            }
            self.ipMaterializeTask = nil
        }
    }

    /// Reads the boot disk's capacity off the main thread. The key tags the
    /// read, so a re-bind to another VM — or another disk — ignores a result
    /// issued for the previous one.
    private func refreshBootDisk() {
        let key = instance.displayedStorageDisks.first.map {
            BootDiskKey(instanceID: instance.id, path: $0.path, isInternal: $0.isInternal)
        }
        guard key != bootDiskKey else { return }
        bootDiskKey = key
        resolved.bootDiskBytes = nil
        bootDiskTask?.cancel()
        bootDiskTask = nil
        guard let key else { return }
        let bundleLayout = instance.bundleLayout
        bootDiskTask = Task { [weak self] in
            let sizes = await Task.detached {
                bundleLayout.diskSizes(forRelativePath: key.path, isInternal: key.isInternal)
            }.value
            guard !Task.isCancelled, let self, self.bootDiskKey == key else { return }
            self.resolved.bootDiskBytes = sizes.capacityBytes
            self.onCategoryResolved?(.storage)
        }
    }

    /// Reads what the snapshots occupy off the main actor — a directory walk
    /// over gigabyte-scale copies — and only when the set of snapshots changed.
    private func refreshSnapshotSizes() {
        let ids = instance.snapshotManifest.ordered.map(\.id)
        guard ids != snapshotSizeIDs else { return }
        snapshotSizeIDs = ids
        // A size is keyed by its snapshot's id, so one for a snapshot the set
        // still holds stays true until the fresh read replaces it — only what
        // the set no longer holds is dropped. Clearing them all would blank
        // every row and the readout for the length of the directory walk.
        let kept = Set(ids)
        resolved.snapshotSizes = resolved.snapshotSizes.filter { kept.contains($0.key) }
        resolved.snapshotTotalBytes = Self.totalBytes(of: resolved.snapshotSizes, for: ids)
        snapshotSizeTask?.cancel()
        snapshotSizeTask = nil
        guard !ids.isEmpty else { return }
        let issuedFor = instance
        let viewModel = self.viewModel
        snapshotSizeTask = Task { [weak self] in
            let sizes = await viewModel.snapshotOnDiskBytes(for: issuedFor)
            // The pane is reused across route and VM changes, so a read that
            // lands after the user moved on must not state the new VM's sizes.
            guard !Task.isCancelled, let self, self.instance.id == issuedFor.id else { return }
            self.resolved.snapshotSizes = sizes
            self.resolved.snapshotTotalBytes = Self.totalBytes(of: sizes, for: ids)
            self.onCategoryResolved?(.snapshots)
        }
    }

    /// What the snapshots in `ids` occupy together, `nil` until every one of
    /// them has been measured.
    ///
    /// A partial sum would understate the footprint; the readout beside the
    /// panel's own list falls back to the bare count on the same terms.
    private static func totalBytes(of sizes: [UUID: UInt64], for ids: [UUID]) -> UInt64? {
        guard !ids.isEmpty else { return nil }
        let measured = ids.compactMap { sizes[$0] }
        guard measured.count == ids.count else { return nil }
        return measured.reduce(UInt64(0), &+)
    }

    #if DEBUG
    /// The in-flight size read, so a test awaits it instead of polling the
    /// total it fills in.
    var snapshotSizeTaskForTesting: Task<Void, Never>? { snapshotSizeTask }

    /// The in-flight address materialization, for event-driven test waits.
    var ipMaterializeTaskForTesting: Task<Void, Never>? { ipMaterializeTask }

    /// The in-flight boot-disk capacity read, for event-driven test waits.
    var bootDiskTaskForTesting: Task<Void, Never>? { bootDiskTask }
    #endif
}
