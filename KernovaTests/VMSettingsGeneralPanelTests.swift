import AVFoundation
import AppKit
import KernovaTestSupport
import Testing
import Virtualization

@testable import Kernova

/// The General panel's own behavior, drilled into through the shell.
@Suite("VM Settings General Panel Tests", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct VMSettingsGeneralPanelTests {
    private let preferences = makeTestPreferences()

    private func makeViewModel() -> VMLibraryViewModel {
        makeSettingsViewModel(preferences: preferences)
    }

    private func makeController(
        guestOS: VMGuestOS, isReadOnly: Bool, category: VMSettingsCategory? = .general
    ) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
        makeSettingsController(
            guestOS: guestOS, isReadOnly: isReadOnly, category: category,
            preferences: preferences)
    }

    // MARK: - Rename session across a rebind

    @Test("A read-only flip on the same VM leaves an open rename alone")
    func readOnlyFlipDoesNotCommitAnOpenRename() throws {
        let (vc, instance, viewModel) = makeController(
            guestOS: .linux, isReadOnly: false, category: .general)
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        viewModel.renameVMInDetail(instance)
        vc.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: false)
        // The panel's only editable field is the name box the rename opened.
        let panel = try #require(vc.panelForTesting(.general))
        let field = try #require(findEditableField(in: panel))
        field.currentEditor()?.string = "Half-typed"
        field.stringValue = "Half-typed"

        // The VM starting flips the pane read-only, which re-enters
        // `reconfigure` with the same instance — not an outgoing one, so the
        // half-typed name must not commit.
        vc.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: true)

        #expect(instance.name == "Test VM")
        #expect(viewModel.activeRename == .detail(instance.id))
    }

    /// The handoff the two rename surfaces share: the sidebar taking the rename
    /// supersedes this one, and the text typed here has to reach the model
    /// rather than being dropped with the box.
    @Test("A superseded detail rename still commits what was typed into it")
    func supersededDetailRenameCommitsItsText() throws {
        let (vc, instance, viewModel) = makeController(
            guestOS: .linux, isReadOnly: false, category: .general)
        let window = makeTestWindow(styleMask: [.titled])
        window.contentView = vc.view
        viewModel.renameVMInDetail(instance)
        vc.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: false)
        let panel = try #require(vc.panelForTesting(.general))
        let field = try #require(findEditableField(in: panel))
        field.currentEditor()?.string = "Typed in detail"
        field.stringValue = "Typed in detail"

        // The sidebar takes the rename over, which is what the pane sees.
        viewModel.renameVMInSidebar(instance)
        vc.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: false)

        #expect(instance.name == "Typed in detail")
        // The marker belongs to the sidebar now, and the detail commit left it.
        #expect(viewModel.activeRename == .sidebar(instance.id))
    }

    /// The row used to be a borderless button, which grayed its own title; a
    /// plain label doesn't, so the pane has to gray it.
    @Test("The name reads as disabled while the VM can't be renamed")
    func nameGraysWhenRenameIsUnavailable() throws {
        let viewModel = makeViewModel()
        // A revert refuses the rename it would assign back over.
        let instance = makeSettingsInstance(
            guestOS: .linux,
            phase: .operating(
                .bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)), from: .stopped))
        let vc = makeSettingsPane(
            instance: instance, viewModel: viewModel, isReadOnly: true)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.general)

        #expect(!viewModel.capabilities.isAvailable(.rename, on: instance))
        let panel = try #require(vc.panelForTesting(.general))
        let name = try #require(
            firstSubview(InlineEditableLabel.self, in: panel) { $0.stringValue == instance.name })
        #expect(name.textColor == .disabledControlTextColor)
    }

    // MARK: - General card OS rows

    private func makeOSRowsController(
        guestOS: VMGuestOS,
        installedImage: InstalledImage? = nil,
        lastSeenGuestOSVersion: String? = nil
    ) -> (VMSettingsViewController, VMInstance, VMLibraryViewModel) {
        let viewModel = makeViewModel()
        let instance = makeSettingsInstance(guestOS: guestOS) {
            $0.installedImage = installedImage
            $0.lastSeenGuestOSVersion = lastSeenGuestOSVersion
        }
        let vc = makeSettingsPane(
            instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.general)
        return (vc, instance, viewModel)
    }

    @Test("A macOS VM that knows both shows the install record and the agent report side by side")
    func osRowsBothKnown() {
        let (vc, _, _) = makeOSRowsController(
            guestOS: .macOS,
            installedImage: .macOSRestoreImage(version: "26.5.2", build: "25F84"),
            lastSeenGuestOSVersion: "Version 26.6 (Build 25G12)")

        #expect(visibleLabel("Installed version", in: vc.view))
        #expect(visibleLabel("macOS 26.5.2 (25F84)", in: vc.view))
        #expect(visibleLabel("OS version", in: vc.view))
        #expect(visibleLabel("26.6", in: vc.view))
    }

    @Test("A macOS VM with no agent shows only what the install recorded")
    func osRowsInstallRecordOnly() {
        let (vc, _, _) = makeOSRowsController(
            guestOS: .macOS,
            installedImage: .macOSRestoreImage(version: "26.5.2", build: "25F84"))

        #expect(visibleLabel("Installed version", in: vc.view))
        #expect(!visibleLabel("OS version", in: vc.view))
    }

    @Test("A macOS VM Kernova did not install shows only what the agent reports")
    func osRowsAgentReportOnly() {
        let (vc, _, _) = makeOSRowsController(
            guestOS: .macOS, lastSeenGuestOSVersion: "26.6")

        #expect(!visibleLabel("Installed version", in: vc.view))
        #expect(visibleLabel("OS version", in: vc.view))
    }

    @Test("A macOS VM that knows neither shows neither row")
    func osRowsNeitherKnown() {
        let (vc, _, _) = makeOSRowsController(guestOS: .macOS)

        #expect(!visibleLabel("Installed version", in: vc.view))
        #expect(!visibleLabel("OS version", in: vc.view))
    }

    @Test("A Linux VM names the attached media and never an OS Version row")
    func osRowsLinuxCatalogImage() {
        let (vc, _, _) = makeOSRowsController(
            guestOS: .linux,
            installedImage: .linuxCatalogImage(
                distribution: "Ubuntu Desktop", version: "26.04 LTS", digest: nil))

        #expect(visibleLabel("Installer image", in: vc.view))
        #expect(visibleLabel("Ubuntu Desktop 26.04 LTS", in: vc.view))
        // Booting that ISO is not installing from it — the guest's own
        // installer can write another distribution, or nothing at all — so the
        // row must never claim the install happened.
        #expect(!containsLabel("Installed version", in: vc.view))
        // Linux guests have no Kernova agent, so the row is never even built.
        #expect(!containsLabel("OS version", in: vc.view))
    }

    @Test("A Linux VM with no install record shows no OS rows at all")
    func osRowsLinuxWithoutRecord() {
        let (vc, _, _) = makeOSRowsController(guestOS: .linux)

        #expect(!visibleLabel("Installer image", in: vc.view))
        #expect(!containsLabel("OS version", in: vc.view))
    }

    // MARK: - Installer image digest

    private static let sha256 =
        "0123456789abcdef" + String(repeating: "5", count: 32) + "fedcba9876543210"
    private static let checksumListURL = URL(
        string: "https://cdimage.ubuntu.com/releases/26.04/SHA256SUMS")!
    private static let isoURL = URL(string: "https://mirror.example/alpine-3.22-aarch64.iso")!

    private static func matched(_ source: DigestSource, filename: String) -> InstallerImageDigest? {
        ExpectedDigest(sha256: sha256, source: source).match(sha256, filename: filename)
    }

    /// The General panel's label reading exactly `text`, visible or not.
    private func panelLabel(_ text: String, in vc: VMSettingsViewController) -> NSTextField? {
        vc.panelForTesting(.general).flatMap { findLabel(withText: text, in: $0) }
    }

    @Test("A catalog image checked against its checksum list shows the digest and where it matched")
    func digestRowsForChecksumList() throws {
        let digest = try #require(
            Self.matched(.checksumList(Self.checksumListURL), filename: "ubuntu-26.04-desktop-arm64.iso"))
        let (vc, _, _) = makeOSRowsController(
            guestOS: .linux,
            installedImage: .linuxCatalogImage(
                distribution: "Ubuntu Desktop", version: "26.04 LTS", digest: digest))

        #expect(panelLabel("Ubuntu Desktop 26.04 LTS", in: vc)?.toolTip == "ubuntu-26.04-desktop-arm64.iso")
        #expect(visibleLabel("SHA-256", in: vc.view))
        let value = try #require(panelLabel("01234567\u{2026}76543210", in: vc))
        #expect(isVisible(value, within: vc.view))
        #expect(value.toolTip == Self.sha256)
        #expect(value.font?.isFixedPitch == true)
        let copy = try #require(
            vc.panelForTesting(.general).flatMap { firstSubview(CopyValueButton.self, in: $0) })
        #expect(copy.value == Self.sha256)
        #expect(!copy.isHidden)
        #expect(visibleLabel("Verification", in: vc.view))
        let verification = try #require(
            panelLabel("Matched the checksum list on cdimage.ubuntu.com", in: vc))
        #expect(isVisible(verification, within: vc.view))
        #expect(verification.toolTip == Self.checksumListURL.absoluteString)
    }

    @Test("A URL image checked against an entered checksum says so, and names its URL")
    func digestRowsForEnteredChecksum() throws {
        let digest = try #require(
            Self.matched(.enteredByUser, filename: "alpine-3.22-aarch64.iso"))
        let (vc, _, _) = makeOSRowsController(
            guestOS: .linux, installedImage: .linuxURLImage(url: Self.isoURL, digest: digest))

        #expect(visibleLabel("Installer image", in: vc.view))
        let image = try #require(panelLabel("alpine-3.22-aarch64.iso", in: vc))
        #expect(isVisible(image, within: vc.view))
        #expect(image.toolTip == Self.isoURL.absoluteString)
        #expect(visibleLabel("01234567\u{2026}76543210", in: vc.view))
        let verification = try #require(panelLabel("Matched the checksum you entered", in: vc))
        #expect(isVisible(verification, within: vc.view))
        #expect(verification.toolTip == nil)
    }

    @Test("A URL image compared with nothing states it was not verified")
    func digestRowsForUncheckedImage() throws {
        let (vc, _, _) = makeOSRowsController(
            guestOS: .linux,
            installedImage: .linuxURLImage(
                url: Self.isoURL,
                digest: .unchecked(filename: "alpine-3.22-aarch64.iso", sha256: Self.sha256)))

        #expect(visibleLabel("01234567\u{2026}76543210", in: vc.view))
        let verification = try #require(panelLabel("Not verified", in: vc))
        #expect(isVisible(verification, within: vc.view))
        #expect(
            verification.toolTip
                == "Computed from the downloaded file. It wasn't compared with any checksum.")
    }

    @Test("A record with no digest shows neither digest row")
    func noDigestRowsWithoutADigest() {
        let preDigest = makeOSRowsController(
            guestOS: .linux,
            installedImage: .linuxCatalogImage(
                distribution: "Ubuntu Desktop", version: "26.04 LTS", digest: nil)
        ).0
        #expect(visibleLabel("Installer image", in: preDigest.view))
        #expect(!visibleLabel("SHA-256", in: preDigest.view))
        #expect(!visibleLabel("Verification", in: preDigest.view))
        #expect(separatesEveryRow(generalCardLayout(in: preDigest)))

        let macOS = makeOSRowsController(
            guestOS: .macOS, installedImage: .macOSRestoreImage(version: "26.5.2", build: "25F84")
        ).0
        #expect(visibleLabel("Installed version", in: macOS.view))
        #expect(!visibleLabel("SHA-256", in: macOS.view))
        #expect(!visibleLabel("Verification", in: macOS.view))
    }

    @Test("Setup completing while the panel is open reveals the digest rows")
    func digestRowsAppearOnRefresh() throws {
        let (vc, instance, viewModel) = makeOSRowsController(guestOS: .linux)
        #expect(!visibleLabel("SHA-256", in: vc.view))

        let digest = try #require(
            Self.matched(.checksumList(Self.checksumListURL), filename: "ubuntu-26.04-desktop-arm64.iso"))
        // Only an operation holding the VM may write the record, as setup does.
        try withOperationNow(on: instance) { context in
            try viewModel.library.updateConfiguration(context.permit) {
                $0.installedImage = .linuxCatalogImage(
                    distribution: "Ubuntu Desktop", version: "26.04 LTS", digest: digest)
            }.get()
        }
        vc.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: false)

        #expect(visibleLabel("Ubuntu Desktop 26.04 LTS", in: vc.view))
        #expect(visibleLabel("01234567\u{2026}76543210", in: vc.view))
        #expect(visibleLabel("Matched the checksum list on cdimage.ubuntu.com", in: vc.view))
        let copy = try #require(
            vc.panelForTesting(.general).flatMap { firstSubview(CopyValueButton.self, in: $0) })
        #expect(copy.value == Self.sha256)
        #expect(separatesEveryRow(generalCardLayout(in: vc)))
    }

    /// The General card's visible run of rows and hairlines, `true` for a
    /// hairline — collapsible rows expanded, hidden views dropped.
    ///
    /// Scoped to the General panel: the overview's General card states some of
    /// the same rows and would match first.
    private func generalCardLayout(in vc: VMSettingsViewController) -> [Bool] {
        // The card's content stack is the one holding separators directly, which
        // no section or form stack does.
        guard let panel = vc.panelForTesting(.general) else {
            Issue.record("Expected a General panel")
            return []
        }
        guard
            let content = firstSubview(
                NSStackView.self, in: panel,
                where: { stack in
                    stack.arrangedSubviews.contains { $0 is GroupedFormCardSeparator }
                        && findLabel(withText: "Boot mode", in: stack) != nil
                })
        else {
            Issue.record("Expected a General card content stack")
            return []
        }
        return content.arrangedSubviews.filter { !$0.isHidden }.flatMap { view -> [Bool] in
            guard let collapsible = view as? GroupedFormCollapsibleRow else {
                return [view is GroupedFormCardSeparator]
            }
            return collapsible.arrangedSubviews.filter { !$0.isHidden }.map { $0 is GroupedFormCardSeparator }
        }
    }

    /// Whether a card's rows and hairlines strictly alternate, starting and
    /// ending on a row — the shape a hidden row must not disturb.
    private func separatesEveryRow(_ layout: [Bool]) -> Bool {
        layout.first == false && layout.last == false
            && zip(layout, layout.dropFirst()).allSatisfy { $0 != $1 }
    }

    @Test("Hidden OS rows take their separators with them")
    func osRowsLeaveNoStrandedSeparator() {
        // Every combination, since each leaves a different run of rows behind.
        let noRows = makeOSRowsController(guestOS: .macOS).0
        #expect(separatesEveryRow(generalCardLayout(in: noRows)))

        let installOnly = makeOSRowsController(
            guestOS: .macOS, installedImage: .macOSRestoreImage(version: "26.5.2", build: "25F84")
        ).0
        #expect(separatesEveryRow(generalCardLayout(in: installOnly)))

        let agentOnly = makeOSRowsController(guestOS: .macOS, lastSeenGuestOSVersion: "26.6").0
        #expect(separatesEveryRow(generalCardLayout(in: agentOnly)))

        let bothRows = makeOSRowsController(
            guestOS: .macOS, installedImage: .macOSRestoreImage(version: "26.5.2", build: "25F84"),
            lastSeenGuestOSVersion: "26.6"
        ).0
        #expect(separatesEveryRow(generalCardLayout(in: bothRows)))
        // Both OS rows really are in the run the check passed on.
        #expect(generalCardLayout(in: bothRows).count == generalCardLayout(in: noRows).count + 4)
    }

    @Test("A first agent report reveals the OS Version row without rebuilding the form")
    func osVersionRowAppearsOnFirstReport() {
        let (vc, instance, viewModel) = makeOSRowsController(guestOS: .macOS)
        #expect(!visibleLabel("OS version", in: vc.view))

        viewModel.library.editConfiguration(of: instance, as: .observations) { $0.lastSeenGuestOSVersion = "26.6" }
        vc.reconfigure(instance: instance, viewModel: viewModel, isReadOnly: false)

        #expect(visibleLabel("OS version", in: vc.view))
        #expect(visibleLabel("26.6", in: vc.view))
    }

    // MARK: - Launch auto-start

    @Test("The Startup toggle reflects the configuration")
    func autoStartSwitchReflectsConfiguration() {
        let viewModel = makeViewModel()
        let instance = makeSettingsInstance(
            guestOS: .linux, hostState: VMHostState(startsAutomaticallyOnLaunch: true))
        let vc = makeSettingsPane(
            instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.general)

        #expect(firstSwitch(action: "autoStartToggled", in: vc.view)?.state == .on)
    }

    @Test("Toggling the Startup switch writes back to the configuration")
    func autoStartToggleWritesConfig() {
        let (vc, instance, _) = makeController(guestOS: .linux, isReadOnly: false)
        #expect(instance.hostState.startsAutomaticallyOnLaunch == false)

        guard let autoStart = firstSwitch(action: "autoStartToggled", in: vc.view) else {
            Issue.record("Expected a Startup switch")
            return
        }
        autoStart.state = .on
        autoStart.sendAction(autoStart.action, to: autoStart.target)

        #expect(instance.hostState.startsAutomaticallyOnLaunch == true)
    }

    /// The flag is consumed once at app launch and reaches no
    /// `VZVirtualMachineConfiguration`, so it must stay editable while the VM
    /// runs — unlike every control the read-only banner locks.
    @Test("The Startup toggle stays editable while the VM is running")
    func autoStartSwitchStaysEnabledWhenReadOnly() {
        let (vc, _, _) = makeController(guestOS: .linux, isReadOnly: true)
        #expect(firstSwitch(action: "autoStartToggled", in: vc.view)?.isEnabled == true)
    }

    @Test("The start order is the auto-start row's info, not a caption")
    func startupRowInfoStatesTheStartOrder() {
        let order = "Virtual machines start in the order they appear in the sidebar."
        #expect(VMSettingsGeneralPanelViewController.autoStartInfo.contains(.body(order)))

        let (vc, _, _) = makeController(guestOS: .linux, isReadOnly: false, category: .general)
        #expect(infoButton(about: "Start when Kernova opens", in: vc.view) != nil)
        #expect(findLabel(withText: order, in: vc.view) == nil)
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

    @Test("A VM with no snapshot offers the mode by taking its baseline")
    func ephemeralToggleOffersTheBaselineCapture() {
        let (vc, _) = makeEphemeralController(snapshotCount: 0, ephemeral: false)
        let toggle = firstSwitch(action: "ephemeralModeToggled", in: vc.view)

        #expect(toggle?.state == .off)
        #expect(toggle?.isEnabled == true)
        #expect(toggle?.alphaValue == 1)
        #expect(visibleLabel(EphemeralModeCopy.noSnapshotsCaption(capturesBaseline: true), in: vc.view))
    }

    @Test("One snapshot is enough to offer the mode")
    func ephemeralToggleEnabledWithASnapshot() {
        let (vc, _) = makeEphemeralController(snapshotCount: 1, ephemeral: false)

        let toggle = firstSwitch(action: "ephemeralModeToggled", in: vc.view)
        #expect(toggle?.isEnabled == true)
        #expect(toggle?.alphaValue == 1)
        for capturesBaseline in [false, true] {
            #expect(
                !visibleLabel(
                    EphemeralModeCopy.noSnapshotsCaption(capturesBaseline: capturesBaseline),
                    in: vc.view))
        }
    }

    /// The baseline capture follows Take Snapshot's own availability, so a VM
    /// that can't be snapshotted has a dimmed switch rather than one opening a
    /// sheet that can't confirm.
    @Test("With Take Snapshot unavailable and no snapshot, the toggle is dimmed")
    func ephemeralToggleDimsWhenTheCaptureIsUnavailable() throws {
        let viewModel = makeViewModel()
        let (vc, instance) = makeEphemeralController(
            snapshots: [], ephemeral: false, viewModel: viewModel)
        instance.activity.placeForTesting(.initialBoot)
        try #require(!viewModel.capabilities.isAvailable(.takeSnapshot, on: instance))
        vc.viewDidAppear()

        let toggle = firstSwitch(action: "ephemeralModeToggled", in: vc.view)
        #expect(toggle?.isEnabled == false)
        #expect(toggle?.alphaValue ?? 1 < 1)
        #expect(visibleLabel(EphemeralModeCopy.noSnapshotsCaption(capturesBaseline: false), in: vc.view))
    }

    /// A VM already in the mode can always be taken back out, so the switch
    /// stays live even once its manifest can no longer offer a baseline.
    @Test("A VM already in the mode keeps a live toggle with no snapshots")
    func ephemeralToggleStaysLiveWhenAlreadyOn() {
        let (vc, instance) = makeEphemeralController(snapshotCount: 1, ephemeral: true)
        instance.seedSnapshotManifest(VMSnapshotManifest())
        // Re-runs `apply()` over the mutated manifest.
        vc.viewDidAppear()

        let toggle = firstSwitch(action: "ephemeralModeToggled", in: vc.view)
        #expect(toggle?.isEnabled == true)
        #expect(toggle?.alphaValue == 1)
    }

    /// The mode turns on only once the capture lands, so the switch reads off
    /// while the sheet is up and nothing is written.
    @Test("Turning the mode on with no snapshot opens the baseline sheet and writes nothing")
    func ephemeralEnableWithoutSnapshotsOpensTheSheet() throws {
        let presenter = MockVMLibraryPresenting()
        let viewModel = makeViewModel()
        viewModel.presenter = presenter
        let storage = try #require(viewModel.storageService as? MockVMStorageService)
        let (vc, instance) = makeEphemeralController(
            snapshots: [], ephemeral: false, viewModel: viewModel)
        let hostStateOnDisk = storage.hostStates[instance.bundleURL]
        let toggle = try #require(firstSwitch(action: "ephemeralModeToggled", in: vc.view))

        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)

        #expect(presenter.takeSnapshotSheetInstances.map(\.id) == [instance.id])
        #expect(presenter.takeSnapshotSheetPurposes == [.ephemeralBaseline])
        #expect(presenter.errors.isEmpty)
        #expect(!instance.hostState.ephemeralModeEnabled)
        #expect(storage.hostStates[instance.bundleURL] == hostStateOnDisk)
        #expect(toggle.state == .off)
    }

    @Test("The Ephemeral offer and the no-snapshot caption are the catalog's answer")
    func ephemeralOfferIsTheCatalogsAnswer() throws {
        let key = VMConfigurationKeyRegistry.ephemeral
        for hasSnapshots in [false, true] {
            for ephemeral in [false, true] {
                // A VM can only have entered the mode with a snapshot; one with
                // none has since lost its manifest.
                let viewModel = makeViewModel()
                let (vc, instance) = makeEphemeralController(
                    snapshots: (0..<(hasSnapshots || ephemeral ? 2 : 0)).map {
                        makeSnapshot(index: $0, kind: .warm)
                    },
                    ephemeral: ephemeral, viewModel: viewModel)
                if !hasSnapshots && ephemeral {
                    instance.seedSnapshotManifest(VMSnapshotManifest())
                    vc.viewDidAppear()
                }
                let label = "snapshots=\(hasSnapshots) ephemeral=\(ephemeral)"
                let toggle = try #require(firstSwitch(action: "ephemeralModeToggled", in: vc.view))
                let enable = viewModel.capabilities.ephemeralModeEnable(on: instance)

                #expect(
                    toggle.isEnabled
                        == (ephemeral
                            ? key.accepts("false", for: instance, entitlements: .entitled)
                            : viewModel.capabilities.isEphemeralModeEnableAvailable(on: instance)),
                    "\(label)")
                #expect(
                    visibleLabel(
                        EphemeralModeCopy.noSnapshotsCaption(
                            capturesBaseline: enable == .capturingBaseline),
                        in: vc.view) == !hasSnapshots, "\(label)")
            }
        }
    }

    @Test("Turning the mode on defaults the baseline to the current snapshot")
    func ephemeralToggleDefaultsToCurrent() {
        let (vc, instance) = makeEphemeralController(snapshotCount: 2, ephemeral: false)
        guard let toggle = firstSwitch(action: "ephemeralModeToggled", in: vc.view) else {
            Issue.record("Expected an Ephemeral Mode switch")
            return
        }

        toggle.state = .on
        toggle.sendAction(toggle.action, to: toggle.target)

        #expect(instance.hostState.ephemeralModeEnabled)
        #expect(
            instance.hostState.ephemeralBaselineSnapshotID
                == instance.snapshotManifest.currentID)
    }

    @Test("Turning the mode off clears the baseline")
    func ephemeralToggleOffClearsTheBaseline() {
        let (vc, instance) = makeEphemeralController(snapshotCount: 2, ephemeral: true)
        guard let toggle = firstSwitch(action: "ephemeralModeToggled", in: vc.view) else {
            Issue.record("Expected an Ephemeral Mode switch")
            return
        }

        toggle.state = .off
        toggle.sendAction(toggle.action, to: toggle.target)

        #expect(!instance.hostState.ephemeralModeEnabled)
        #expect(instance.hostState.ephemeralBaselineSnapshotID == nil)
    }

    @Test("The baseline menu lists the VM's snapshots and selects the chosen one")
    func ephemeralBaselineMenuListsSnapshots() {
        let (vc, instance) = makeEphemeralController(snapshotCount: 3, ephemeral: true)
        guard let popUp = firstPopUp(action: "ephemeralBaselineChanged", in: vc.view) else {
            Issue.record("Expected a Baseline snapshot popup")
            return
        }

        #expect(popUp.itemArray.count == 3)
        #expect(
            (popUp.selectedItem?.representedObject as? UUID)
                == instance.hostState.ephemeralBaselineSnapshotID)
    }

    @Test("Choosing another snapshot moves the baseline")
    func ephemeralBaselineSelectionWritesConfig() {
        let (vc, instance) = makeEphemeralController(snapshotCount: 3, ephemeral: true)
        guard let popUp = firstPopUp(action: "ephemeralBaselineChanged", in: vc.view) else {
            Issue.record("Expected a Baseline snapshot popup")
            return
        }
        // Rows render newest first, so the first item is not the Current one.
        let newest = popUp.itemArray[0].representedObject as? UUID

        popUp.select(popUp.itemArray[0])
        popUp.sendAction(popUp.action, to: popUp.target)

        #expect(instance.hostState.ephemeralBaselineSnapshotID == newest)
        #expect(instance.hostState.ephemeralModeEnabled)
    }

    /// The flag is read at power-off and reaches no `VZVirtualMachineConfiguration`,
    /// so it stays editable while the VM runs — and a running ephemeral VM is
    /// exactly where a user reaches for the switch.
    @Test("The Ephemeral toggle stays editable while the VM is running")
    func ephemeralToggleStaysEnabledWhenReadOnly() {
        let (vc, _) = makeEphemeralController(
            snapshotCount: 1, ephemeral: false, isReadOnly: true)

        #expect(firstSwitch(action: "ephemeralModeToggled", in: vc.view)?.isEnabled == true)
    }

    @Test("What an ephemeral VM does is the Ephemeral Mode row's info, not a caption")
    func ephemeralExplanationLivesInTheRowInfo() {
        let (vc, _) = makeEphemeralController(snapshotCount: 1, ephemeral: true)
        #expect(infoButton(about: "Ephemeral Mode", in: vc.view) != nil)
        #expect(findLabel(containing: "An ephemeral virtual machine", in: vc.view) == nil)
    }

    @Test("Each baseline entry is its snapshot's name")
    func ephemeralBaselineMenuListsSnapshotNames() throws {
        let (vc, _) = makeEphemeralController(
            snapshots: [
                makeSnapshot(index: 0, kind: .warm), makeSnapshot(index: 1, kind: .cold),
            ], ephemeral: true)
        let popUp = try #require(firstPopUp(action: "ephemeralBaselineChanged", in: vc.view))

        // Rows render newest first, so the cold one leads.
        #expect(popUp.itemArray.map(\.title) == ["Snapshot 1", "Snapshot 0"])
    }

    /// Nothing keeps two snapshots from sharing a name, and both have to stay
    /// pickable — an entry dropped for carrying a duplicate title would take a
    /// baseline out of reach.
    @Test("Two snapshots sharing a name both list")
    func ephemeralBaselineMenuKeepsDuplicateNames() throws {
        let snapshots = [
            makeSnapshot(index: 0, kind: .warm, name: "Baseline"),
            makeSnapshot(index: 1, kind: .warm, name: "Baseline"),
        ]
        let (vc, instance) = makeEphemeralController(snapshots: snapshots, ephemeral: true)
        let popUp = try #require(firstPopUp(action: "ephemeralBaselineChanged", in: vc.view))

        #expect(popUp.itemArray.count == 2)
        #expect(
            (popUp.selectedItem?.representedObject as? UUID)
                == instance.hostState.ephemeralBaselineSnapshotID)
    }

    @Test("A warm baseline says the VM comes back suspended")
    func ephemeralWarmBaselineCaptionIsShown() {
        let (vc, _) = makeEphemeralController(snapshotCount: 1, ephemeral: true, kind: .warm)

        #expect(visibleLabel(EphemeralModeCopy.baselineCaption(for: .warm), in: vc.view))
        #expect(!visibleLabel(EphemeralModeCopy.baselineCaption(for: .cold), in: vc.view))
    }

    @Test("A cold baseline says the VM comes back stopped")
    func ephemeralColdBaselineCaptionIsShown() {
        let (vc, _) = makeEphemeralController(snapshotCount: 1, ephemeral: true, kind: .cold)

        #expect(visibleLabel(EphemeralModeCopy.baselineCaption(for: .cold), in: vc.view))
        #expect(!visibleLabel(EphemeralModeCopy.baselineCaption(for: .warm), in: vc.view))
    }

    /// There is no baseline to describe while the mode is off, and the caption
    /// follows the sub-option that holds the choice.
    @Test("No baseline caption shows while the mode is off")
    func ephemeralBaselineCaptionHiddenWhenOff() {
        let (vc, _) = makeEphemeralController(snapshotCount: 1, ephemeral: false)

        #expect(!visibleLabel(EphemeralModeCopy.baselineCaption(for: .warm), in: vc.view))
        #expect(!visibleLabel(EphemeralModeCopy.baselineCaption(for: .cold), in: vc.view))
    }

    @Test("The baseline caption starts at the Baseline snapshot title's edge")
    func ephemeralBaselineCaptionAlignsWithItsRow() throws {
        let (vc, _) = makeEphemeralController(snapshotCount: 1, ephemeral: true)
        vc.view.frame = NSRect(x: 0, y: 0, width: 700, height: 900)
        vc.view.layoutSubtreeIfNeeded()

        let caption = try #require(
            findLabel(withText: EphemeralModeCopy.baselineCaption(for: .warm), in: vc.view))
        let title = try #require(findLabel(withText: "Baseline snapshot", in: vc.view))
        let card = try #require(enclosingGroupedFormCard(of: caption))
        #expect(try alignmentRect(of: caption, in: card).minX == alignmentRect(of: title, in: card).minX)
    }

    /// The caption is the selected baseline's, so moving the choice to a
    /// different kind moves the caption with it.
    @Test("Choosing a cold baseline swaps the caption")
    func ephemeralBaselineCaptionFollowsTheSelection() throws {
        let (vc, _) = makeEphemeralController(
            snapshots: [
                makeSnapshot(index: 0, kind: .warm), makeSnapshot(index: 1, kind: .cold),
            ], ephemeral: true)
        let popUp = try #require(firstPopUp(action: "ephemeralBaselineChanged", in: vc.view))

        // Newest first, so item 0 is the cold one.
        popUp.select(popUp.itemArray[0])
        popUp.sendAction(popUp.action, to: popUp.target)
        // The written configuration re-enters `apply()` through the model's own
        // observation in the app; here the render is asked for directly.
        vc.viewDidAppear()

        #expect(visibleLabel(EphemeralModeCopy.baselineCaption(for: .cold), in: vc.view))
        #expect(!visibleLabel(EphemeralModeCopy.baselineCaption(for: .warm), in: vc.view))
    }

    // MARK: - Startup capacity warning

    /// Builds a controller over a library holding `markedMacOSVMs` macOS VMs
    /// marked to start automatically — the VM under test among them when it is
    /// itself a macOS guest.
    private func makeStartupController(guestOS: VMGuestOS, markedMacOSVMs: Int) -> (
        VMSettingsViewController, VMInstance
    ) {
        let viewModel = makeViewModel()
        let marksItself = guestOS == .macOS && markedMacOSVMs > 0
        let instance = viewModel.library.admitFixture(
            guestOS: guestOS, hostState: VMHostState(startsAutomaticallyOnLaunch: marksItself))
        for index in 0..<(markedMacOSVMs - (marksItself ? 1 : 0)) {
            viewModel.library.admitFixture(
                guestOS: .macOS, hostState: VMHostState(startsAutomaticallyOnLaunch: true)
            ) {
                $0.name = "Marked \(index)"
            }
        }
        let vc = makeSettingsPane(
            instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.general)
        return (vc, instance)
    }

    @Test("Three marked macOS VMs warn that macOS won't run them all")
    func startupWarnsOverTheMacOSLimit() throws {
        let (vc, _) = makeStartupController(guestOS: .macOS, markedMacOSVMs: 3)
        let warning = try #require(
            VMOverviewResolver.autoStartCapacityWarning(
                isMacOSGuest: true, markedMacOSVMCount: 3))

        #expect(visibleLabel(warning, in: vc.view))
    }

    /// Whether any visible label carries the capacity warning's vendor sentence.
    ///
    /// Matched by substring rather than by whole string: the message leads with
    /// the marked count, so the exact text is only known where a warning is
    /// expected — and the absence assertions are exactly where it is not.
    private func showsMacOSCapacityWarning(in view: NSView) -> Bool {
        firstSubview(NSTextField.self, in: view) {
            $0.stringValue.contains("but macOS runs at most two at once")
                && isVisible($0, within: view)
        } != nil
    }

    @Test("Two marked macOS VMs are within the limit and warn about nothing")
    func startupDoesNotWarnAtTheMacOSLimit() {
        let (vc, _) = makeStartupController(guestOS: .macOS, markedMacOSVMs: 2)
        #expect(!showsMacOSCapacityWarning(in: vc.view))
    }

    /// Linux guests don't count against the macOS cap, so the warning is not
    /// theirs to show even while three macOS VMs are marked.
    @Test("A Linux guest never shows the macOS capacity warning")
    func startupNeverWarnsOnALinuxGuest() {
        let (vc, _) = makeStartupController(guestOS: .linux, markedMacOSVMs: 3)
        #expect(!showsMacOSCapacityWarning(in: vc.view))
    }

    /// One row of the capacity-warning decision table.
    struct CapacityCase: Sendable, CustomStringConvertible {
        let isMacOSGuest: Bool
        let marked: Int
        let warns: Bool

        init(_ isMacOSGuest: Bool, _ marked: Int, _ warns: Bool) {
            self.isMacOSGuest = isMacOSGuest
            self.marked = marked
            self.warns = warns
        }

        var description: String {
            "\(isMacOSGuest ? "macOS" : "Linux") guest, \(marked) marked → "
                + (warns ? "warns" : "silent")
        }
    }

    @Test(
        "autoStartCapacityWarning fires only for a macOS guest over the limit",
        arguments: [
            CapacityCase(true, 0, false),
            CapacityCase(true, 1, false),
            CapacityCase(true, 2, false),
            CapacityCase(true, 3, true),
            CapacityCase(true, 7, true),
            // A Linux guest doesn't count against the macOS cap and can do
            // nothing about it from its own pane.
            CapacityCase(false, 3, false),
            CapacityCase(false, 7, false),
        ])
    func autoStartCapacityWarningMatrix(testCase: CapacityCase) {
        let warning = VMOverviewResolver.autoStartCapacityWarning(
            isMacOSGuest: testCase.isMacOSGuest, markedMacOSVMCount: testCase.marked)

        #expect((warning != nil) == testCase.warns)
        if let warning {
            // The vendor's claim, at the vendor's strength.
            #expect(warning.contains("macOS runs at most two at once"))
            #expect(warning.hasPrefix("\(testCase.marked) macOS virtual machines"))
        }
    }

    // MARK: - Machine ID

    private static let sharedMachineIDNote = "Same machine ID as \u{201C}Twin\u{201D}."

    @Test("A VM with a machine ID shows its fingerprint, the whole digest in the tooltip")
    func machineIDRowShowsTheFingerprint() throws {
        let identity = Data([2, 7, 1, 8])
        let viewModel = makeViewModel()
        let instance = viewModel.library.registerFixture { $0.genericMachineIdentifierData = identity }
        let vc = makeSettingsPane(instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.general)

        let fingerprint = MachineIdentity.generic(identity).fingerprint
        #expect(visibleLabel("Machine ID", in: vc.view))
        let value = try #require(panelLabel(fingerprint.short, in: vc))
        #expect(isVisible(value, within: vc.view))
        #expect(value.toolTip == fingerprint.digest)
        #expect(value.font?.isFixedPitch == true)
        #expect(!visibleLabel(Self.sharedMachineIDNote, in: vc.view))
        #expect(separatesEveryRow(generalCardLayout(in: vc)))
    }

    @Test("A VM with no machine ID shows no Machine ID row")
    func machineIDRowHiddenWithoutAnIdentifier() {
        let (vc, _, _) = makeController(guestOS: .linux, isReadOnly: false)

        #expect(!visibleLabel("Machine ID", in: vc.view))
        #expect(separatesEveryRow(generalCardLayout(in: vc)))
    }

    @Test("Another VM arriving with the same machine ID is named under the Machine ID row")
    func sharedMachineIDFollowsTheLibrary() async throws {
        let identity = Data([2, 7, 1, 8])
        let viewModel = makeViewModel()
        let instance = viewModel.library.registerFixture { $0.genericMachineIdentifierData = identity }
        let vc = makeSettingsPane(instance: instance, viewModel: viewModel, isReadOnly: false)
        vc.loadViewIfNeeded()
        vc.viewDidAppear()
        vc.showCategory(.general)
        #expect(!visibleLabel(Self.sharedMachineIDNote, in: vc.view))

        viewModel.library.registerFixture(name: "Twin") { $0.genericMachineIdentifierData = identity }
        // The pane's repaint is the main-actor task the change enqueued.
        await drainMainQueue()

        #expect(visibleLabel(Self.sharedMachineIDNote, in: vc.view))
        let title = try #require(panelLabel("Machine ID", in: vc))
        let owner = try #require(
            sequence(first: title as NSView, next: \.superview).first { $0 is GroupedFormNotedRow })
        #expect(visibleLabel(Self.sharedMachineIDNote, in: owner))
    }
}
