import AVFoundation
import Testing

@testable import Kernova

@Suite("VM Overview Resolver Tests", .serialized, .admissionGated)
@MainActor
struct VMOverviewResolverTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.vmoverviewresolver")

    private static let wiFi = BridgedInterface(identifier: "en0", localizedDisplayName: "Wi-Fi")

    private func makeInstance(_ mutate: (inout VMConfiguration) -> Void = { _ in }) -> VMInstance {
        var config = VMConfiguration(name: "Test VM", guestOS: .linux, bootMode: .efi)
        mutate(&config)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    /// `inLibrary` lists the VM the resolver is bound to, which is what lets the
    /// reads it issues — each addressing its VM by id — answer at all.
    ///
    /// Listed rather than registered: `wirePersistence` re-reads the snapshot
    /// manifest these tests seed by hand, and claims a network slot the address
    /// case asserts nothing takes.
    private func makeResolver(
        instance: VMInstance,
        viewModel: VMLibraryViewModel? = nil,
        inLibrary: Bool = false,
        entitled: Bool = true,
        vmnetNetworks: MockVmnetNetworkProvider = MockVmnetNetworkProvider(),
        interfaces: any BridgedInterfaceProviding = MockBridgedInterfaceProvider(),
        micPermission: AVAuthorizationStatus = .authorized
    ) -> VMOverviewResolver {
        let model =
            viewModel
            ?? makeSettingsViewModel(
                preferences: preferences, vmnetNetworks: vmnetNetworks, entitled: entitled)
        if inLibrary { model.library.instances.append(instance) }
        return VMOverviewResolver(
            instance: instance,
            viewModel: model,
            entitlements: EntitlementService(
                reader: MockEntitlementReader(granted: entitled ? ["com.apple.vm.networking"] : [])),
            bridgedInterfaces: interfaces,
            micPermissionStatus: { micPermission })
    }

    // MARK: - Mode titles

    @Test("Every mode names itself the way the picker titles its entry")
    func modeTitlesMatchThePicker() {
        #expect(NetworkModeChoice.shared.title(entitled: true, interfaces: []) == "Shared Network")
        #expect(NetworkModeChoice.none.title(entitled: true, interfaces: []) == "None")
        #expect(NetworkModeChoice.hostOnly.title(entitled: true, interfaces: []) == "Host Only")
        #expect(
            NetworkModeChoice.bridged(nil).title(entitled: true, interfaces: []) == "Automatic")
        #expect(
            NetworkModeChoice.bridged("en0").title(entitled: true, interfaces: [Self.wiFi])
                == "Wi-Fi (en0)")
    }

    @Test("A mode the signature doesn't authorize still names itself, marked unavailable")
    func unentitledModesNameThemselves() {
        #expect(
            NetworkModeChoice.hostOnly.title(entitled: false, interfaces: [])
                == "Host Only (unavailable)")
        #expect(
            NetworkModeChoice.bridged("en0").title(entitled: false, interfaces: [Self.wiFi])
                == "Bridged (unavailable)")
        // Entitled, but the host has stopped offering the interface.
        #expect(
            NetworkModeChoice.bridged("en5").title(entitled: true, interfaces: [Self.wiFi])
                == "en5 (unavailable)")
        // An interface the host names nothing else reads as its bare identifier.
        let bare = BridgedInterface(identifier: "bridge0", localizedDisplayName: "bridge0")
        #expect(
            NetworkModeChoice.bridged("bridge0").title(entitled: true, interfaces: [bare])
                == "bridge0")
    }

    @Test("Naming a bridged interface is the only title that takes an enumeration")
    func onlyABridgedInterfaceNeedsTheHostList() {
        #expect(NetworkModeChoice.bridged("en0").namesAHostInterface)
        #expect(!NetworkModeChoice.bridged(nil).namesAHostInterface)
        #expect(!NetworkModeChoice.shared.namesAHostInterface)
        #expect(!NetworkModeChoice.none.namesAHostInterface)
    }

    @Test("The mode title is named once per mode, not once per pass")
    func modeTitleIsNamedOncePerMode() {
        let interfaces = CountingBridgedInterfaceProvider(available: [Self.wiFi])
        let instance = makeInstance {
            $0.networkEnabled = true
            $0.networkMode = .bridged
            $0.bridgedInterfaceIdentifier = "en0"
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let resolver = makeResolver(instance: instance, interfaces: interfaces)

        resolver.refresh()
        resolver.refresh()
        resolver.refresh()

        #expect(resolver.resolved.networkModeTitle == "Wi-Fi (en0)")
        #expect(interfaces.enumerationCount == 1)
    }

    @Test("A mode that names no interface never enumerates the host's")
    func nonBridgedModesNeverEnumerate() {
        let interfaces = CountingBridgedInterfaceProvider(available: [Self.wiFi])
        let instance = makeInstance {
            $0.networkEnabled = true
            $0.networkMode = .shared
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let resolver = makeResolver(instance: instance, interfaces: interfaces)

        resolver.refresh()

        #expect(resolver.resolved.networkModeTitle == "Shared Network")
        #expect(interfaces.enumerationCount == 0)
    }

    // MARK: - Address

    @Test("The address is the registry's answer, and displaying it claims nothing")
    func addressComesFromTheRegistryWithoutClaimingASlot() {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedAddresses = ["aa:bb:cc:dd:ee:ff": "192.168.64.9"]
        let instance = makeInstance {
            $0.networkEnabled = true
            $0.networkMode = .shared
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let resolver = makeResolver(instance: instance, vmnetNetworks: vmnet)

        resolver.refresh()

        #expect(resolver.resolved.ipAddress == .reserved("192.168.64.9"))
        // The declaration path is the store's only writer: this instance is not
        // in the library, so showing it takes no slot and materializes nothing.
        #expect(vmnet.reservedMACs.isEmpty)
        #expect(vmnet.materializeCount == 0)
    }

    @Test("A slot on a network with no addressing yet reads as pending, and states nothing")
    func addressPendsUntilTheNetworkHasAddressing() {
        let vmnet = MockVmnetNetworkProvider()
        let instance = makeInstance {
            $0.networkEnabled = true
            $0.networkMode = .shared
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let resolver = makeResolver(instance: instance, vmnetNetworks: vmnet)

        resolver.refresh()

        #expect(resolver.resolved.ipAddress == .pending)
        #expect(resolver.resolved.ipAddress.displayText == nil)
    }

    @Test("Bridged hands addressing to the network; an unentitled build has none to state")
    func addressAbsentWhereNothingAssignsOne() {
        let bridged = makeInstance {
            $0.networkEnabled = true
            $0.networkMode = .bridged
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let bridgedResolver = makeResolver(instance: bridged)
        bridgedResolver.refresh()
        #expect(bridgedResolver.resolved.ipAddress == .externallyAssigned)
        #expect(bridgedResolver.resolved.ipAddress.displayText == "Assigned by your network")

        let unentitled = makeInstance {
            $0.networkEnabled = true
            $0.networkMode = .shared
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let unentitledResolver = makeResolver(instance: unentitled, entitled: false)
        unentitledResolver.refresh()
        #expect(unentitledResolver.resolved.ipAddress == .unavailable)

        let off = makeInstance { $0.networkEnabled = false }
        let offResolver = makeResolver(instance: off)
        offResolver.refresh()
        #expect(offResolver.resolved.ipAddress == .unavailable)
    }

    // MARK: - Forwarding

    @Test("Only an entitled Shared VM with a MAC counts forwarded rules")
    func forwardingCountAppliesWhereForwardingDoes() {
        let rules = [PortForwardingRule(transport: .tcp, hostPort: 8080, guestPort: 80)]
        func count(entitled: Bool, mode: VMNetworkMode, mac: String?) -> Int? {
            let instance = makeInstance {
                $0.networkEnabled = true
                $0.networkMode = mode
                $0.macAddress = mac
                $0.portForwardingRules = rules
            }
            let resolver = makeResolver(instance: instance, entitled: entitled)
            resolver.refresh()
            return resolver.resolved.portForwardingRuleCount
        }

        #expect(count(entitled: true, mode: .shared, mac: "aa:bb:cc:dd:ee:ff") == 1)
        #expect(count(entitled: false, mode: .shared, mac: "aa:bb:cc:dd:ee:ff") == nil)
        #expect(count(entitled: true, mode: .hostOnly, mac: "aa:bb:cc:dd:ee:ff") == nil)
        #expect(count(entitled: true, mode: .shared, mac: nil) == nil)
    }

    // MARK: - Warnings

    @Test("A duplicate MAC names the other VMs holding it")
    func duplicateMACWarningNamesTheOtherVMs() throws {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let instance = makeInstance {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let twin = makeInstance {
            $0.name = "Twin"
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        viewModel.instances = [instance, twin]
        let resolver = makeResolver(instance: instance, viewModel: viewModel)

        resolver.refresh()

        let warning = try #require(resolver.resolved.warnings[.network])
        #expect(warning.contains("Twin"))
        #expect(warning.contains("MAC address"))
    }

    @Test("A VM alone on its address raises no Network warning")
    func soleHolderOfAMACRaisesNothing() {
        let instance = makeInstance {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:ff"
        }
        let resolver = makeResolver(instance: instance)
        resolver.refresh()
        #expect(resolver.resolved.warnings[.network] == nil)
    }

    @Test("A refused microphone raises the System warning only while input is on")
    func micWarningFollowsPermissionAndInput() {
        let silent = makeInstance { $0.audioInputEnabled = false }
        let silentResolver = makeResolver(instance: silent, micPermission: .denied)
        silentResolver.refresh()
        #expect(silentResolver.resolved.micWarning == MicWarningState.none)
        #expect(silentResolver.resolved.warnings[.system] == nil)

        let listening = makeInstance { $0.audioInputEnabled = true }
        let deniedResolver = makeResolver(instance: listening, micPermission: .denied)
        deniedResolver.refresh()
        #expect(deniedResolver.resolved.micWarning == .denied)
        #expect(
            deniedResolver.resolved.warnings[.system]
                == VMOverviewResolver.micPermissionDeniedWarning)

        let promptResolver = makeResolver(instance: listening, micPermission: .notDetermined)
        promptResolver.refresh()
        #expect(promptResolver.resolved.micWarning == .willPrompt)
        // Only a refusal is worth a card's warning glyph.
        #expect(promptResolver.resolved.warnings[.system] == nil)
    }

    // MARK: - Async reads and rebinding

    @Test("The snapshots' footprint lands from an off-main read, keyed to its set")
    func snapshotFootprintFollowsItsSet() async throws {
        let instance = makeInstance()
        let snapshot = VMSnapshot(name: "Base")
        instance.snapshotManifest = VMSnapshotManifest(
            snapshots: [snapshot], currentID: snapshot.id)
        let resolver = makeResolver(instance: instance, inLibrary: true)

        resolver.refresh()
        #expect(resolver.resolved.snapshotTotalBytes == nil)
        await resolver.snapshotSizeTaskForTesting?.value
        #expect(resolver.resolved.snapshotTotalBytes != nil)
        #expect(resolver.resolved.snapshotSizes.keys.contains(snapshot.id))

        // A pass over the same set re-issues nothing.
        resolver.refresh()
        #expect(resolver.resolved.snapshotTotalBytes != nil)
    }

    @Test("A size already read survives the re-read the next snapshot triggers")
    func measuredSizesOutliveARereadOfTheSameVM() async throws {
        let instance = makeInstance()
        let first = VMSnapshot(name: "First")
        instance.snapshotManifest = VMSnapshotManifest(snapshots: [first], currentID: first.id)
        let resolver = makeResolver(instance: instance, inLibrary: true)
        resolver.refresh()
        await resolver.snapshotSizeTaskForTesting?.value
        let measured = try #require(resolver.resolved.snapshotSizes[first.id])

        // Capturing a second snapshot re-issues the walk, which takes seconds on
        // a real VM — the row already measured keeps its figure meanwhile.
        let second = VMSnapshot(name: "Second")
        instance.snapshotManifest = VMSnapshotManifest(
            snapshots: [first, second], currentID: second.id)
        resolver.refresh()

        #expect(resolver.resolved.snapshotSizes[first.id] == measured)
        // The set is only part-measured, so no total is claimed — the same
        // terms the panel's own readout falls back to the bare count on.
        #expect(resolver.resolved.snapshotTotalBytes == nil)

        await resolver.snapshotSizeTaskForTesting?.value
        #expect(resolver.resolved.snapshotSizes.count == 2)
        #expect(resolver.resolved.snapshotTotalBytes != nil)
    }

    @Test("Deleting a snapshot drops its size and leaves the rest measured")
    func deletingASnapshotDropsOnlyItsOwnSize() async throws {
        let instance = makeInstance()
        let first = VMSnapshot(name: "First")
        let second = VMSnapshot(name: "Second")
        instance.snapshotManifest = VMSnapshotManifest(
            snapshots: [first, second], currentID: second.id)
        let resolver = makeResolver(instance: instance, inLibrary: true)
        resolver.refresh()
        await resolver.snapshotSizeTaskForTesting?.value
        #expect(resolver.resolved.snapshotSizes.count == 2)

        instance.snapshotManifest = VMSnapshotManifest(snapshots: [first], currentID: first.id)
        resolver.refresh()

        #expect(resolver.resolved.snapshotSizes[second.id] == nil)
        #expect(resolver.resolved.snapshotSizes[first.id] != nil)
        // Everything left is measured, so the footprint stands without waiting
        // for the re-read.
        #expect(resolver.resolved.snapshotTotalBytes != nil)
    }

    @Test("Binding to another VM drops what described the outgoing one")
    func rebindingClearsTheOutgoingVMsValues() async {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let instance = makeInstance()
        let snapshot = VMSnapshot(name: "Base")
        instance.snapshotManifest = VMSnapshotManifest(
            snapshots: [snapshot], currentID: snapshot.id)
        let resolver = makeResolver(instance: instance, viewModel: viewModel, inLibrary: true)
        resolver.refresh()
        await resolver.snapshotSizeTaskForTesting?.value
        await resolver.bootDiskTaskForTesting?.value
        #expect(resolver.resolved.snapshotTotalBytes != nil)

        resolver.bind(instance: makeInstance(), viewModel: viewModel)

        // Nothing of the previous VM's survives to be stated beside the new
        // one's count.
        #expect(resolver.resolved.snapshotTotalBytes == nil)
        #expect(resolver.resolved.snapshotSizes.isEmpty)
        #expect(resolver.resolved.bootDiskBytes == nil)
        #expect(resolver.resolved.networkModeTitle == nil)
    }

    @Test("A resolved read reports the category whose card it moved")
    func resolvedReadsReportTheirCategory() async {
        let instance = makeInstance()
        let snapshot = VMSnapshot(name: "Base")
        instance.snapshotManifest = VMSnapshotManifest(
            snapshots: [snapshot], currentID: snapshot.id)
        let resolver = makeResolver(instance: instance, inLibrary: true)
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
