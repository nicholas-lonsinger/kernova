import AVFoundation
import AppKit
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI
@testable import KernovaVirtualization

/// The General panel's own behavior, drilled into through the shell.
@Suite("VM Settings General Panel Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct VMSettingsGeneralPanelTests {
    private let preferences = makeTestPreferences()

    private func makeViewModel() -> VMLibraryViewModel {
        makeSettingsViewModel(preferences: preferences)
    }

    // MARK: - Ephemeral Mode

    /// Builds a settings pane over a VM carrying `snapshotCount` snapshots of
    /// `kind`, the oldest of which is the Current one.
    private func makeEphemeralController(
        snapshotCount: Int, ephemeral: Bool, isReadOnly: Bool = false,
        kind: VMSnapshotKind = .warm
    ) -> (VMSettingsViewController, VMInstance) {
        makeEphemeralController(
            snapshots: (0..<snapshotCount).map { makeSnapshot(index: $0, kind: kind) },
            ephemeral: ephemeral, isReadOnly: isReadOnly)
    }

    /// One snapshot of the series the count-based helper builds: named for its
    /// index, and a minute newer than the one before it.
    private func makeSnapshot(
        index: Int, kind: VMSnapshotKind, name: String? = nil
    ) -> VMSnapshot {
        VMSnapshot(
            name: name ?? "Snapshot \(index)",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
            kind: kind, macAddress: nil)
    }

    /// Builds a settings pane over a VM carrying `snapshots`, the first of which
    /// is the Current one and, in the mode, the baseline.
    private func makeEphemeralController(
        snapshots: [VMSnapshot], ephemeral: Bool, isReadOnly: Bool = false,
        viewModel: VMLibraryViewModel? = nil
    ) -> (VMSettingsViewController, VMInstance) {
        let viewModel = viewModel ?? makeViewModel()
        let baseline = ephemeral ? snapshots.first : nil
        let instance = viewModel.library.registerFixture(
            guestOS: .linux,
            hostState: baseline.map { .ephemeral(baseline: $0.id) } ?? VMHostState())
        instance.seedSnapshotManifest(
            VMSnapshotManifest(
                snapshots: snapshots, currentID: snapshots.first?.id))
        let vc = makeSettingsPane(
            instance: instance, viewModel: viewModel, isReadOnly: isReadOnly)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.general)
        return (vc, instance)
    }

    @Test("Turning the mode on asks first, and confirmed defaults the baseline to the current snapshot")
    func ephemeralToggleDefaultsToCurrent() throws {
        let viewModel = makeViewModel()
        let (vc, instance) = makeEphemeralController(
            snapshots: (0..<2).map { makeSnapshot(index: $0, kind: .warm) }, ephemeral: false,
            viewModel: viewModel)
        let window = showTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let toggle = try #require(firstSwitch(action: "ephemeralModeToggled", in: vc.view))

        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)

        // The verb refused for want of consent, so nothing landed; the sheet
        // asks in the words that refusal carried.
        #expect(!instance.hostState.ephemeralModeEnabled)
        let current = try #require(instance.snapshotManifest.snapshots.first)
        let prompt = VMCommandCore.ephemeralBaselinePrompt(current, on: instance, turningOn: true)
        let sheet = try #require(window.attachedSheet)
        #expect(findLabel(withText: prompt.title, in: try #require(sheet.contentView)) != nil)

        // The confirmation's write.
        ConsentedSettingWrite(instance: instance, viewModel: viewModel, refresh: {}).write(
            VMConfigurationKeyRegistry.ephemeral.assigning(true), confirmingIn: nil,
            consent: Consent([.setEphemeralBaseline]))

        #expect(instance.hostState.ephemeralModeEnabled)
        #expect(
            instance.hostState.ephemeralBaselineSnapshotID
                == instance.snapshotManifest.currentID)
    }

    @Test("Choosing another snapshot asks first, and confirmed moves the baseline")
    func ephemeralBaselineSelectionWritesConfig() throws {
        let viewModel = makeViewModel()
        let (vc, instance) = makeEphemeralController(
            snapshots: (0..<3).map { makeSnapshot(index: $0, kind: .warm) }, ephemeral: true,
            viewModel: viewModel)
        let window = showTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        let popUp = try #require(firstPopUp(action: "ephemeralBaselineChanged", in: vc.view))
        // Rows render newest first, so the first item is not the Current one.
        let newest = try #require(popUp.itemArray[0].representedObject as? UUID)
        let pinned = instance.hostState.ephemeralBaselineSnapshotID

        popUp.select(popUp.itemArray[0])
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.hostState.ephemeralBaselineSnapshotID == pinned)
        #expect(window.attachedSheet != nil)

        // The confirmation's write.
        ConsentedSettingWrite(instance: instance, viewModel: viewModel, refresh: {}).write(
            VMConfigurationKeyRegistry.ephemeralBaseline.assigning(newest.uuidString),
            confirmingIn: nil, consent: Consent([.setEphemeralBaseline]))

        #expect(instance.hostState.ephemeralBaselineSnapshotID == newest)
        #expect(instance.hostState.ephemeralModeEnabled)
    }
}
