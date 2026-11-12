import AVFoundation
import KernovaCommandModel
import KernovaTestSupport
import Synchronization
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

@Suite("VM Overview Resolver Tests", .serialized, .caseScoped)
@MainActor
struct VMOverviewResolverTests {
    private let preferences = makeTestPreferences()

    private static let wiFi = BridgedInterface(identifier: "en0", localizedDisplayName: "Wi-Fi")

    /// A resolver whose reads — each addressing its VM by id — answer only
    /// when `instance` is one of `viewModel`'s library's own.
    private func makeResolver(
        instance: VMInstance,
        viewModel: VMLibraryViewModel? = nil,
        entitled: Bool = true,
        vmnetNetworks: VmnetNetworkService = .scripted(),
        interfaces: any BridgedInterfaceProviding = MockBridgedInterfaceProvider(),
        micPermission: AVAuthorizationStatus = .authorized
    ) -> VMOverviewResolver {
        let model =
            viewModel
            ?? makeSettingsViewModel(
                preferences: preferences, vmnetNetworks: vmnetNetworks, entitled: entitled)
        return VMOverviewResolver(
            instance: instance,
            viewModel: model,
            fileMonitor: AttachmentFileMonitor(probe: Self.everyFilePresent, hostNotifications: .isolated()),
            bridgedInterfaces: interfaces,
            micPermissionStatus: { micPermission })
    }

    /// Answers every attachment file present, so no fixture's made-up path
    /// moves the measure key under a test.
    private static let everyFilePresent: AttachmentFileMonitor.Probe = { added, _, _ in
        AttachmentFileMonitor.ProbeResult(
            existence: Dictionary(uniqueKeysWithValues: added.map { ($0, true) }), parentFDs: [:])
    }

    // MARK: - Mode titles

    @Test("NAT reads NAT on every display surface, and its raw values are nat")
    func natModeReadsNAT() {
        #expect(VMNetworkMode.nat.title == "NAT")
        #expect(VMNetworkMode.nat.rawValue == "nat")
        #expect(VmnetNetworkKind.nat.rawValue == "nat")
        #expect(NetworkKind.nat.rawValue == "nat")
        // Shortcuts reads a literal table; it names each kind as the app does.
        for kind in [VMNetworkKind.nat, .hostOnly] {
            #expect(
                String(localized: VMNetworkKind.caseDisplayRepresentations[kind]!.title)
                    == VmnetNetworkKind(kind.kind).mode.title)
        }
        #expect(VMNetworkKind.nat.rawValue == "nat")
        #expect(NetworksSettingsViewController.kindTitle(.nat) == "NAT")
    }

    @Test("The mode title is named once per mode, not once per pass")
    func modeTitleIsNamedOncePerMode() {
        let interfaces = CountingBridgedInterfaceProvider(available: [Self.wiFi])
        let instance = VMInstanceFixture.make {
            $0.networkEnabled = true
            $0.networkMode = .bridged
            $0.bridgedInterfaceIdentifier = "en0"
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let resolver = makeResolver(instance: instance, interfaces: interfaces)

        resolver.refresh()
        resolver.refresh()
        resolver.refresh()

        #expect(resolver.resolved.networkModeLabel?.text == "Bridged \u{2013} Wi-Fi (en0)")
        #expect(interfaces.enumerationCount == 1)
    }

    @Test("The stored label names the network the configuration holds after each re-resolve, for every reader")
    func storedLabelFollowsTheConfiguration() throws {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let instance = viewModel.library.registerFixture {
            $0.networkEnabled = true
            $0.networkMode = .nat
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let resolver = makeResolver(instance: instance, viewModel: viewModel)
        // Named from the moment it exists, before any pass.
        #expect(resolver.networkModeLabel.text == "NAT \u{2013} Common")

        guard
            case .applied = viewModel.setConfiguration(
                [VMConfigurationKeyRegistry.networkMode.assigning(VMNetworkMode.hostOnly.rawValue)], on: instance)
        else {
            Issue.record("The mode write did not land")
            return
        }
        resolver.refresh()

        #expect(resolver.networkModeLabel.text == "Host Only \u{2013} Common")
        #expect(resolver.resolved.networkModeLabel?.text == "Host Only \u{2013} Common")
        let card = VMOverviewSummary.rows(for: .network, instance: instance, resolved: resolver.resolved)
        #expect(card.first?.label == "Host Only \u{2013} Common")
    }

    @Test("The picker's enumeration names a bridged interface back on the host for every reader")
    func pickerEnumerationRenamesTheCurrentInterface() {
        let interfaces = MockBridgedInterfaceProvider(available: [])
        let instance = VMInstanceFixture.make {
            $0.networkEnabled = true
            $0.networkMode = .bridged
            $0.bridgedInterfaceIdentifier = "en0"
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let resolver = makeResolver(instance: instance, interfaces: interfaces)
        resolver.refresh()
        #expect(resolver.resolved.networkModeLabel?.text == "Bridged \u{2013} en0 (unavailable)")

        interfaces.setAvailable([Self.wiFi])
        resolver.resolveNetworkModeLabel(enumerated: interfaces.interfaces())
        resolver.refresh()

        #expect(resolver.resolved.networkModeLabel?.text == "Bridged \u{2013} Wi-Fi (en0)")
    }

    @Test("A mode that names no interface never enumerates the host's")
    func nonBridgedModesNeverEnumerate() {
        let interfaces = CountingBridgedInterfaceProvider(available: [Self.wiFi])
        let instance = VMInstanceFixture.make {
            $0.networkEnabled = true
            $0.networkMode = .nat
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let resolver = makeResolver(instance: instance, interfaces: interfaces)

        resolver.refresh()

        #expect(resolver.resolved.networkModeLabel?.text == "NAT \u{2013} Common")
        #expect(interfaces.enumerationCount == 0)
    }

    // MARK: - Address

    /// A NAT VM on `aa:bb:cc:dd:ee:ff`, running unless `phase` says otherwise.
    private func sharedInstance(phase: VMLifecyclePhase = .running(sessionID: UUID())) -> VMInstance {
        VMInstanceFixture.make(phase: phase, mutate: Self.shareNetwork)
    }

    /// Networking on, NAT, on `aa:bb:cc:dd:ee:ff`.
    private static func shareNetwork(_ config: inout VMConfiguration) {
        config.networkEnabled = true
        config.networkMode = .nat
        config.macAddress = "aa:bb:cc:dd:ee:ff"
    }

    @Test("A running VM not yet seen says so; a stopped one states nothing")
    func addressNotSeenWhileRunningAbsentWhileStopped() {
        let runningResolver = makeResolver(instance: sharedInstance())
        runningResolver.refresh()
        #expect(runningResolver.resolved.ipAddress == .notObserved)
        #expect(runningResolver.resolved.ipAddress.displayText == "Not seen on the network")

        let stoppedResolver = makeResolver(instance: sharedInstance(phase: .stopped))
        stoppedResolver.refresh()
        #expect(stoppedResolver.resolved.ipAddress == .unavailable)
        #expect(stoppedResolver.resolved.ipAddress.displayText == nil)
    }

    // MARK: - Warnings

    @Test("A VM sharing its machine identity and MAC address is warned like any other holder")
    func duplicateMACWarningIgnoresTheMachineIdentity() throws {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let identity = Data([2, 7, 1, 8])
        let instance = viewModel.library.admitFixture {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
            $0.genericMachineIdentifierData = identity
        }
        viewModel.library.admitFixture {
            $0.name = "Twin"
            $0.networkEnabled = true
            $0.macAddress = "AA:BB:CC:DD:EE:FF"
            $0.genericMachineIdentifierData = identity
        }
        let resolver = makeResolver(instance: instance, viewModel: viewModel)

        resolver.refresh()

        #expect(
            resolver.resolved.warnings[.network]
                == "\u{201C}Twin\u{201D} also uses this MAC address. Virtual machines with "
                + "the same MAC address can\u{2019}t run on the same network at once, but they can "
                + "on separate networks.")
    }

    @Test("A Bridged VM on its own NAT network is warned beside a shared MAC address")
    func bridgedFallbackJoinsTheDuplicateMACWarning() throws {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let instance = viewModel.library.admitFixture {
            $0.networkEnabled = true
            $0.networkMode = .bridged
            $0.bridgedInterfaceIdentifier = "en1"
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        viewModel.library.admitFixture {
            $0.name = "Twin"
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let resolver = makeResolver(instance: instance, viewModel: viewModel)
        resolver.refresh()
        let duplicateMAC = try #require(resolver.resolved.warnings[.network])

        instance.beginSessionContextForTesting().networkAttachment = .attached(.bridgedFallback)
        resolver.refresh()

        let notice = try #require(instance.networkAttachmentNotice)
        let warning = try #require(resolver.resolved.warnings[.network])
        #expect(warning.hasPrefix(notice))
        #expect(warning.hasSuffix(duplicateMAC))
    }

    @Test("The shared machine ID note names one holder, or several in a list")
    func sharedMachineIDNoteNamesTheHolders() {
        #expect(VMOverviewResolver.sharedMachineIDNote(holders: []) == nil)
        #expect(
            VMOverviewResolver.sharedMachineIDNote(holders: ["Work"])
                == "Same machine ID as \u{201C}Work\u{201D}.")
        #expect(
            VMOverviewResolver.sharedMachineIDNote(holders: ["Work", "Home"])
                == "Same machine ID as \u{201C}Work\u{201D} and \u{201C}Home\u{201D}.")
    }

    @Test("A refused microphone raises the System warning only while input is on")
    func micWarningFollowsPermissionAndInput() {
        let silent = VMInstanceFixture.make { $0.audioInputEnabled = false }
        let silentResolver = makeResolver(instance: silent, micPermission: .denied)
        silentResolver.refresh()
        #expect(silentResolver.resolved.micWarning == MicWarningState.none)
        #expect(silentResolver.resolved.warnings[.system] == nil)

        let listening = VMInstanceFixture.make { $0.audioInputEnabled = true }
        let deniedResolver = makeResolver(instance: listening, micPermission: .denied)
        deniedResolver.refresh()
        #expect(deniedResolver.resolved.micWarning == .denied)
        #expect(
            deniedResolver.resolved.warnings[.system]
                == VMOverviewResolver.micPermissionDeniedWarning)

        let promptResolver = makeResolver(instance: listening, micPermission: .notDetermined)
        promptResolver.refresh()
        #expect(promptResolver.resolved.micWarning == MicWarningState.none)
        // Only a refusal is worth a card's warning glyph.
        #expect(promptResolver.resolved.warnings[.system] == nil)
    }

    // MARK: - Async reads and rebinding

    /// A resolver over a VM holding one snapshot whose size `files` reports.
    private func makeMeasuredResolver(
        _ files: MockVMBundleMachineFiles
    ) -> (VMOverviewResolver, VMInstance, VMSnapshot) {
        let viewModel = makeSettingsViewModel(preferences: preferences, machineFiles: files)
        let instance = viewModel.library.admitFixture()
        let snapshot = VMSnapshot(name: "Base", macAddress: nil)
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot], currentID: snapshot.id))
        return (makeResolver(instance: instance, viewModel: viewModel), instance, snapshot)
    }

    @Test("Showing the sizes again measures them again, with nothing else changed")
    func remeasuringReadsAgain() async throws {
        let files = MockVMBundleMachineFiles()
        let (resolver, _, snapshot) = makeMeasuredResolver(files)
        resolver.refresh()
        await resolver.snapshotSizeTaskForTesting?.value
        resolver.refresh()
        #expect(files.sizeReads == 1)

        let grown = SnapshotSize(bytes: 72_000_000_000, privateBytes: 9_000_000_000)
        files.setSize(grown, for: snapshot.id)
        resolver.remeasureSnapshotSizes()
        resolver.refresh()
        await resolver.snapshotSizeTaskForTesting?.value

        #expect(files.sizeReads == 2)
        #expect(resolver.resolved.snapshotSizes[snapshot.id] == grown)
    }

    @Test("A size already read survives the re-read the next snapshot triggers")
    func measuredSizesOutliveARereadOfTheSameVM() async throws {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let instance = viewModel.library.admitFixture()
        let first = VMSnapshot(name: "First", macAddress: nil)
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [first], currentID: first.id))
        let resolver = makeResolver(instance: instance, viewModel: viewModel)
        resolver.refresh()
        await resolver.snapshotSizeTaskForTesting?.value
        let measured = try #require(resolver.resolved.snapshotSizes[first.id])

        // Capturing a second snapshot re-issues the walk, which takes seconds on
        // a real VM — the row already measured keeps its figure meanwhile.
        let second = VMSnapshot(name: "Second", macAddress: nil)
        instance.seedSnapshotManifest(
            VMSnapshotManifest(
                snapshots: [first, second], currentID: second.id))
        resolver.refresh()

        #expect(resolver.resolved.snapshotSizes[first.id] == measured)
        #expect(resolver.resolved.snapshotSizes[second.id] == nil)

        await resolver.snapshotSizeTaskForTesting?.value
        #expect(resolver.resolved.snapshotSizes.count == 2)
    }

    // MARK: - Attachment sizes

    /// An installer image ahead of the main disk, and one removable medium.
    private static let installer = StorageDisk(path: "/tmp/ubuntu-26.04.1-desktop-arm64.iso")
    private static let mainDisk = StorageDisk(path: "Disk.asif", label: "Main Disk", isInternal: true)
    private static let stick = RemovableMediaItem(path: "/tmp/stick.img")

    private static let installerSizes = VMBundleLayout.DiskSizes(
        onDiskBytes: 4_150_000_000, capacityBytes: 4_150_000_000)
    private static let mainDiskSizes = VMBundleLayout.DiskSizes(
        onDiskBytes: 9_000_000_000, capacityBytes: 100_000_000_000)
    private static let stickSizes = VMBundleLayout.DiskSizes(onDiskBytes: 1_000_000, capacityBytes: 8_000_000_000)

    /// A resolver over a VM attaching ``installer`` and ``mainDisk`` with
    /// ``stick`` beside them, whose sizes `files` reports.
    private func makeAttachmentResolver(
        _ files: MockVMBundleMachineFiles, phase: VMLifecyclePhase = .stopped
    ) -> (VMOverviewResolver, VMInstance, VMLibraryViewModel) {
        files.setDiskSizes(Self.installerSizes, for: Self.installer.id)
        files.setDiskSizes(Self.mainDiskSizes, for: Self.mainDisk.id)
        files.setDiskSizes(Self.stickSizes, for: Self.stick.id)
        let viewModel = makeSettingsViewModel(preferences: preferences, machineFiles: files)
        let instance = viewModel.library.registerFixture(phase: phase) {
            $0.storageDisks = [Self.installer, Self.mainDisk]
            $0.removableMedia = [Self.stick]
        }
        return (makeResolver(instance: instance, viewModel: viewModel), instance, viewModel)
    }

    @Test("A stopped VM is measured once per attachment set and phase; a running one on every pass")
    func onlyARunningVMIsRemeasuredEveryPass() async {
        let files = MockVMBundleMachineFiles()
        let (resolver, instance, _) = makeAttachmentResolver(files)
        resolver.refresh()
        await resolver.attachmentSizeTaskForTesting?.value
        resolver.refresh()
        #expect(files.diskSizeReads == 1)

        // The phase committing measures again, and while the guest runs and
        // writes, so does every pass after it.
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        resolver.refresh()
        await resolver.attachmentSizeTaskForTesting?.value
        #expect(files.diskSizeReads == 2)
        resolver.refresh()
        await resolver.attachmentSizeTaskForTesting?.value
        #expect(files.diskSizeReads == 3)
    }

    @Test("Detaching a medium drops its sizes at once and leaves the disks' on screen")
    func detachingDropsOnlyItsOwnSizes() async {
        let files = MockVMBundleMachineFiles()
        let (resolver, instance, viewModel) = makeAttachmentResolver(files)
        resolver.refresh()
        await resolver.attachmentSizeTaskForTesting?.value
        let hold = files.holdNextDiskSizeRead()

        viewModel.ejectRemovableMedia(Self.stick.id, from: instance)
        resolver.refresh()

        // Before the measurement the detach issued has landed.
        #expect(resolver.resolved.attachmentSizes[Self.stick.id] == nil)
        #expect(resolver.resolved.attachmentSizes[Self.installer.id] == Self.installerSizes)
        #expect(resolver.resolved.attachmentSizes[Self.mainDisk.id] == Self.mainDiskSizes)
        hold.signal()
        await resolver.attachmentSizeTaskForTesting?.value
    }

    @Test("A measurement landing after a newer one never replaces it")
    func aStaleAttachmentMeasurementCannotOverwriteANewerOne() async throws {
        let files = MockVMBundleMachineFiles()
        let (resolver, _, _) = makeAttachmentResolver(files)
        let hold = files.holdNextDiskSizeRead()
        resolver.refresh()
        let staleRead = resolver.attachmentSizeTaskForTesting
        try await files.diskSizeReadEntered.wait { files.diskSizeReads == 1 }

        let fresh = VMBundleLayout.DiskSizes(onDiskBytes: 12_000_000_000, capacityBytes: 100_000_000_000)
        files.setDiskSizes(fresh, for: Self.mainDisk.id)
        resolver.remeasureAttachmentSizes()
        resolver.refresh()
        await resolver.attachmentSizeTaskForTesting?.value
        #expect(resolver.resolved.attachmentSizes[Self.mainDisk.id] == fresh)

        hold.signal()
        await staleRead?.value
        #expect(resolver.resolved.attachmentSizes[Self.mainDisk.id] == fresh)
    }

    @Test("Binding to another VM drops what described the outgoing one")
    func rebindingClearsTheOutgoingVMsValues() async {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let instance = viewModel.library.admitFixture()
        let snapshot = VMSnapshot(name: "Base", macAddress: nil)
        instance.seedSnapshotManifest(
            VMSnapshotManifest(
                snapshots: [snapshot], currentID: snapshot.id))
        let resolver = makeResolver(instance: instance, viewModel: viewModel)
        resolver.refresh()
        await resolver.snapshotSizeTaskForTesting?.value
        await resolver.attachmentSizeTaskForTesting?.value
        #expect(!resolver.resolved.snapshotSizes.isEmpty)
        #expect(!resolver.resolved.attachmentSizes.isEmpty)

        resolver.bind(instance: VMInstanceFixture.make { $0.networkEnabled = false }, viewModel: viewModel)

        // Nothing of the previous VM's survives to be stated on the new one's
        // rows, and the network is the new one's.
        #expect(resolver.resolved.snapshotSizes.isEmpty)
        #expect(resolver.resolved.attachmentSizes.isEmpty)
        #expect(resolver.resolved.networkModeLabel == .noNetwork)
    }

    @Test("A resolved read reports the category whose card it moved")
    func resolvedReadsReportTheirCategory() async {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let instance = viewModel.library.admitFixture()
        let snapshot = VMSnapshot(name: "Base", macAddress: nil)
        instance.seedSnapshotManifest(
            VMSnapshotManifest(
                snapshots: [snapshot], currentID: snapshot.id))
        let resolver = makeResolver(instance: instance, viewModel: viewModel)
        var reported: [VMSettingsCategory] = []
        resolver.onCategoryResolved = { reported.append($0) }

        resolver.refresh()
        await resolver.snapshotSizeTaskForTesting?.value
        await resolver.attachmentSizeTaskForTesting?.value

        #expect(reported.contains(.snapshots))
        #expect(reported.contains(.storage))
        #expect(!reported.contains(.general))
    }
}

/// Counts how often the host's bridgeable interfaces are enumerated, which is
/// the cost the resolver is built to pay once per mode rather than per pass.
private final class CountingBridgedInterfaceProvider: BridgedInterfaceProviding {
    let available: [BridgedInterface]
    private let enumerations = Mutex(0)

    var enumerationCount: Int { enumerations.withLock { $0 } }

    init(available: [BridgedInterface]) {
        self.available = available
    }

    func interfaces() -> [BridgedInterface] {
        enumerations.withLock { $0 += 1 }
        return available
    }

    func primaryInterfaceIdentifier() -> String? { nil }
}
