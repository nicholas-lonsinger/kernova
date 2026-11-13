import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaAgentRuntime
import KernovaKit
import KernovaTestSupport
import KernovaWire
import SwiftProtobuf
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMInstance Tests", .caseScoped)
@MainActor
struct VMInstanceTests {
    private let scratch = TestScratchDirectory(prefix: "VMInstanceTests")

    private static let oneSnapshot = VMSnapshotManifest(
        snapshots: [VMSnapshot(name: "One", macAddress: nil)])

    private static let revert = VMAdmission.Request.operation(
        .bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)))

    // MARK: - Snapshot eligibility

    @Test(
        "A live (running or live-paused) or stopped VM can be snapshotted; operations and unbootable states cannot"
    )
    func captureModeCoversLiveAndStopped() {
        for phase in [VMLifecyclePhase.running(sessionID: UUID()), .livePaused(sessionID: UUID())] {
            #expect(VMInstanceFixture.make(phase: phase).snapshotCaptureMode != nil, "phase \(phase)")
        }
        #expect(VMInstanceFixture.make(phase: .stopped).snapshotCaptureMode != nil)
        // Suspended is covered separately below — it can be snapshotted too,
        // just through a different capture mode.
        for phase in VMLifecyclePhaseFixtures.operations + [
            .failed(message: "Boot failed."), .initialBoot,
        ] {
            #expect(VMInstanceFixture.make(phase: phase).snapshotCaptureMode == nil, "phase \(phase)")
        }
    }

    @Test(
        "A suspended VM with no suspend slot cannot be captured — a dead end a failed snapshot attempt can leave it in"
    )
    func suspendedWithNoSaveFileCannotBeCaptured() {
        let instance = VMInstanceFixture.make(phase: .suspended)
        #expect(instance.isSuspended)
        #expect(!instance.hasSaveFile)

        #expect(instance.snapshotCaptureMode == nil)
    }

    @Test("A revert needs a snapshot to go back to")
    func revertNeedsASnapshot() {
        let instance = VMInstanceFixture.make(phase: .stopped)
        #expect(!instance.activity.admits(Self.revert))

        instance.seedSnapshotManifest(Self.oneSnapshot)
        #expect(instance.activity.admits(Self.revert))
    }

    // MARK: - detailPaneMode

    @Test("detailPaneMode is per-instance (independent between VMs)")
    func detailPaneModeIsPerInstance() {
        let a = VMInstanceFixture.make()
        let b = VMInstanceFixture.make()
        a.detailPaneMode = .settings
        #expect(a.detailPaneMode == .settings)
        #expect(b.detailPaneMode == .display)
    }

    @Test("A power-off clears detailPaneMode back to .display")
    func powerOffClearsDetailPaneMode() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        instance.detailPaneMode = .settings

        instance.handleSessionEvent(.guestDidStop)

        #expect(instance.detailPaneMode == .display)
        #expect(instance.status == .stopped)
    }

    // MARK: - The session ending

    @Test("A hidden (headless) display reads inline once its session ends")
    func sessionEndResetsHiddenDisplayMode() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        instance.displayMode = .hidden

        instance.handleSessionEvent(.guestDidStop)

        #expect(instance.displayMode == .inline)
    }

    /// Only the close of the display window moves the mode, since the window
    /// can outlive the session — across a Restart, it shows the next one.
    @Test("A session's end leaves a display window's mode alone", arguments: [VMDisplayMode.popOut, .fullscreen])
    func sessionEndKeepsWindowDisplayMode(mode: VMDisplayMode) {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        instance.displayMode = mode

        instance.handleSessionEvent(.guestDidStop)

        #expect(instance.displayMode == mode)
    }

    @Test("Hiding the display of a VM with no session leaves it inline")
    func hidingWithoutASessionStaysInline() {
        let instance = VMInstanceFixture.make(phase: .stopped)

        instance.displayMode = .hidden

        #expect(instance.displayMode == .inline)
    }

    // MARK: - The suspend slot

    @Test("A suspend slot only counts while nothing is live")
    func holdsSuspendedSessionNeedsAnAtRestPhase() throws {
        let instance = VMInstanceFixture.make(phase: .suspended)
        #expect(!instance.holdsSuspendedSession)

        try VMInstanceFixture.writeSaveFile(for: instance)
        for phase: VMLifecyclePhase in [.suspended, .stopped, .failed(message: "x"), .initialBoot] {
            instance.activity.placeForTesting(phase)
            #expect(instance.holdsSuspendedSession, "\(phase)")
            #expect(!instance.activity.admits(.edit(.machineKeys)), "\(phase)")
            #expect(instance.activity.admits(.resume), "\(phase)")
            #expect(instance.activity.admits(.operation(.deleting)), "\(phase)")
        }
        let live = VMLifecyclePhase.running(sessionID: UUID())
        for phase: VMLifecyclePhase in [
            live, .operating(.saving, from: live),
            .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped),
            .operating(.bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)), from: .stopped),
        ] {
            instance.activity.placeForTesting(phase)
            #expect(!instance.holdsSuspendedSession, "\(phase)")
        }
    }

    @Test("A VM answers admission as it will stand once its saved state is discarded")
    func decideAfterTheSaveFileIsDeletedLiftsOnlyThatTerm() throws {
        let instance = VMInstanceFixture.make(phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: instance)
        let edit = VMAdmission.Request.edit(.machineKeys)

        #expect(!instance.activity.admits(edit))
        #expect(instance.activity.decide(edit, posture: .commit, after: .deletesSaveFile) == .admit)
        // A revert to a cold baseline lands it stopped too; a warm baseline's
        // lands it suspended on the baseline's own saved state.
        let cold = VMSnapshot(name: "Cold", kind: .cold, macAddress: nil)
        let warm = VMSnapshot(name: "Warm", kind: .warm, macAddress: nil)
        #expect(instance.activity.decide(edit, posture: .commit, after: .revertsToBaseline(cold)) == .admit)
        #expect(instance.activity.decide(edit, posture: .commit, after: .revertsToBaseline(warm)) != .admit)
        // The file is untouched, and the answer goes on reading it.
        #expect(instance.hasSaveFile)
        #expect(!instance.activity.admits(edit))

        // Only that term is lifted: a VM no phase admits the edit in stays
        // refused.
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        #expect(instance.activity.decide(edit, posture: .commit, after: .deletesSaveFile) != .admit)
    }

    // MARK: - isSuspended

    @Test("isSuspended is false when stopped")
    func isSuspendedFalseWhenStopped() {
        let instance = VMInstanceFixture.make(phase: .stopped)
        #expect(instance.isSuspended == false)
    }

    // MARK: - hasLiveSession

    @Test(
        "hasLiveSession is false during an operation that shows its own status, even with a live virtual machine",
        arguments: [
            PhaseFixture.operating(.saving, from: .running(sessionID: UUID())),
            .operating(.bringUp(.guestStart(.restoringSavedState)), from: .suspended, boundSession: UUID()),
            .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped, boundSession: UUID()),
            .operating(.bringUp(.settingUp(.macOSInstall)), from: .initialBoot, boundSession: UUID()),
            .operating(.capturingSnapshot(.live), from: .running(sessionID: UUID())),
        ])
    func hasLiveSessionIsFalseDuringAnOperation(phase: PhaseFixture) {
        // A VM that has not settled at running or live-paused is not something
        // the termination pass can snapshot.
        #expect(VMInstanceFixture.make(phase: phase.phase).hasLiveSession == false)
    }

    // MARK: - effectiveMachineIdentifierData

    @Test("A file the install writes is the identifier, though the bundle was read before it existed")
    func effectiveMachineIDFollowsThePlatformFilesWrite() async throws {
        let machineFiles = MockVMBundleMachineFiles()
        let instance = VMInstanceFixture.make(
            guestOS: .macOS, bundleFactory: VMBundle.Factory(machineFiles: machineFiles))
        try FileManager.default.createDirectory(at: instance.bundleURL, withIntermediateDirectories: true)
        #expect(instance.machineIdentity == nil)

        let changed = ObservationFireRecorder()
        withObservationTracking {
            _ = instance.machineIdentity
        } onChange: {
            changed.record()
        }
        machineFiles.setPlatformMachineIdentifier(Data([7, 7, 7]))
        _ = try await withOperation(on: instance) { context in
            try await context.bundle.createMacPlatformFiles(hardwareModel: Data())
        }

        #expect(changed.didFire)
        #expect(instance.configuration.machineIdentifierData == nil)
        #expect(instance.machineIdentity == .mac(Data([7, 7, 7])))
    }

    // MARK: - machineIdentity

    @Test("A macOS guest's identity is its effective macOS identifier")
    func machineIdentityOfAMacOSGuest() throws {
        let configured = VMInstanceFixture.make(guestOS: .macOS) { $0.machineIdentifierData = Data([1]) }
        #expect(configured.machineIdentity == .mac(Data([1])))

        let fileOnly = VMInstanceFixture.make(guestOS: .macOS)
        try FileManager.default.createDirectory(at: fileOnly.bundleURL, withIntermediateDirectories: true)
        try Data([2]).write(to: fileOnly.machineIdentifierURL)
        #expect(fileOnly.machineIdentity == .mac(Data([2])))
    }

    @Test("A Linux guest's identity is its generic identifier, and nil without one")
    func machineIdentityOfALinuxGuest() {
        let identified = VMInstanceFixture.make { $0.genericMachineIdentifierData = Data([3]) }
        #expect(identified.machineIdentity == .generic(Data([3])))
        #expect(VMInstanceFixture.make().machineIdentity == nil)
    }

    // MARK: - isKeepingAppAlive

    @Test("isKeepingAppAlive is true for active statuses")
    func isKeepingAppAliveActive() {
        for phase in [VMLifecyclePhase.running(sessionID: UUID())] + VMLifecyclePhaseFixtures.operations {
            let instance = VMInstanceFixture.make(phase: phase)
            #expect(instance.isKeepingAppAlive == true, "\(phase)")
        }
    }

    // MARK: - Bundle Paths

    @Test("Bundle path URLs are correctly derived from bundleURL")
    func bundlePaths() {
        let instance = VMInstanceFixture.make()

        #expect(instance.diskImageURL.lastPathComponent == "Disk.asif")
        #expect(instance.bundleLayout.saveFileURL.lastPathComponent == "SaveFile.vzvmsave")
    }

    // MARK: - Serial Console

    @Test("serialLogURL is forwarded from bundleLayout")
    func serialLogURL() {
        let instance = VMInstanceFixture.make()
        #expect(instance.serialLogURL.lastPathComponent == "serial.log")
    }

    // MARK: - Status Display Properties

    @Test("statusDisplayName delegates to status.displayName in every phase")
    func statusDisplayNameDelegates() {
        for phase in VMLifecyclePhaseFixtures.all {
            #expect(VMInstanceFixture.make(phase: phase).statusDisplayName == phase.status.displayName, "\(phase)")
        }
    }

    @Test("statusToolTip names disk when suspended and memory when live-paused")
    func statusToolTipSuspendedAndPaused() {
        #expect(VMInstanceFixture.make(phase: .suspended).statusToolTip == "VM state is saved to disk")
        #expect(
            VMInstanceFixture.make(phase: .livePaused(sessionID: UUID())).statusToolTip
                == "VM is paused in memory")
    }

    @Test("statusToolTip carries the stored message in the error state")
    func statusToolTipError() {
        let instance = VMInstanceFixture.make(phase: .failed(message: "The virtual machine failed to start."))
        #expect(instance.statusToolTip == "The virtual machine failed to start.")
    }

    // MARK: - Network Attachment Recovery

    @Test("A running VM awaiting network reattach says why")
    func networkPendingSaysWhy() {
        let library = makeWiredLibrary()
        let instance = library.registerFixture(phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting().networkAttachment = .detached

        // The wording names what is actually unavailable: the app-managed
        // network for NAT and Host Only, a host interface and the VM's own
        // NAT network for Bridged.
        library.editConfiguration(of: instance, as: .networkAttachment) { $0.networkMode = .nat }
        #expect(
            instance.statusToolTip
                == "The NAT network is unavailable. Kernova reconnects automatically.")
        library.editConfiguration(of: instance, as: .networkAttachment) { $0.networkMode = .hostOnly }
        #expect(
            instance.statusToolTip
                == "The Host Only network is unavailable. Kernova reconnects automatically.")
        library.editConfiguration(of: instance, as: .networkAttachment) { $0.networkMode = .bridged }
        #expect(instance.statusToolTip?.contains("network interface") == true)
        #expect(instance.statusToolTip?.contains("isn\u{2019}t connected") == true)
    }

    @Test("A running Bridged VM on its own NAT network says so, naming the missing interface")
    func bridgedFallbackSaysWhy() async {
        let library = makeWiredLibrary()
        let instance = library.registerFixture(phase: .running(sessionID: UUID())) {
            $0.networkEnabled = true
            $0.networkMode = .bridged
            $0.bridgedInterfaceIdentifier = "en1"
        }
        let device = MockNetworkDeviceControl()
        let coordinator = attachNetworkCoordinator(to: instance, device: device, entitlements: .entitled)
        coordinator.activate()
        await coordinator.vmnetMaterializationTaskForTesting?.value

        #expect(instance.isOnBridgedFallback)
        #expect(instance.statusToolTip?.contains("en1") == true)
        #expect(instance.statusToolTip?.contains("until it returns") == true)

        library.editConfiguration(of: instance, as: .networkAttachment) { $0.bridgedInterfaceIdentifier = nil }
        #expect(instance.statusToolTip?.contains("No network interface can be bridged") == true)
        #expect(instance.statusToolTip?.contains("until one can") == true)

        // The same network chosen as NAT – Isolated is where the VM belongs.
        library.editConfiguration(of: instance, as: .networkAttachment) {
            $0.networkMode = .nat
            $0.networkMembership = .isolated
        }
        #expect(device.currentPlan == .vmnet(.own(.nat)))
        #expect(!instance.isOnBridgedFallback)
        #expect(instance.statusToolTip == nil)
        coordinator.stop()
    }

    @Test("applyLivePolicy forwards a network mode change to the coordinator")
    func applyLivePolicyForwardsNetworkChange() {
        let library = makeWiredLibrary()
        let instance = library.registerFixture(phase: .running(sessionID: UUID())) {
            $0.networkEnabled = true
            $0.networkMode = .nat
        }
        let device = MockNetworkDeviceControl(plan: .vmnet(.common(.nat)))
        let coordinator = attachNetworkCoordinator(
            to: instance, device: device,
            provider: MockBridgedInterfaceProvider(
                available: [BridgedInterface(identifier: "en0", localizedDisplayName: "Wi-Fi")]),
            entitlements: .entitled)
        coordinator.activate()
        #expect(device.appliedPlans.isEmpty)

        library.editConfiguration(of: instance, as: .networkAttachment) {
            $0.networkMode = .bridged
            $0.bridgedInterfaceIdentifier = "en0"
        }

        #expect(device.appliedPlans == [.bridged("en0")])
    }

    @Test("A session's end stops network recovery and clears the pending flag")
    func sessionEndStopsNetworkRecovery() throws {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID())) {
            $0.networkEnabled = true
            $0.networkMode = .bridged
        }
        let device = MockNetworkDeviceControl()
        let observer = MockNetworkLinkObserver()
        let coordinator = attachNetworkCoordinator(
            to: instance, device: device, linkObserver: observer)
        coordinator.activate()
        #expect(observer.isObserving)
        #expect(instance.networkAttachmentPending)
        let context = try #require(instance.sessionContext)

        instance.handleSessionEvent(.guestDidStop)

        // `NetworkAttachmentCoordinator.isActive` is private, so the mock link
        // observer is the only external signal that `stop()` actually ran —
        // reading `instance.networkAttachmentCoordinator` here would pass
        // whether or not `tearDown()` stopped the coordinator, since it is
        // that same context's slot the teardown nils regardless.
        #expect(context.networkAttachmentCoordinator == nil)
        #expect(context.networkAttachment == nil)
        #expect(!observer.isObserving)
    }

    // MARK: - Lifecycle Action Labels

    /// Builds a stopped VM with an install context whose download destination has
    /// a sibling `.kernovadownload` bundle seeded on disk.
    ///
    /// `partialBytes` is what the bundle's `data` file holds: pass `nil` for the
    /// husk a finalize leaves when its disposal fails (directory and metadata
    /// present, `data` already moved to the destination).
    private func makeInstanceWithSeededDownloadBundle(
        partialBytes: Data?,
        source: MacOSInstallContext.Source = .downloadLatest
    ) throws -> VMInstance {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)

        let destination = scratch.url.appendingPathComponent("RestoreImage.ipsw")
        let bundle = DownloadBundle(url: DownloadService.resumeBundleURL(for: destination))
        try bundle.prepareForFreshDownload(
            with: DownloadBundleMetadata(
                originalURL: URL(fileURLWithPath: "/tmp/RestoreImage.ipsw"),
                etag: nil,
                lastModified: nil,
                createdAt: Date()
            )
        )
        if let partialBytes {
            try partialBytes.write(to: bundle.dataURL)
        } else {
            try FileManager.default.removeItem(at: bundle.dataURL)
        }
        // Guards against a vacuous pass: the husk case asserts a *false*
        // `hasResumableInstallDownload`, which an absent bundle would also
        // produce. The directory must be there for the test to mean anything.
        #expect(bundle.exists)

        let instance = VMInstanceFixture.make(phase: .stopped) {
            $0.installContext = MacOSInstallContext(
                source: source,
                downloadDestinationPath: destination.path(percentEncoded: false)
            )
        }
        return instance
    }

    @Test("startAction is .install when the bundle is a data-less husk")
    func startActionInstallWithHuskBundle() throws {
        // A finalize whose disposal failed leaves the bundle directory (and its
        // metadata) behind with `data` already moved to the destination. It has
        // no bytes to resume from, so it must not offer "Resume Install".
        let instance = try makeInstanceWithSeededDownloadBundle(partialBytes: nil)

        #expect(instance.hasResumableInstallDownload == false)
        #expect(instance.startAction == .install)
        #expect(instance.startAction.label == "Install")
    }

    @Test(
        "startAction is .resumeInstall when the bundle still holds partial bytes",
        arguments: [
            MacOSInstallContext.Source.downloadLatest, .catalogVersion, .customURL,
        ]
    )
    func startActionResumeInstallWithPartialBytes(source: MacOSInstallContext.Source) throws {
        // Every downloading source writes the same sidecar and resumes through
        // the same path, so all three offer "Resume Install".
        let instance = try makeInstanceWithSeededDownloadBundle(
            partialBytes: Data(repeating: 0x11, count: 1024),
            source: source
        )

        #expect(instance.hasResumableInstallDownload == true)
        #expect(instance.startAction == .resumeInstall)
        #expect(instance.startAction.label == "Resume Install")
    }

    @Test("startAction is .install for a local-file install beside a partial bundle")
    func startActionInstallForLocalFileSource() throws {
        // A local-file install never downloads, so a bundle left at the same
        // path by an earlier attempt says nothing about what Start will do.
        let instance = try makeInstanceWithSeededDownloadBundle(
            partialBytes: Data(repeating: 0x11, count: 1024),
            source: .localFile
        )

        #expect(instance.hasResumableInstallDownload == false)
        #expect(instance.startAction == .install)
    }

    @Test("startAction is .resumeDownload when a Linux image's bundle holds partial bytes")
    func startActionResumeDownload() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)

        let destination = scratch.url.appendingPathComponent("debian-13.6.0-arm64-netinst.iso")
        let bundle = DownloadBundle(url: DownloadService.resumeBundleURL(for: destination))
        try bundle.prepareForFreshDownload(
            with: DownloadBundleMetadata(
                originalURL: URL(fileURLWithPath: destination.path(percentEncoded: false)),
                etag: nil, lastModified: nil, createdAt: Date()))
        try Data(repeating: 0x11, count: 1024).write(to: bundle.dataURL)

        let instance = VMInstanceFixture.make(phase: .stopped) {
            $0.linuxInstallContext = LinuxInstallContext(
                source: .catalogEntry(makeLinuxCatalogEntry()),
                downloadDestinationPath: destination.path(percentEncoded: false))
        }

        #expect(instance.hasResumableInstallDownload == true)
        #expect(instance.startAction == .resumeDownload)
        #expect(instance.startAction.label == "Resume Download")
    }

    @Test("An Ephemeral VM's stop labels name the revert, not a discard")
    func stopActionTitlesNameTheRevert() {
        #expect(VMInstance.StopAction.revertToBaseline.menuTitle == "Revert to Baseline…")
        #expect(VMInstance.StopAction.revertToBaseline.toolbarLabel == "Revert to Baseline")
        #expect(
            VMInstance.StopAction.revertToBaseline.toolTip
                == "Return the virtual machine to its baseline snapshot")
    }

    /// A VM whose bundle exists on disk, holding a warm baseline snapshot whose
    /// captured saved state the bundle's own suspend slot can be compared to.
    private func makeEphemeralInstanceWithBundle(
        ephemeralModeEnabled: Bool = true
    ) throws -> (instance: VMInstance, baseline: VMSnapshot) {
        let baseline = VMSnapshot(name: "Ephemeral", macAddress: nil)
        let instance = VMInstanceFixture.make(
            name: "Ephemeral VM", phase: .suspended,
            hostState: ephemeralModeEnabled ? .ephemeral(baseline: baseline.id) : VMHostState())
        try FileManager.default.createDirectory(at: instance.bundleURL, withIntermediateDirectories: true)
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [baseline]))

        let snapshotLayout = instance.bundleLayout.snapshotLayout(id: baseline.id)
        try FileManager.default.createDirectory(
            at: snapshotLayout.bundleURL, withIntermediateDirectories: true)
        try Data("captured".utf8).write(to: snapshotLayout.saveFileURL)
        return (instance, baseline)
    }

    @Test("A suspended Ephemeral VM holding the baseline's own saved state rests at it")
    func restingAtEphemeralBaseline() throws {
        let (instance, baseline) = try makeEphemeralInstanceWithBundle()
        let captured = instance.bundleLayout.snapshotLayout(id: baseline.id).saveFileURL

        try FileManager.default.copyItem(at: captured, to: instance.bundleLayout.saveFileURL)
        #expect(instance.isRestingAtEphemeralBaseline)
    }

    @Test("A suspend of its own leaves an Ephemeral VM away from its baseline")
    func ownSuspendIsNotTheEphemeralBaseline() throws {
        let (instance, _) = try makeEphemeralInstanceWithBundle()

        try Data("captured".utf8).write(to: instance.bundleLayout.saveFileURL)
        #expect(!instance.isRestingAtEphemeralBaseline)
    }

    @Test("A VM that is not suspended never reads as resting at its baseline")
    func restingAtBaselineNeedsASuspendedVM() throws {
        let (instance, baseline) = try makeEphemeralInstanceWithBundle()
        let captured = instance.bundleLayout.snapshotLayout(id: baseline.id).saveFileURL
        try FileManager.default.copyItem(at: captured, to: instance.bundleLayout.saveFileURL)

        instance.activity.placeForTesting(.running(sessionID: UUID()))
        #expect(!instance.isRestingAtEphemeralBaseline)
    }

    // MARK: - agentPresentation dispatch
    //
    // `VMInstance.agentPresentation` is the single read site for the UI; every
    // guest sources it from the agent hub's snapshot once its session attached
    // the hub a transport.

    @Test("A session without a socket device has no agent channel, so no presentation", arguments: VMGuestOS.allCases)
    func agentPresentationSessionWithoutTransportIsNil(guestOS: VMGuestOS) {
        let instance = VMInstanceFixture.make(guestOS: guestOS, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        #expect(instance.agentPresentation == nil)
    }

    @Test("agentStatus returns to nil once the session ends")
    func agentStatusIsNilAfterTheSessionEnds() {
        let instance = makeMacOSInstanceWithAgentInstalled()
        #expect(instance.agentPresentation?.status == .connecting(expected: "0.9.2"))

        instance.handleSessionEvent(.guestDidStop)

        #expect(instance.sessionContext == nil)
        #expect(instance.agentPresentation?.status == nil)
    }

    // MARK: - An operation's ending

    @Test("Moving out of a failure drops its message rather than carrying it forward")
    func failureMessageCannotOutliveItsPhase() {
        let instance = VMInstanceFixture.make(phase: .failed(message: "The disk went away."))
        #expect(instance.errorMessage == "The disk went away.")

        instance.activity.placeForTesting(.stopped)

        #expect(instance.errorMessage == nil)
    }

    // MARK: - Settling running

    /// One operation ending with the guest running, and what that ending
    /// switches on.
    struct SettleRunningRow: Sendable, CustomTestStringConvertible {
        let kind: VMOperationKind
        let startedFrom: VMLifecyclePhase
        let slot: Bool
        let activatesNetwork: Bool
        let armsWatchdog: Bool

        var testDescription: String { "\(kind)" }
    }

    nonisolated private static let settleSession = UUID()

    nonisolated private static let settleRunningRows: [SettleRunningRow] = [
        SettleRunningRow(
            kind: .bringUp(.guestStart(.starting(recovery: false))), startedFrom: .stopped, slot: false,
            activatesNetwork: true, armsWatchdog: true),
        // A restore resumes whatever guest state was frozen, which may be a
        // Recovery session that never runs the agent — Start of a VM holding a
        // slot included.
        SettleRunningRow(
            kind: .bringUp(.guestStart(.restoringSavedState)), startedFrom: .suspended, slot: true,
            activatesNetwork: true, armsWatchdog: false),
        SettleRunningRow(
            kind: .bringUp(.reverting(snapshotID: settleSession, resumesAfter: true)),
            startedFrom: .running(sessionID: settleSession), slot: false,
            activatesNetwork: true, armsWatchdog: false),
        SettleRunningRow(
            kind: .resuming, startedFrom: .livePaused(sessionID: settleSession), slot: false,
            activatesNetwork: true, armsWatchdog: true),
        SettleRunningRow(
            kind: .deletingSnapshot, startedFrom: .running(sessionID: settleSession), slot: false,
            activatesNetwork: false, armsWatchdog: false),
    ]

    @Test(
        "An operation ending with the guest running activates the network and arms the watchdog as its kind says",
        arguments: settleRunningRows)
    func settlingRunningFollowsTheKind(row: SettleRunningRow) async throws {
        let instance = VMInstanceFixture.make(
            name: "Settle VM", guestOS: .macOS, phase: row.startedFrom,
            snapshots: VMSnapshotManifest(
                snapshots: [VMSnapshot(id: Self.settleSession, name: "Base", macAddress: nil)],
                currentID: nil)
        ) {
            $0.networkEnabled = true
            $0.networkMode = .bridged
            $0.lastSeenAgentVersion = "0.9.2"
        }
        defer { instance.cancelAgentAbsenceWatchdog() }
        if row.slot { try VMInstanceFixture.writeSaveFile(for: instance) }
        let observer = MockNetworkLinkObserver()

        switch row.kind {
        case .bringUp(let kind):
            try await instance.activity.launchAnyBringUp(kind) { context in
                // A revert ends the session it started from before it brings
                // the snapshot up.
                context.operation.endSession()
                instance.beginSessionContext(context)
                attachNetworkCoordinator(
                    to: instance, device: MockNetworkDeviceControl(), linkObserver: observer)
                context.bindSessionForTesting(UUID())
                return .rest(.live(.running), ())
            }.value()
        default:
            instance.beginSessionContextForTesting()
            attachNetworkCoordinator(
                to: instance, device: MockNetworkDeviceControl(), linkObserver: observer)
            try await instance.activity.perform(try #require(VMNonBringUpKind(row.kind))) {
                _ in .rest(.live(.running), ())
            }
        }

        #expect(instance.status == .running)
        #expect(observer.isObserving == row.activatesNetwork)
        #expect((instance.agentAbsenceTimerForTesting != nil) == row.armsWatchdog)
    }

    // MARK: - Session Events

    @Test("a session event whose id matches no live session is dropped")
    func staleSessionEventIsDropped() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        // No session attached: any delivered id is stale — the event a
        // torn-down session's guest stop produces after a fresh start.
        instance.deliverSessionEvent(.guestDidStop, from: UUID())
        #expect(instance.status == .running)
    }

    @Test("networkAttachmentDisconnected forwards to the recovery coordinator")
    func networkDisconnectedEventForwardsToCoordinator() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID())) {
            $0.networkEnabled = true
            $0.networkMode = .nat
        }
        let device = MockNetworkDeviceControl(plan: .nat)
        let coordinator = attachNetworkCoordinator(to: instance, device: device)
        coordinator.activate()
        #expect(device.appliedPlans.isEmpty)

        instance.handleSessionEvent(
            .networkAttachmentDisconnected(NSError(domain: "test", code: 2)))

        // The framework-nil'd mirror is cleared and the chosen mode reattached.
        #expect(device.appliedPlans == [.nat])
        #expect(device.currentPlan == .nat)
    }

    // MARK: - Agent Absence Watchdog
    //
    // The watchdog warns (`agentExpectedButMissing`) after a grace period when:
    //   - The VM is `.running` (a frozen guest can't answer),
    //   - `lastSeenAgentVersion` is set (so we have a baseline expectation),
    //   - No session peer is connected to the agent hub already,
    //   - No `setupState` is in progress, and
    //   - No session peer connects during the grace window.
    // The watchdog task is the only writer of what it flips, so a no-op test
    // proves no task was armed, and a cancel test awaits the task's return.

    /// Builds a macOS VMInstance with a known `lastSeenAgentVersion` and an
    /// open session context whose agent hub has a transport — the watchdog is
    /// session state, so it arms into one or not at all.
    ///
    /// Registered with `library` when one is passed — what a test whose VM
    /// writes its settings needs.
    ///
    /// The caller is responsible for explicitly clearing the watchdog if needed
    /// across tests.
    private func makeMacOSInstanceWithAgentInstalled(
        in library: VMLibrary? = nil,
        lastSeen: String = "0.9.2",
        lastSeenGuestOSVersion: String? = nil,
        setupState: GuestSetupState? = nil,
        bootedIntoRecovery: Bool = false,
        agentInstallNudgeDismissed: Bool = false
    ) -> VMInstance {
        let name = "macOS Watchdog Test"
        let phase = VMLifecyclePhase.running(sessionID: UUID())
        let hostState = VMHostState(agentInstallNudgeDismissed: agentInstallNudgeDismissed)
        let recordAgent: (inout VMConfiguration) -> Void = {
            $0.lastSeenAgentVersion = lastSeen
            $0.lastSeenAgentPayloadHash = Self.agentHash
            $0.lastSeenGuestOSVersion = lastSeenGuestOSVersion
        }
        let instance =
            library?.registerFixture(
                name: name, guestOS: .macOS, phase: phase, hostState: hostState, mutate: recordAgent)
            ?? VMInstanceFixture.make(
                name: name, guestOS: .macOS, phase: phase, hostState: hostState, mutate: recordAgent)
        instance.setupState = setupState
        instance.beginSessionContextForTesting(bootedIntoRecovery: bootedIntoRecovery).hasAgentTransport = true
        return instance
    }

    /// Lands a hub snapshot whose only peer is a session agent reporting
    /// `version`, standing `standing`, on the connection `handle`.
    private func connectSessionAgent(
        to instance: VMInstance, version: String = "0.9.2", standing: PeerSummary.Standing = .current,
        handle: UInt64 = 1
    ) {
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(
                peers: [
                    PeerSummary(
                        handle: PeerHandle(rawValue: handle), role: .sessionPeer, scope: .user, os: .macOS,
                        sessionID: "2", userName: "pbear", console: .on, versionLabel: version, standing: standing,
                        isResponsive: true, payloadHash: Self.agentHash)
                ], features: FeatureStatus.merge([])))
    }

    /// The payload hash the agent ``makeMacOSInstanceWithAgentInstalled(in:lastSeen:lastSeenGuestOSVersion:setupState:bootedIntoRecovery:agentInstallNudgeDismissed:)``
    /// records claimed, and ``connectSessionAgent(to:version:standing:handle:)``'s claims.
    private static let agentHash = Data(repeating: 0x7E, count: 32)

    /// Lands a hub snapshot with no peer: every agent went away.
    private func disconnectAgents(from instance: VMInstance) {
        instance.publishAgentHubSnapshotForTesting(.empty)
    }

    private static let testWatchdogGrace: Duration = .milliseconds(200)

    @Test("Cancelling the watchdog before grace prevents firing")
    func watchdogCancelledStaysQuiet() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.agentAbsenceGrace = Self.testWatchdogGrace
        instance.startAgentAbsenceWatch()
        let watchdog = try #require(instance.agentAbsenceTimerForTesting)

        instance.cancelAgentAbsenceWatchdog()
        await watchdog.value
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test("macOS: an agent that never connects this session warns once, at the floor plus the grace")
    func macOSNeverConnectedWarnsAtFloorPlusGrace() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.agentAbsenceGrace = Self.testWatchdogGrace
        instance.startAgentAbsenceWatch()
        let context = try #require(instance.sessionContext)
        let floor = try #require(context.agentAbsenceFloor)
        #expect(context.agentAbsenceTimerDeadline == floor + Self.testWatchdogGrace)

        await instance.agentAbsenceTimerForTesting?.value
        #expect(SystemScheduler().now >= floor + Self.testWatchdogGrace)
        #expect(instance.agentExpectedButMissing == true)
        #expect(instance.missingAgentNoticesForTesting.count == 1)
        #expect(instance.missingAgentNoticesForTesting.first?.contains("login agent, last seen 0.9.2") == true)
        #expect(instance.agentAbsenceTimerForTesting == nil)
    }

    @Test("Watchdog is a no-op for the whole of a recovery-booted session")
    func watchdogNoopAfterRecoveryBoot() {
        // Recovery never runs the agent, so its silence proves nothing — the
        // "didn't reconnect" badge would be false and clearing the stored guest
        // OS version would erase a value that is not in doubt. Session state,
        // not a per-call flag: a pause/resume inside a Recovery session reaches
        // the same arm site with no idea a Recovery boot happened.
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeenGuestOSVersion: "26.0",
            bootedIntoRecovery: true)

        instance.agentAbsenceGrace = Self.testWatchdogGrace

        instance.startAgentAbsenceWatch()
        #expect(instance.agentAbsenceTimerForTesting == nil)
    }

    @Test("Each boot attempt's context carries its own recovery-boot flag")
    func recoveryFlagIsPerSessionContext() {
        // The retry loop the cold-boot path runs tears the session down and
        // opens a fresh context per attempt, so a Recovery boot that hits
        // file-lock contention must come back up in Recovery.
        let instance = makeMacOSInstanceWithAgentInstalled(bootedIntoRecovery: true)
        #expect(instance.bootedIntoRecovery)

        instance.handleSessionEvent(.guestDidStop)
        #expect(!instance.bootedIntoRecovery)

        instance.beginSessionContextForTesting(bootedIntoRecovery: true)
        #expect(instance.bootedIntoRecovery)
        // And an ordinary attempt on the same instance is ordinary.
        instance.beginSessionContextForTesting()
        #expect(!instance.bootedIntoRecovery)
    }

    @Test("Watchdog is a no-op while macOS install is in progress")
    func watchdogNoopDuringMacOSInstall() {
        // No agent exists during install; no point arming the watchdog.
        let setupState = GuestSetupState.macOSInstall(hasDownloadStep: true)
        let instance = makeMacOSInstanceWithAgentInstalled(setupState: setupState)

        instance.agentAbsenceGrace = Self.testWatchdogGrace

        instance.startAgentAbsenceWatch()
        #expect(instance.agentAbsenceTimerForTesting == nil)
    }

    @Test("Reading the agents again with nothing changed keeps the armed timer and its deadline")
    func watchdogReevaluationKeepsTheTimer() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        defer { instance.cancelAgentAbsenceWatchdog() }
        instance.agentAbsenceGrace = .seconds(30)
        instance.startAgentAbsenceWatch()
        let armed = try #require(instance.agentAbsenceTimerForTesting)
        let deadline = instance.sessionContext?.agentAbsenceTimerDeadline

        instance.agentPresenceChanged()
        instance.agentPresenceChanged()
        #expect(instance.agentAbsenceTimerForTesting == armed)
        #expect(instance.sessionContext?.agentAbsenceTimerDeadline == deadline)
    }

    @Test("Watchdog firing also clears a previously-dismissed install nudge and persists the change")
    func watchdogClearsAgentInstallNudgeDismissed() async throws {
        // Scenario: user previously installed the agent (lastSeenAgentVersion
        // set) and earlier dismissed the install nudge for this VM. The
        // agent now fails to reconnect after boot; the watchdog fires
        // .expectedMissing AND resets the dismissed flag so any future
        // .waiting (e.g. they wipe + reinstall the VM) is not silently
        // suppressed by their old preference.
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = makeMacOSInstanceWithAgentInstalled(in: library, agentInstallNudgeDismissed: true)
        defer { withExtendedLifetime(library) {} }

        instance.agentAbsenceGrace = Self.testWatchdogGrace

        instance.startAgentAbsenceWatch()

        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.agentExpectedButMissing == true)
        #expect(instance.hostState.agentInstallNudgeDismissed == false)
        #expect(storage.saveHostStateCallCount == 1)
        #expect(storage.hostStates[instance.bundleURL]?.agentInstallNudgeDismissed == false)
    }

    @Test(
        "A watchdog whose reset cannot be saved leaves the configuration as the bundle holds it, and the surfaces show the guest version as unknown"
    )
    func watchdogWhoseResetFailsShowsTheVersionAsUnknown() async throws {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = makeMacOSInstanceWithAgentInstalled(
            in: library,
            lastSeenGuestOSVersion: "26.0", agentInstallNudgeDismissed: true)
        defer { withExtendedLifetime(library) {} }
        storage.setSaveConfigurationError(NSError(domain: "test", code: 1))
        let held = instance.settings

        instance.agentAbsenceGrace = Self.testWatchdogGrace

        instance.startAgentAbsenceWatch()

        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.agentExpectedButMissing == true)
        #expect(instance.settings == held)
        #expect(storage.bundles[instance.bundleURL] == held.configuration)
        #expect(storage.hostStates[instance.bundleURL] == held.hostState)
        #expect(instance.agentPresentation?.status == .expectedMissing(expected: "0.9.2"))
        #expect(instance.guestOSVersionDisplay == nil)
        #expect(instance.effectiveConfiguration.effectiveGuestMacOSVersion == nil)
    }

    @Test("Row 3: once the agent connected this session, its absence never warns, and nothing persisted moves")
    func watchdogPreservesPersistedStateAfterAMidSessionDeath() async throws {
        // A login agent that connected this session demonstrably exists: a
        // logout or crash is not a missing install, so nothing arms, nothing
        // warns, and neither the nudge dismissal nor the guest OS version
        // moves.
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = makeMacOSInstanceWithAgentInstalled(
            in: library, lastSeenGuestOSVersion: "26.0", agentInstallNudgeDismissed: true)
        defer { withExtendedLifetime(library) {} }

        connectSessionAgent(to: instance)
        let persistsAfterHello = storage.saveConfigurationCallCount
        let hostStatePersistsAfterHello = storage.saveHostStateCallCount

        // The agent goes away mid-session and never comes back.
        disconnectAgents(from: instance)
        instance.agentAbsenceGrace = Self.testWatchdogGrace
        instance.startAgentAbsenceWatch()
        #expect(instance.agentAbsenceTimerForTesting == nil)
        #expect(instance.agentExpectedButMissing == false)
        #expect(instance.missingAgentNoticesForTesting.isEmpty)
        #expect(instance.hostState.agentInstallNudgeDismissed == true)
        #expect(instance.configuration.lastSeenGuestOSVersion == "26.0")
        #expect(storage.saveConfigurationCallCount == persistsAfterHello)
        #expect(storage.saveHostStateCallCount == hostStatePersistsAfterHello)
    }

    // MARK: - Session peers recorded

    @Test("A session peer running the bundled payload reports the login scope arriving, each time it connects")
    func sessionPeerReportsLoginWhenCurrent() {
        let library = makeWiredLibrary()
        let instance = makeMacOSInstanceWithAgentInstalled(in: library)
        defer { withExtendedLifetime(library) {} }
        var arrivals: [Set<GuestAgentScope>] = []
        instance.onCurrentAgentsArrived = { arrivals.append($0) }

        connectSessionAgent(to: instance, handle: 1)
        disconnectAgents(from: instance)
        // What the disk was mounted for decides whether this ejects it, so a
        // reinstall of the same payload is an arrival like any other.
        connectSessionAgent(to: instance, handle: 2)

        #expect(arrivals == [[.login], [.login]])
    }

    @Test("A session peer running another payload reports no arrival")
    func sessionPeerReportsNothingWhenOutdated() {
        let library = makeWiredLibrary()
        let instance = makeMacOSInstanceWithAgentInstalled(in: library)
        defer { withExtendedLifetime(library) {} }
        var arrivals: [Set<GuestAgentScope>] = []
        instance.onCurrentAgentsArrived = { arrivals.append($0) }

        connectSessionAgent(
            to: instance, version: "0.0.1", standing: .outdated(offeredVersionLabel: "1.0 (1)", update: .updating))

        #expect(arrivals.isEmpty)
    }

    @Test("A session peer connecting cancels the watchdog and clears expected-missing, for the rest of the session")
    func sessionPeerClearsWatchdogState() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.agentAbsenceGrace = .seconds(10)
        instance.startAgentAbsenceWatch()
        #expect(instance.agentAbsenceTimerForTesting != nil)
        instance.sessionContext?.warnedAgentScopes = [.login]

        connectSessionAgent(to: instance)

        #expect(instance.agentExpectedButMissing == false)
        #expect(instance.agentAbsenceTimerForTesting == nil)
        // The agent connected this session, so nothing arms again.
        disconnectAgents(from: instance)
        instance.agentAbsenceGrace = Self.testWatchdogGrace
        instance.startAgentAbsenceWatch()
        #expect(instance.agentAbsenceTimerForTesting == nil)
    }

    @Test(
        "A session peer whose record cannot be saved leaves the configuration as the bundle holds it, and the surfaces show the reported version"
    )
    func sessionPeerWhoseRecordFailsShowsTheReportedVersion() {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = makeMacOSInstanceWithAgentInstalled(in: library, lastSeen: "0.9.0")
        defer { withExtendedLifetime(library) {} }
        storage.setSaveConfigurationError(NSError(domain: "test", code: 1))
        let held = instance.configuration

        connectSessionAgent(to: instance, version: "0.9.2")

        #expect(instance.configuration == held)
        #expect(storage.bundles[instance.bundleURL] == held)
        #expect(instance.lastSeenAgentVersion == "0.9.2")
        #expect(instance.effectiveConfiguration.lastSeenAgentVersion == "0.9.2")
    }

    // MARK: - Agent records replaced per run

    /// Lands a hub snapshot of `peers`, each `(role, version, payload hash)`, connected now.
    private func connectAgents(to instance: VMInstance, _ peers: [(PeerRole, String, Data)]) {
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(
                peers: peers.enumerated().map { index, peer in
                    PeerSummary(
                        handle: PeerHandle(rawValue: UInt64(index + 1)), role: peer.0,
                        scope: peer.0 == .systemPeer ? .system : .user, os: .macOS, sessionID: "2",
                        userName: peer.0 == .systemPeer ? "" : "pbear", console: .on, versionLabel: peer.1,
                        standing: .current, isResponsive: true, payloadHash: peer.2)
                }, features: FeatureStatus.merge([])))
    }

    /// Ends `instance`'s run as the guest stopping does, then starts its next one, its agents not yet back.
    private func runAgain(_ instance: VMInstance) {
        instance.handleSessionEvent(.guestDidStop)
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        instance.beginSessionContextForTesting().hasAgentTransport = true
        instance.publishAgentHubSnapshotForTesting(.empty)
    }

    private static let systemHash = Data(repeating: 0x5A, count: 32)

    @Test("A scope the guest stopped running warns in one run at most, then is no longer expected")
    func scopeSwitchWarnsOnce() async {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = makeMacOSInstanceWithAgentInstalled(in: library, lastSeen: "1.0")
        defer { withExtendedLifetime(library) {} }

        // The guest now runs only the install for everyone's system peer: the login agent it ran last time warns.
        connectAgents(to: instance, [(.systemPeer, "2.0", Self.systemHash)])
        instance.agentAbsenceGrace = Self.testWatchdogGrace
        instance.startAgentAbsenceWatch()
        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.warnedMissingAgents.map(\.scope) == [.login])
        #expect(instance.missingAgentNoticesForTesting.count == 1)

        // The run that saw it replaces the records: the system peer only.
        instance.handleSessionEvent(.guestDidStop)
        #expect(instance.configuration.lastSeenAgent(.login) == nil)
        #expect(
            instance.configuration.lastSeenAgent(.system)
                == GuestAgentSighting(versionLabel: "2.0", payloadHash: Self.systemHash))
        #expect(storage.bundles[instance.bundleURL]?.lastSeenAgentVersion == nil)

        // Every later run expects the system peer alone, so nothing warns again.
        for _ in 0..<2 {
            instance.activity.placeForTesting(.running(sessionID: UUID()))
            instance.beginSessionContextForTesting().hasAgentTransport = true
            connectAgents(to: instance, [(.systemPeer, "2.0", Self.systemHash)])
            instance.startAgentAbsenceWatch()
            #expect(instance.agentAbsenceTimerForTesting == nil)
            #expect(instance.warnedMissingAgents.isEmpty)
            instance.handleSessionEvent(.guestDidStop)
        }
        #expect(instance.missingAgentNoticesForTesting.count == 1)
    }

    @Test("A scope that leaves the guest during a run warns in that run only")
    func scopeLeavingDuringARunWarnsOnce() async {
        let library = makeWiredLibrary()
        let instance = makeMacOSInstanceWithAgentInstalled(in: library, lastSeen: "1.0")
        defer { withExtendedLifetime(library) {} }
        let session = (PeerRole.sessionPeer, "1.0", Self.agentHash)
        connectAgents(to: instance, [session, (.systemPeer, "1.0", Self.systemHash)])

        // The install for everyone goes, and one just for the user takes its place: the system peer never returns.
        connectAgents(to: instance, [session])
        instance.agentAbsenceGrace = Self.testWatchdogGrace
        instance.startAgentAbsenceWatch()
        await instance.agentAbsenceTimerForTesting?.value
        #expect(instance.warnedMissingAgents.map(\.scope) == [.system])

        instance.handleSessionEvent(.guestDidStop)
        #expect(instance.configuration.lastSeenAgent(.system) == nil)
        #expect(instance.configuration.lastSeenAgent(.login)?.versionLabel == "1.0")

        instance.activity.placeForTesting(.running(sessionID: UUID()))
        instance.beginSessionContextForTesting().hasAgentTransport = true
        connectAgents(to: instance, [session])
        instance.startAgentAbsenceWatch()
        #expect(instance.agentAbsenceTimerForTesting == nil)
        #expect(instance.missingAgentNoticesForTesting.count == 1)
    }

    @Test("A run that saw no agent — a boot into Recovery, a guest that never got far — keeps the records")
    func runWithoutAgentKeepsRecords() {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = makeMacOSInstanceWithAgentInstalled(in: library, lastSeen: "1.0")
        defer { withExtendedLifetime(library) {} }
        connectAgents(to: instance, [(.sessionPeer, "1.0", Self.systemHash), (.systemPeer, "1.0", Self.systemHash)])
        runAgain(instance)
        let recorded = instance.configuration
        let saves = storage.saveConfigurationCallCount
        #expect(recorded.lastSeenAgent(.login) != nil && recorded.lastSeenAgent(.system) != nil)

        // This run sees nothing.
        instance.handleSessionEvent(.guestDidStop)

        #expect(instance.configuration == recorded)
        #expect(storage.saveConfigurationCallCount == saves)
    }

    @Test("The Library's bucket and the install choice follow the scopes the last run saw")
    func bucketAndInstallChoiceFollowTheRun() async throws {
        let library = makeWiredLibrary()
        let bundled = try #require(await AppBundleProducts.testing.guestAgents.payloadHashes()[.macOS])
        try await waitForChange { library.bundledPayloadHashes[.macOS] == bundled }
        let instance = makeMacOSInstanceWithAgentInstalled(in: library, lastSeen: "1.0")
        defer { withExtendedLifetime(library) {} }
        // A login agent of an older payload last time, and both scopes on record.
        connectAgents(
            to: instance, [(.sessionPeer, "1.0", Self.systemHash), (.systemPeer, "1.0", Self.systemHash)])
        runAgain(instance)
        #expect(instance.seenAgentScopes == [.login, .system])
        #expect(library.sidebarContext.subject(of: instance).guestAgent == .olderVersion)

        // This run sees only a current system peer: the stale login record goes with it.
        connectAgents(to: instance, [(.systemPeer, "1.0", bundled)])
        runAgain(instance)

        #expect(instance.seenAgentScopes == [.system])
        #expect(LinuxAgentInstallChoice(seen: instance.seenAgentScopes) == .systemService)
        #expect(library.sidebarContext.subject(of: instance).guestAgent == .upToDate)
    }

    // MARK: - Storage disks

    @Test("bundledStorageDisks returns the internal disks and excludes externals")
    func bundledStorageDisksListInternalOnly() {
        let instance = VMInstanceFixture.make {
            $0.storageDisks = [
                StorageDisk(
                    path: "Disk.asif", readOnly: false, label: "Main", isInternal: true,
                    kind: .virtio),
                StorageDisk(
                    path: "AdditionalDisks/extra.asif", readOnly: false, label: "Extra",
                    isInternal: true, kind: .virtio
                ),
                StorageDisk(
                    path: "/Volumes/External/data.img", readOnly: false, label: "Scratch",
                    isInternal: false, kind: .virtio
                ),
            ]
        }

        let bundled = instance.bundledStorageDisks

        #expect(bundled.count == 2)
        #expect(bundled.allSatisfy { $0.isInternal })
        #expect(bundled.map(\.label) == ["Main", "Extra"])
    }

    @Test("isSoleStorageDisk is true for a VM's only disk and false for either of two")
    func isSoleStorageDiskFollowsTheCount() {
        let library = makeWiredLibrary()
        let instance = library.registerFixture()
        // A nil list resolves to the synthesized main disk alone.
        let main = instance.effectiveStorageDisks[0]
        #expect(instance.isSoleStorageDisk(main))

        let extra = StorageDisk(
            path: "AdditionalDisks/extra.asif", readOnly: false, label: "Extra",
            isInternal: true, kind: .virtio)
        library.editConfiguration(of: instance, as: .machineKeys) { $0.storageDisks = [main, extra] }
        #expect(!instance.isSoleStorageDisk(main))
        #expect(!instance.isSoleStorageDisk(extra))

        library.editConfiguration(of: instance, as: .machineKeys) { $0.storageDisks = [extra] }
        #expect(instance.isSoleStorageDisk(extra))
    }

    @Test("hasGuestAgentInstallerMounted reflects whether the bundled DMG is attached")
    func hasGuestAgentInstallerMountedReflectsState() throws {
        let installerURL = try #require(BundledGuestAgents.testing.macOSInstallerDiskImageURL)
        let library = makeWiredLibrary()
        let instance = library.registerFixture()

        #expect(!instance.hasGuestAgentInstallerMounted)

        library.editConfiguration(of: instance, as: .hotPlugMedia) {
            $0.removableMedia = [
                RemovableMediaItem(path: installerURL.path(percentEncoded: false), readOnly: true)
            ]
        }
        #expect(instance.hasGuestAgentInstallerMounted)

        // An unrelated removable item must not count as the installer.
        library.editConfiguration(of: instance, as: .hotPlugMedia) {
            $0.removableMedia = [
                RemovableMediaItem(path: "/some/other/disk.img", readOnly: false)
            ]
        }
        #expect(!instance.hasGuestAgentInstallerMounted)
    }
}
