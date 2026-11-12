import Foundation
import KernovaAgentCore
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The app-wide paste ceiling reaching a running guest's agent connections.
///
/// The ceiling lives in `AppPreferences`, so it produces no `VMConfiguration`
/// diff for `applyLivePolicy` to carry — without an explicit re-push a running
/// guest keeps enforcing the value it was handed at connect, and the two ends
/// silently disagree until the next reconnect.
@Suite("Clipboard paste ceiling policy push", .serialized, .caseScoped)
@MainActor
struct ClipboardPasteLimitPolicyPushTests {
    @Test("changing the ceiling re-pushes policy to a connected guest, without a reconnect")
    func changingTheCeilingRePushes() async throws {
        let preferences = makeTestPreferences()
        let viewModel = VMLibraryViewModel(
            storageService: MockVMStorageService(),
            diskImageService: MockDiskImageService(),
            machineFiles: VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles()),
            virtualizationHost: FakeVirtualizationHost(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            localImageInspector: MockLocalRestoreImageInspector(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            bridgedInterfaces: MockBridgedInterfaceProvider(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: makeTestDownloadsDirectory(),
            preferences: preferences,
            vmnetNetworks: VmnetNetworkService.scripted(),
            arpTable: ScriptedARPTable(),
            entitlements: .entitled,
            hostNotifications: .isolated(),
            hostPasteboard: FakePasteboard(), bundleProducts: .testing)

        let probe = AgentHubProbe()
        let instance = viewModel.library.registerFixture(
            name: "Ceiling VM", guestOS: .macOS, phase: .running(sessionID: UUID()),
            preferences: preferences, agentConnector: probe, mutate: { $0.clipboardSharingEnabled = true })
        instance.beginSessionContextForTesting()
        instance.attachAgentTransport(probe)
        try await probe.changed.wait { probe.isStarted }
        #expect(probe.connect())

        // The connect-time push carries whatever is stored now.
        let initial = try #require(probe.policies.first)
        #expect(ClipboardPolicyValue(initial)?.maxPasteBytes == UInt64(preferences.clipboardMaxPasteBytes))

        // The Settings pane's action, verbatim: write the preference, then ask
        // the library to carry it to every running guest.
        let raised = 16 * 1024 * 1024 * 1024
        preferences.clipboardMaxPasteBytes = raised
        viewModel.applyClipboardPasteLimitChange()

        let pushed = instance.agentHubPolicy(for: instance.configuration)
        #expect(ClipboardPolicyValue(pushed)?.maxPasteBytes == UInt64(raised))
        try await probe.changed.wait { probe.commands.contains(.setPolicy(pushed)) }
        #expect(instance.effectiveClipboardMaxPasteBytes == raised)
    }
}
