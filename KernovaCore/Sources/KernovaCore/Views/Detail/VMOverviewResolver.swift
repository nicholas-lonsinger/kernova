import AVFoundation
import Foundation
import KernovaKit

/// The settings pane's resolved values for one VM: everything its surfaces state
/// that the configuration alone cannot answer.
///
/// View-less, so switching VMs paints the overview's cards without the six
/// panels that would otherwise have to exist to answer for them, and the panel
/// showing the same figure reads it here rather than resolving it a second time.
///
/// Two reads land asynchronously — every attachment's sizes and the
/// snapshots' sizes. Each is keyed to the VM it was issued for and reported
/// through ``onCategoryResolved`` so one card, or one row, repaints.
@MainActor
package final class VMOverviewResolver {
    /// How many macOS guests macOS itself will run at the same time.
    ///
    /// The cap is the platform's, enforced by VZ — a start past it fails, which
    /// is what ``VMLibraryViewModel/explainedFailure(for:on:)`` explains after
    /// the fact. Here it is read ahead of time, off the marked set.
    static let concurrentMacOSGuestLimit = 2

    /// What the Audio banner — and the System card's warning glyph — say about a
    /// refused microphone.
    package static let micPermissionDeniedWarning = "Microphone permission is denied."

    /// Every resolved value, the network's label as the configuration names
    /// it now among them.
    package var resolved: VMOverviewResolved {
        var resolved = values
        resolved.networkModeLabel = networkModeLabel
        return resolved
    }

    /// Every resolved value but the network's label.
    private var values = VMOverviewResolved()

    /// How the VM's network names itself — the one naming every surface reads:
    /// named again whenever ``refresh()`` follows a configuration or network
    /// list change, and whenever the Mode picker enumerates the host's
    /// interfaces (``resolveNetworkModeLabel(enumerated:)``).
    package private(set) var networkModeLabel: NetworkChoiceLabel

    /// Fires when an async read lands, naming the category whose value moved.
    package var onCategoryResolved: ((VMSettingsCategory) -> Void)?

    /// Existence of every monitored attachment file the VM points at, which
    /// each ``refresh()`` points at the current configuration. A presence flip
    /// measures the attachment sizes again.
    package let fileMonitor: AttachmentFileMonitor

    private let bridgedInterfaces: any BridgedInterfaceProviding
    private let micPermissionStatus: @MainActor () -> AVAuthorizationStatus

    private var instance: VMInstance
    private var viewModel: VMLibraryViewModel

    /// The microphone permission as last read; re-read when the app comes
    /// forward, where System Settings may have changed it.
    private var micPermission: AVAuthorizationStatus

    /// The host's bridgeable interfaces as last enumerated, and the choice
    /// they were enumerated under — so a bridged interface is named from a
    /// new enumeration only when the choice moves, or the Mode picker opens.
    private var interfaceEnumeration: InterfaceEnumeration?

    /// The attachments, their files' presence and the lifecycle phase the
    /// attachment sizes were last measured under; a stopped VM's sizes move
    /// only when one of them does.
    private var attachmentMeasureKey: AttachmentMeasureKey?
    private var attachmentSizeTask: Task<Void, Never>?
    /// Counts measurements issued; only the newest one's result is applied.
    private var attachmentMeasureGeneration = 0

    /// The VM state the snapshot sizes were last measured in. A size is a
    /// measurement of shared blocks at one moment — a revert, a capture, a
    /// delete, or the guest writing until it stops all move it without touching
    /// the snapshot — so any change to the manifest or the lifecycle phase
    /// measures again.
    private var snapshotMeasureKey: SnapshotMeasureKey?
    private var snapshotSizeTask: Task<Void, Never>?
    /// Counts measurements issued; only the newest one's result is applied.
    private var snapshotMeasureGeneration = 0

    private struct SnapshotMeasureKey: Equatable {
        let manifest: VMSnapshotManifest
        let phaseCommits: Int
    }

    private struct AttachmentMeasureKey: Equatable {
        let images: [UUID: DiskImageReference]
        /// Whether ``fileMonitor`` reports each out-of-bundle image's file present.
        let presence: [UUID: Bool]
        let phaseCommits: Int
    }

    package init(
        instance: VMInstance,
        viewModel: VMLibraryViewModel,
        fileMonitor: AttachmentFileMonitor,
        bridgedInterfaces: any BridgedInterfaceProviding,
        micPermissionStatus: @escaping @MainActor () -> AVAuthorizationStatus
    ) {
        self.instance = instance
        self.viewModel = viewModel
        self.fileMonitor = fileMonitor
        self.bridgedInterfaces = bridgedInterfaces
        self.micPermissionStatus = micPermissionStatus
        self.micPermission = micPermissionStatus()
        let enumeration = Self.interfaceEnumeration(for: instance, from: bridgedInterfaces, reusing: nil)
        self.interfaceEnumeration = enumeration
        self.networkModeLabel = Self.networkModeLabel(of: instance, in: viewModel, interfaces: enumeration)
    }

    // MARK: - Binding

    /// Rebinds to a (possibly different) VM; a different one drops every stored
    /// value and in-flight read, which described the outgoing one.
    package func bind(instance: VMInstance, viewModel: VMLibraryViewModel) {
        let instanceChanged = instance.id != self.instance.id
        self.instance = instance
        self.viewModel = viewModel
        guard instanceChanged else { return }
        attachmentSizeTask?.cancel()
        attachmentSizeTask = nil
        attachmentMeasureKey = nil
        attachmentMeasureGeneration += 1
        snapshotSizeTask?.cancel()
        snapshotSizeTask = nil
        snapshotMeasureKey = nil
        snapshotMeasureGeneration += 1
        interfaceEnumeration = nil
        values = VMOverviewResolved()
        resolveNetworkModeLabel()
    }

    /// The pane is going away: drop the reads that would paint it unseen.
    package func prepareForDisappearance() {
        snapshotSizeTask?.cancel()
        snapshotSizeTask = nil
        snapshotMeasureGeneration += 1
        remeasureSnapshotSizes()
        attachmentSizeTask?.cancel()
        attachmentSizeTask = nil
        attachmentMeasureGeneration += 1
        remeasureAttachmentSizes()
    }

    /// Measures the snapshot sizes again on the next pass, whatever changed
    /// since the last measurement — for a surface stating them coming into view.
    package func remeasureSnapshotSizes() {
        snapshotMeasureKey = nil
    }

    /// Measures the attachment sizes again on the next pass, whatever changed
    /// since the last measurement — for a surface stating them coming into view.
    package func remeasureAttachmentSizes() {
        attachmentMeasureKey = nil
    }

    /// Re-reads the microphone permission, which System Settings — or macOS's
    /// own prompt — may have changed since the last pass.
    package func rereadMicPermission() {
        micPermission = micPermissionStatus()
    }

    // MARK: - Resolution

    /// Re-resolves every value from the model. Idempotent; the off-main reads
    /// re-issue only when what they answer for changed.
    package func refresh() {
        let config = instance.configuration
        values.warnings[.general] = Self.autoStartCapacityWarning(
            isMacOSGuest: config.guestOS == .macOS,
            markedMacOSVMCount: viewModel.macOSVMNamesMarkedForAutoStart.count)
        values.warnings[.network] = Self.duplicateMACWarning(
            sharingWith: config.networkEnabled && config.macAddress != nil
                ? viewModel.vmNamesSharingMACAddress(with: instance) : [])
        values.sharedMachineIDNote = Self.sharedMachineIDNote(
            holders: viewModel.vmNamesSharingMachineIdentity(with: instance))
        values.micWarning = micPermissionPresentation(
            micPermission, audioInputEnabled: config.audioInputEnabled)
        values.warnings[.system] =
            values.micWarning == .denied ? Self.micPermissionDeniedWarning : nil
        values.canTakeSnapshot = viewModel.capabilities.isAvailable(.takeSnapshot, on: instance)
        refreshNetwork()
        seedFileMonitor()
        refreshAttachmentSizes()
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
        return "\(markedMacOSVMCount) macOS virtual machines are set to start when Kernova opens, "
            + "but macOS runs at most two at once — the rest won't start."
    }

    /// Names the other VMs carrying this one's MAC address, `nil` when none
    /// does — shown wherever the MAC row is: an address is held while
    /// networking is off, but nothing shows it there to contradict.
    static func duplicateMACWarning(sharingWith names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "\(DataFormatters.quotedList(names)) also \(names.count == 1 ? "uses" : "use") "
            + "this MAC address. Virtual machines with the same MAC address can\u{2019}t run on "
            + "the same network at once, but they can on separate networks."
    }

    /// Names the other VMs holding this one's machine ID, `nil` when none do.
    static func sharedMachineIDNote(holders: [String]) -> String? {
        guard !holders.isEmpty else { return nil }
        return "Same machine ID as \(DataFormatters.quotedList(holders))."
    }

    private func refreshNetwork() {
        resolveNetworkModeLabel()
        values.ipAddress = viewModel.guestAddress(for: instance)
    }

    /// Names the VM's network again from `interfaces`, the host's bridgeable
    /// interfaces as an enumeration just found them — the Mode picker's, as
    /// it opens — so every surface names a bridged interface as the host
    /// offers it now.
    package func resolveNetworkModeLabel(enumerated interfaces: [BridgedInterface]) {
        interfaceEnumeration = InterfaceEnumeration(
            choice: NetworkModeChoice(instance.configuration), interfaces: interfaces)
        resolveNetworkModeLabel()
    }

    /// Names the VM's network again under its configuration, enumerating the
    /// host's interfaces only for a bridged interface the last enumeration
    /// was not taken under. Every other choice is named again each pass, so a
    /// renamed network re-titles.
    private func resolveNetworkModeLabel() {
        interfaceEnumeration = Self.interfaceEnumeration(
            for: instance, from: bridgedInterfaces, reusing: interfaceEnumeration)
        networkModeLabel = Self.networkModeLabel(of: instance, in: viewModel, interfaces: interfaceEnumeration)
    }

    /// The host's bridgeable interfaces, and the choice they were enumerated
    /// under.
    private struct InterfaceEnumeration {
        let choice: NetworkModeChoice
        let interfaces: [BridgedInterface]
    }

    /// The enumeration naming `instance`'s network: `last` while it was taken
    /// under the current choice or the choice names no interface, else a new
    /// one.
    private static func interfaceEnumeration(
        for instance: VMInstance, from provider: any BridgedInterfaceProviding, reusing last: InterfaceEnumeration?
    ) -> InterfaceEnumeration? {
        let choice = NetworkModeChoice(instance.configuration)
        guard choice.namesAHostInterface, last?.choice != choice else { return last }
        return InterfaceEnumeration(choice: choice, interfaces: provider.interfaces())
    }

    private static func networkModeLabel(
        of instance: VMInstance, in viewModel: VMLibraryViewModel, interfaces: InterfaceEnumeration?
    ) -> NetworkChoiceLabel {
        NetworkModeChoice.label(
            of: instance.configuration, entitlements: viewModel.entitlements,
            interfaces: { interfaces?.interfaces ?? [] }, networks: viewModel.networks.state)
    }

    /// Points ``fileMonitor`` at the current configuration's monitored
    /// attachment paths. Idempotent: the monitor probes only what changed.
    private func seedFileMonitor() {
        let refs = instance.configuration.externalFileReferences
            .filter(\.kind.isExistenceMonitored).bookmarksByPath
        Task { [fileMonitor] in await fileMonitor.setPaths(refs) }
    }

    /// Measures every storage disk's and removable medium's sizes off the main
    /// actor: on every pass while the guest is running and writing to its
    /// disks, and otherwise whenever the attachments, their files' presence, or
    /// the lifecycle phase moved (``attachmentMeasureKey``) — a stopped VM's
    /// sizes cannot move on their own.
    private func refreshAttachmentSizes() {
        var images = Dictionary(
            instance.effectiveStorageDisks.map { ($0.id, $0.imageReference) }, uniquingKeysWith: { first, _ in first })
        for item in instance.configuration.removableMedia ?? [] {
            images[item.id] = item.imageReference
        }
        // Only a detached attachment's entry is dropped at once; the rest stay
        // on screen until the new measurement replaces them.
        values.attachmentSizes = values.attachmentSizes.filter { images[$0.key] != nil }
        let presence = images.filter { !$0.value.isInternal }.mapValues { fileMonitor.exists($0.path) }
        let key = AttachmentMeasureKey(
            images: images, presence: presence, phaseCommits: instance.activity.phaseCommits)
        guard instance.status == .running || key != attachmentMeasureKey else { return }
        attachmentMeasureKey = key
        attachmentSizeTask?.cancel()
        attachmentSizeTask = nil
        attachmentMeasureGeneration += 1
        let generation = attachmentMeasureGeneration
        let bundle = instance.bundle
        attachmentSizeTask = Task { [weak self] in
            let sizes = await bundle.diskSizes(of: images)
            // A measurement issued after this one, or a re-bind to another VM,
            // owns what the rows state now.
            guard let self, self.attachmentMeasureGeneration == generation else { return }
            self.values.attachmentSizes = sizes
            self.onCategoryResolved?(.storage)
        }
    }

    /// Measures each snapshot's size off the main actor whenever the VM state
    /// they were measured in moved (``snapshotMeasureKey``), once the VM is
    /// settled — an operation's own writes are still landing until then.
    private func refreshSnapshotSizes() {
        let manifest = instance.snapshotManifest
        // Only what the manifest no longer lists is dropped at once: the rest
        // stay on screen until the new measurement replaces them, rather than
        // blanking every row for the length of the walk.
        let kept = Set(manifest.ordered.map(\.id))
        values.snapshotSizes = values.snapshotSizes.filter { kept.contains($0.key) }
        guard instance.phase.isSettled else { return }
        let key = SnapshotMeasureKey(manifest: manifest, phaseCommits: instance.activity.phaseCommits)
        guard key != snapshotMeasureKey else { return }
        snapshotMeasureKey = key
        snapshotSizeTask?.cancel()
        snapshotSizeTask = nil
        snapshotMeasureGeneration += 1
        guard !kept.isEmpty else { return }
        let generation = snapshotMeasureGeneration
        let issuedFor = instance
        let viewModel = self.viewModel
        snapshotSizeTask = Task { [weak self] in
            let sizes = await viewModel.snapshotSizes(for: issuedFor)
            // A measurement issued after this one, or a re-bind to another VM,
            // owns what the rows state now.
            guard let self, self.snapshotMeasureGeneration == generation else { return }
            self.values.snapshotSizes = sizes
            self.onCategoryResolved?(.snapshots)
        }
    }

    #if DEBUG
    /// The in-flight size read, so a test awaits it instead of polling the
    /// sizes it fills in.
    var snapshotSizeTaskForTesting: Task<Void, Never>? { snapshotSizeTask }

    /// The in-flight attachment size read, for event-driven test waits.
    var attachmentSizeTaskForTesting: Task<Void, Never>? { attachmentSizeTask }
    #endif
}
