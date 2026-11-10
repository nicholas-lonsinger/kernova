import AVFoundation
import AppKit
import KernovaCommandModel
import KernovaTestSupport
import Testing
import Virtualization

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

@Suite("VMSettingsViewController Tests", .serialized, .caseScoped)
@MainActor
struct VMSettingsViewControllerTests {
    private let preferences = makeTestPreferences()

    private func makeController(
        guestOS: VMGuestOS, isReadOnly: Bool, category: VMSettingsCategory? = nil
    ) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
        makeSettingsController(
            guestOS: guestOS, isReadOnly: isReadOnly, category: category,
            preferences: preferences)
    }

    // MARK: - Config write-back

    @Test("Toggling Clipboard Sharing writes back to the configuration")
    func clipboardToggleWritesConfig() {
        let (vc, instance, _) = makeController(
            guestOS: .linux, isReadOnly: false, category: .sharing)
        #expect(instance.configuration.clipboardSharingEnabled == false)

        guard let clipboard = firstSwitch(action: "clipboardToggled", in: vc.view) else {
            Issue.record("Expected a clipboard switch")
            return
        }
        clipboard.state = .on
        clipboard.sendAction(clipboard.action, to: clipboard.target)

        #expect(instance.configuration.clipboardSharingEnabled == true)
    }

    // MARK: - Ephemeral Mode through the card

    /// The card's switch and the panel's share one dispatcher, so the card
    /// takes the baseline the same way: the sheet opens and nothing is
    /// written until its capture lands.
    @Test("The overview card's Ephemeral switch takes the baseline on a VM with no snapshot")
    func ephemeralEnableFromTheCardOpensTheBaselineSheet() throws {
        let (vc, instance, viewModel) = makeController(guestOS: .linux, isReadOnly: false)
        let presenter = MockVMLibraryPresenting()
        viewModel.presenter = presenter
        let storage = try #require(viewModel.storageService as? MockVMStorageService)
        let hostStateOnDisk = storage.hostStates[instance.bundleURL]
        let card = try #require(vc.overviewCardForTesting(.general))
        let toggle = try #require(
            firstSubview(NSSwitch.self, in: card) {
                $0.identifier?.rawValue == VMOverviewToggle.ephemeralMode.rawValue
            })
        #expect(instance.snapshotManifest.isEmpty)
        #expect(toggle.isEnabled)

        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)

        #expect(presenter.takeSnapshotSheetInstances.map(\.id) == [instance.id])
        #expect(presenter.takeSnapshotSheetPurposes == [.ephemeralBaseline])
        #expect(presenter.errors.isEmpty)
        #expect(!instance.hostState.ephemeralModeEnabled)
        #expect(storage.hostStates[instance.bundleURL] == hostStateOnDisk)
        #expect(toggle.state == .off)
    }

    // MARK: - Ephemeral Mode settings banner

    private static let bannerText =
        EphemeralModeCopy.settingsBannerLead + EphemeralModeCopy.settingsBannerMessage

    /// A pane over a stopped macOS VM in Ephemeral Mode whose baseline is
    /// "Clean install" — or, with `listsBaseline` false, names one the
    /// manifest no longer lists.
    private func makeEphemeralController(
        listsBaseline: Bool = true
    ) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let baseline = VMSnapshot(name: "Clean install", macAddress: nil)
        let instance = viewModel.library.registerFixture(
            guestOS: .macOS, hostState: .ephemeral(baseline: baseline.id),
            snapshots: VMSnapshotManifest(snapshots: listsBaseline ? [baseline] : []))
        let vc = makeSettingsPane(instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        return (vc, instance, viewModel)
    }

    private func showsBanner(_ vc: VMSettingsViewController) -> Bool {
        visibleLabel(Self.bannerText, in: vc.view)
    }

    @Test("Don't show again hides the banner at once and turns its reminder off")
    func dontShowAgainHidesTheBannerLive() async throws {
        let (vc, _, viewModel) = makeEphemeralController()
        vc.showCategory(.system)
        #expect(showsBanner(vc))

        let link = try #require(
            allSubviews(NSButton.self, in: vc.view) {
                $0.title == EphemeralModeCopy.settingsBannerDismissTitle
            }.first)
        #expect(NSApp.sendAction(try #require(link.action), to: link.target, from: link))

        #expect(viewModel.ephemeralSettingsBannerDismissed)
        try await waitUntil { !self.showsBanner(vc) }

        viewModel.ephemeralSettingsBannerDismissed = false
        try await waitUntil { self.showsBanner(vc) }
    }

    @Test("Sharing's banner info names the rows a revert keeps")
    func sharingBannerInfoNamesKeptRows() throws {
        let (vc, _, _) = makeEphemeralController()
        vc.showCategory(.sharing)

        let info = try #require(infoButton(about: EphemeralModeCopy.settingsBannerLead, in: vc.view))
        #expect(info.paragraphs.first?.text.contains("\u{201C}Clean install\u{201D}") == true)
        #expect(info.paragraphs.last == .body("Show install reminder stays as you set it."))

        vc.showCategory(.network)
        let networkInfo = try #require(
            infoButton(about: EphemeralModeCopy.settingsBannerLead, in: vc.view))
        #expect(networkInfo.paragraphs.count == 1)
    }

    // MARK: - App activation

    /// Carries a microphone status the test moves between activations, which is
    /// what makes the re-read `appDidBecomeActive()` performs observable.
    @MainActor
    private final class MicStatus {
        var value: AVAuthorizationStatus
        init(_ value: AVAuthorizationStatus) { self.value = value }
    }

    @Test("Activation refreshes the pane only through its view model's host notifications")
    func activationArrivesOnlyThroughTheViewModelsNotifications() {
        let notifications = HostNotifications.isolated()
        // Stands in for every other library's notifications.
        let other = HostNotifications.isolated()
        let mic = MicStatus(.authorized)
        let viewModel = makeSettingsViewModel(preferences: preferences, hostNotifications: notifications)
        let instance = makeSettingsInstance(guestOS: .linux) { $0.audioInputEnabled = true }
        let vc = makeSettingsPane(
            instance: instance, viewModel: viewModel, isReadOnly: false,
            micPermissionStatus: { mic.value })
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        #expect(vc.resolvedForTesting.micWarning == .none)

        // Permission revoked in System Settings while Kernova was away — a
        // change only an activation re-reads.
        mic.value = .denied

        other.appDidBecomeActive.post()
        #expect(vc.resolvedForTesting.micWarning == .none)

        notifications.appDidBecomeActive.post()
        #expect(vc.resolvedForTesting.micWarning == .denied)
    }
}
