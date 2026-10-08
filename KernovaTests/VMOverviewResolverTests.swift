import AVFoundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

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
        vmnetNetworks: MockVmnetNetworkProvider = MockVmnetNetworkProvider(),
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
            bridgedInterfaces: interfaces,
            micPermissionStatus: { micPermission })
    }

    // MARK: - Mode titles

    @Test("Every choice names its mode's group and its entry, joined by an en dash")
    func modeTitlesNameGroupAndEntry() {
        #expect(
            NetworkModeChoice.nat.title(attachable: true, interfaces: [], networks: .listed([]))
                == "NAT \u{2013} Common")
        #expect(NetworkModeChoice.none.title(attachable: true, interfaces: [], networks: .listed([])) == "None")
        #expect(
            NetworkModeChoice.hostOnly.title(attachable: true, interfaces: [], networks: .listed([]))
                == "Host Only \u{2013} Common")
        #expect(
            NetworkModeChoice.bridged(nil).title(attachable: true, interfaces: [], networks: .listed([]))
                == "Bridged \u{2013} Automatic")
        #expect(
            NetworkModeChoice.bridged("en0").label(attachable: true, interfaces: [Self.wiFi], networks: .listed([]))
                == NetworkChoiceLabel(mode: .bridged, entry: "Wi-Fi (en0)"))
        #expect(
            NetworkModeChoice.bridged("en0").title(attachable: true, interfaces: [Self.wiFi], networks: .listed([]))
                == "Bridged \u{2013} Wi-Fi (en0)")
        #expect(NetworkModeChoice.none.label(attachable: true, interfaces: [], networks: .listed([])).group == nil)
    }

    @Test("A network of a mode names itself: isolated, or by its name, under its mode")
    func networkTitlesNameTheNetwork() {
        let lab = VMNamedNetwork(id: UUID(), name: "Lab", kind: .nat)
        #expect(
            NetworkModeChoice.vmnet(.hostOnly, .isolated).label(attachable: true, interfaces: [], networks: .listed([]))
                == NetworkChoiceLabel(mode: .hostOnly, entry: "Isolated"))
        #expect(
            NetworkModeChoice.vmnet(.hostOnly, .isolated).title(
                attachable: true, interfaces: [], networks: .listed([])) == "Host Only \u{2013} Isolated")
        #expect(
            NetworkModeChoice.vmnet(.nat, .network(lab.id)).label(
                attachable: true, interfaces: [], networks: .listed([lab]))
                == NetworkChoiceLabel(mode: .nat, entry: "Lab"))
        #expect(
            NetworkModeChoice.vmnet(.nat, .network(lab.id)).title(
                attachable: true, interfaces: [], networks: .listed([lab])) == "NAT \u{2013} Lab")
        #expect(
            NetworkModeChoice.vmnet(.nat, .network(lab.id)).title(
                attachable: false, interfaces: [], networks: .listed([lab])) == "NAT \u{2013} Lab (unavailable)")
        #expect(
            NetworkModeChoice.vmnet(.hostOnly, .isolated).title(
                attachable: false, interfaces: [], networks: .listed([]))
                == "Host Only \u{2013} Isolated (unavailable)")
        // Unlisted, or listed only in the other mode: no surface here can
        // choose it, so it never reads as merely unavailable.
        #expect(
            NetworkModeChoice.vmnet(.nat, .network(UUID())).title(
                attachable: false, interfaces: [], networks: .listed([lab]))
                == "NAT \u{2013} Network Not in This Library")
        #expect(
            NetworkModeChoice.vmnet(.hostOnly, .network(lab.id)).title(
                attachable: true, interfaces: [], networks: .listed([lab]))
                == "Host Only \u{2013} Network Not in This Library")
    }

    @Test("While the network list can't be read, a named network reads so under its mode, and no other title moves")
    func networkTitlesWhileTheListIsUnreadable() {
        let unreadable = VMNetworkDirectory.State.unreadable(
            UnreadableConfigFile(
                location: .networkList(URL(fileURLWithPath: "/tmp/Networks.json")), owner: .networkList,
                problems: [ConfigProblem(path: nil, issue: .notJSON(detail: "x"))]))
        #expect(
            NetworkModeChoice.vmnet(.nat, .network(UUID())).label(
                attachable: true, interfaces: [], networks: unreadable)
                == NetworkChoiceLabel(mode: .nat, entry: "Network List Can\u{2019}t Be Read"))
        #expect(
            NetworkModeChoice.vmnet(.nat, .network(UUID())).title(
                attachable: true, interfaces: [], networks: unreadable)
                == "NAT \u{2013} Network List Can\u{2019}t Be Read")
        #expect(
            NetworkModeChoice.vmnet(.hostOnly, .isolated).title(
                attachable: true, interfaces: [], networks: unreadable) == "Host Only \u{2013} Isolated")
    }

    @Test("A mode the signature doesn't authorize still names itself, marked unavailable")
    func unentitledModesNameThemselves() {
        #expect(
            NetworkModeChoice.hostOnly.title(attachable: false, interfaces: [], networks: .listed([]))
                == "Host Only \u{2013} Common (unavailable)")
        #expect(
            NetworkModeChoice.bridged("en0").title(attachable: false, interfaces: [Self.wiFi], networks: .listed([]))
                == "Bridged \u{2013} Wi-Fi (en0) (unavailable)")
        #expect(
            NetworkModeChoice.bridged(nil).title(attachable: false, interfaces: [], networks: .listed([]))
                == "Bridged \u{2013} Automatic (unavailable)")
        // Entitled, but the host has stopped offering the interface.
        #expect(
            NetworkModeChoice.bridged("en5").title(attachable: true, interfaces: [Self.wiFi], networks: .listed([]))
                == "Bridged \u{2013} en5 (unavailable)")
        // An interface the host names nothing else reads as its bare identifier.
        let bare = BridgedInterface(identifier: "bridge0", localizedDisplayName: "bridge0")
        #expect(
            NetworkModeChoice.bridged("bridge0").title(attachable: true, interfaces: [bare], networks: .listed([]))
                == "Bridged \u{2013} bridge0")
    }

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

    @Test("Naming a bridged interface is the only title that takes an enumeration")
    func onlyABridgedInterfaceNeedsTheHostList() {
        #expect(NetworkModeChoice.bridged("en0").namesAHostInterface)
        #expect(!NetworkModeChoice.bridged(nil).namesAHostInterface)
        #expect(!NetworkModeChoice.nat.namesAHostInterface)
        #expect(!NetworkModeChoice.none.namesAHostInterface)
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

    @Test("The address is the observer's answer for a running VM, and displaying it materializes nothing")
    func addressComesFromTheObserver() async {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedSubnets = [.common(.nat): .scripted("192.168.64.0")]
        let model = makeSettingsViewModel(
            preferences: preferences, vmnetNetworks: vmnet,
            arpTable: ScriptedARPTable([
                .scripted("192.168.64.9", mac: "aa:bb:cc:dd:ee:ff", expiry: ARPEntry.freshExpiry)
            ]))
        let instance = model.library.admitFixture(
            phase: .running(sessionID: UUID()), mutate: Self.shareNetwork)
        let resolver = makeResolver(instance: instance, viewModel: model)
        await model.library.guestAddresses.readForTesting()

        resolver.refresh()

        #expect(resolver.resolved.ipAddress == .observed("192.168.64.9"))
        #expect(vmnet.materializeCount == 0)
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

    @Test("Bridged hands addressing to the network; an unentitled build has none to state")
    func addressAbsentWhereNothingAssignsOne() {
        let bridged = VMInstanceFixture.make {
            $0.networkEnabled = true
            $0.networkMode = .bridged
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let bridgedResolver = makeResolver(instance: bridged)
        bridgedResolver.refresh()
        #expect(bridgedResolver.resolved.ipAddress == .externallyAssigned)
        #expect(bridgedResolver.resolved.ipAddress.displayText == "Assigned by your network")

        let unentitledResolver = makeResolver(instance: sharedInstance(), entitled: false)
        unentitledResolver.refresh()
        #expect(unentitledResolver.resolved.ipAddress == .unavailable)

        let off = VMInstanceFixture.make { $0.networkEnabled = false }
        let offResolver = makeResolver(instance: off)
        offResolver.refresh()
        #expect(offResolver.resolved.ipAddress == .unavailable)
    }

    // MARK: - Warnings

    @Test("A duplicate MAC names the other VMs holding it")
    func duplicateMACWarningNamesTheOtherVMs() throws {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let instance = viewModel.library.admitFixture {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        viewModel.library.admitFixture {
            $0.name = "Twin"
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let resolver = makeResolver(instance: instance, viewModel: viewModel)

        resolver.refresh()

        let warning = try #require(resolver.resolved.warnings[.network])
        #expect(warning.contains("Twin"))
        #expect(warning.contains("MAC address"))
    }

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

    @Test("A VM sharing its machine ID gets the note, whatever the MAC addresses")
    func sharedMachineIDIsANote() {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let identity = Data([2, 7, 1, 8])
        let instance = viewModel.library.admitFixture {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:01"
            $0.genericMachineIdentifierData = identity
        }
        viewModel.library.admitFixture {
            $0.name = "Twin"
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:02"
            $0.genericMachineIdentifierData = identity
        }
        let resolver = makeResolver(instance: instance, viewModel: viewModel)

        resolver.refresh()

        #expect(resolver.resolved.sharedMachineIDNote == "Same machine ID as \u{201C}Twin\u{201D}.")
        #expect(resolver.resolved.warnings[.general] == nil)
    }

    @Test("A VM alone on its address raises no Network warning")
    func soleHolderOfAMACRaisesNothing() {
        let instance = VMInstanceFixture.make {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let resolver = makeResolver(instance: instance)
        resolver.refresh()
        #expect(resolver.resolved.warnings[.network] == nil)
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

    @Test("The snapshots' sizes land from an off-main read, measured once per state")
    func snapshotSizesFollowTheirSet() async throws {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let instance = viewModel.library.admitFixture()
        let snapshot = VMSnapshot(name: "Base", macAddress: nil)
        instance.seedSnapshotManifest(
            VMSnapshotManifest(
                snapshots: [snapshot], currentID: snapshot.id))
        let resolver = makeResolver(instance: instance, viewModel: viewModel)

        resolver.refresh()
        #expect(resolver.resolved.snapshotSizes.isEmpty)
        await resolver.snapshotSizeTaskForTesting?.value
        #expect(resolver.resolved.snapshotSizes.keys.contains(snapshot.id))

        // A pass over the same set re-issues nothing.
        resolver.refresh()
        #expect(resolver.resolved.snapshotSizes.keys.contains(snapshot.id))
    }

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

    @Test("A lifecycle change that keeps the same snapshots measures them again")
    func aLifecycleChangeRemeasuresTheSameSnapshots() async throws {
        let files = MockVMBundleMachineFiles()
        let (resolver, instance, snapshot) = makeMeasuredResolver(files)
        let before = SnapshotSize(bytes: 72_000_000_000, privateBytes: 8_000_000_000)
        files.setSize(before, for: snapshot.id)
        var repainted: [VMSettingsCategory] = []
        resolver.onCategoryResolved = { repainted.append($0) }
        resolver.refresh()
        await resolver.snapshotSizeTaskForTesting?.value
        #expect(resolver.resolved.snapshotSizes[snapshot.id] == before)

        // A revert clones the snapshot back over the live disks, so its private
        // bytes fall away while the manifest stays exactly as it was — and the
        // VM rests where it started.
        let after = SnapshotSize(bytes: 72_000_000_000, privateBytes: 4_096)
        files.setSize(after, for: snapshot.id)
        instance.activity.placeForTesting(
            .operating(
                .bringUp(.reverting(snapshotID: snapshot.id, resumesAfter: false)), from: .stopped))
        resolver.refresh()
        instance.activity.placeForTesting(.stopped)
        resolver.refresh()
        await resolver.snapshotSizeTaskForTesting?.value

        #expect(resolver.resolved.snapshotSizes[snapshot.id] == after)
        #expect(repainted.filter { $0 == .snapshots }.count == 2)
        #expect(files.sizeReads == 2)
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

    @Test("A measurement landing after a newer one never replaces it")
    func aStaleMeasurementCannotOverwriteANewerOne() async throws {
        let files = MockVMBundleMachineFiles()
        let (resolver, _, snapshot) = makeMeasuredResolver(files)
        let stale = SnapshotSize(bytes: 72_000_000_000, privateBytes: 8_000_000_000)
        files.setSize(stale, for: snapshot.id)
        let hold = files.holdNextSizeRead()
        resolver.refresh()
        let staleRead = resolver.snapshotSizeTaskForTesting
        try await files.sizeReadEntered.wait { files.sizeReads == 1 }

        let fresh = SnapshotSize(bytes: 72_000_000_000, privateBytes: 4_096)
        files.setSize(fresh, for: snapshot.id)
        resolver.remeasureSnapshotSizes()
        resolver.refresh()
        await resolver.snapshotSizeTaskForTesting?.value
        #expect(resolver.resolved.snapshotSizes[snapshot.id] == fresh)

        hold.signal()
        await staleRead?.value
        #expect(resolver.resolved.snapshotSizes[snapshot.id] == fresh)
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

    @Test("Deleting a snapshot drops its size and leaves the rest measured")
    func deletingASnapshotDropsOnlyItsOwnSize() async throws {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let instance = viewModel.library.admitFixture()
        let first = VMSnapshot(name: "First", macAddress: nil)
        let second = VMSnapshot(name: "Second", macAddress: nil)
        instance.seedSnapshotManifest(
            VMSnapshotManifest(
                snapshots: [first, second], currentID: second.id))
        let resolver = makeResolver(instance: instance, viewModel: viewModel)
        resolver.refresh()
        await resolver.snapshotSizeTaskForTesting?.value
        #expect(resolver.resolved.snapshotSizes.count == 2)

        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [first], currentID: first.id))
        resolver.refresh()

        #expect(resolver.resolved.snapshotSizes[second.id] == nil)
        #expect(resolver.resolved.snapshotSizes[first.id] != nil)
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
        await resolver.bootDiskTaskForTesting?.value
        #expect(!resolver.resolved.snapshotSizes.isEmpty)

        resolver.bind(instance: VMInstanceFixture.make(), viewModel: viewModel)

        // Nothing of the previous VM's survives to be stated on the new one's
        // rows.
        #expect(resolver.resolved.snapshotSizes.isEmpty)
        #expect(resolver.resolved.bootDiskBytes == nil)
        #expect(resolver.resolved.networkModeLabel == nil)
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
        await resolver.bootDiskTaskForTesting?.value

        #expect(reported.contains(.snapshots))
        #expect(reported.contains(.storage))
        #expect(!reported.contains(.general))
    }
}

/// Counts how often the host's bridgeable interfaces are enumerated, which is
/// the cost the resolver is built to pay once per mode rather than per pass.
private final class CountingBridgedInterfaceProvider:
    BridgedInterfaceProviding, @unchecked Sendable
{
    let available: [BridgedInterface]
    private(set) var enumerationCount = 0

    init(available: [BridgedInterface]) {
        self.available = available
    }

    func interfaces() -> [BridgedInterface] {
        enumerationCount += 1
        return available
    }

    func primaryInterfaceIdentifier() -> String? { nil }
}
