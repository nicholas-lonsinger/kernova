import Testing
import Foundation
import AppKit
import KernovaKit
import KernovaTestSupport
@testable import Kernova

@Suite("VMInstance Tests", .admissionGated)
@MainActor
struct VMInstanceTests {
    /// Every phase that reports a status other than `.paused` — what the
    /// display-projection loops enumerate, since the paused pair is covered on
    /// its own.
    private static var nonPausedPhases: [VMLifecyclePhase] {
        [.stopped, .initialBoot, .failed(message: "Boot failed."), .running(sessionID: UUID())]
            + VMLifecyclePhaseFixtures.operations.filter { $0.status != .paused }
    }

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

    @Test("A cold-paused VM's suspend slot is captured as a suspended-mode snapshot")
    func coldPausedTakesASuspendedSnapshot() throws {
        let instance = VMInstanceFixture.make(phase: .suspended)
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        FileManager.default.createFile(
            atPath: instance.bundleLayout.saveFileURL.path(percentEncoded: false),
            contents: Data("fake save".utf8))

        #expect(instance.snapshotCaptureMode == .suspended)
    }

    @Test(
        "A cold-paused VM with no suspend slot cannot be captured — a dead end a failed snapshot attempt can leave it in"
    )
    func coldPausedWithNoSaveFileCannotBeCaptured() {
        let instance = VMInstanceFixture.make(phase: .suspended)
        #expect(instance.isColdPaused)
        #expect(!instance.hasSaveFile)

        #expect(instance.snapshotCaptureMode == nil)
    }

    @Test("The capture mode follows what the VM has to capture, and decides the stamped kind")
    func snapshotModeFollowsLiveness() {
        for phase in [VMLifecyclePhase.running(sessionID: UUID()), .livePaused(sessionID: UUID())] {
            #expect(VMInstanceFixture.make(phase: phase).snapshotCaptureMode == .live, "phase \(phase)")
        }
        #expect(VMInstanceFixture.make(phase: .stopped).snapshotCaptureMode == .stopped)
        #expect(VMSnapshotCaptureMode.live.kind == .warm)
        #expect(VMSnapshotCaptureMode.suspended.kind == .warm)
        #expect(VMSnapshotCaptureMode.stopped.kind == .cold)
    }

    @Test("A revert needs a snapshot to go back to")
    func revertNeedsASnapshot() {
        let instance = VMInstanceFixture.make(phase: .stopped)
        #expect(!instance.activity.admits(Self.revert))

        instance.seedSnapshotManifest(Self.oneSnapshot)
        #expect(instance.activity.admits(Self.revert))
    }

    @Test("A running VM can be reverted — the revert discards the live session")
    func runningVMCanBeReverted() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        instance.seedSnapshotManifest(Self.oneSnapshot)
        #expect(instance.activity.admits(Self.revert))
    }

    // MARK: - detailPaneMode

    @Test("detailPaneMode defaults to .display on a new instance")
    func detailPaneModeDefaultsToDisplay() {
        let instance = VMInstanceFixture.make()
        #expect(instance.detailPaneMode == .display)
    }

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

    @Test("A session's end releases the whole session context and rests on the slot that survived it")
    func sessionEndReleasesTheContext() throws {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        defer { VMInstanceFixture.removeBundle(of: instance) }
        let context = instance.beginSessionContextForTesting()
        context.serialInputPipe = Pipe()
        context.serialOutputPipe = Pipe()
        try VMInstanceFixture.writeSaveFile(for: instance)

        instance.handleSessionEvent(.guestDidStop)

        #expect(instance.phase == .suspended)
        #expect(instance.liveSessionID == nil)
        #expect(instance.sessionContext == nil)
        #expect(instance.session == nil)
        // The released context is drained too, so nothing a stale reference
        // still holds keeps a file handle or a service alive.
        #expect(context.serialInputPipe == nil)
        #expect(context.serialOutputPipe == nil)
    }

    @Test("A session's end resets a hidden (headless) displayMode to inline")
    func sessionEndResetsHiddenDisplayMode() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        instance.displayMode = .hidden

        instance.handleSessionEvent(.guestDidStop)

        #expect(instance.displayMode == .inline)
    }

    @Test("A second session end changes nothing")
    func sessionEndIdempotent() {
        let instance = VMInstanceFixture.make(phase: .livePaused(sessionID: UUID()))
        instance.handleSessionEvent(.guestDidStop)
        instance.handleSessionEvent(.guestDidStop)

        #expect(instance.status == .stopped)
        #expect(instance.sessionContext == nil)
        #expect(instance.session == nil)
    }

    @Test("A power-off sets status to stopped and clears the session")
    func powerOffRestsStopped() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        #expect(instance.status == .running)

        instance.handleSessionEvent(.guestDidStop)

        #expect(instance.status == .stopped)
        #expect(instance.session == nil)
    }

    @Test("A power-off event on a stopped VM changes nothing")
    func powerOffIdempotentWhenStopped() {
        let instance = VMInstanceFixture.make(phase: .stopped)
        instance.handleSessionEvent(.guestDidStop)
        #expect(instance.status == .stopped)
        #expect(instance.session == nil)
    }

    // MARK: - The suspend slot

    @Test("A suspend slot only counts while nothing is live")
    func holdsSuspendedSessionNeedsAnAtRestPhase() throws {
        let instance = VMInstanceFixture.make(phase: .suspended)
        defer { VMInstanceFixture.removeBundle(of: instance) }
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

    @Test("Discarding the saved state takes the file and the suspension together")
    func discardSavedStateRestsTheVMStopped() throws {
        let instance = VMInstanceFixture.make(phase: .suspended)
        defer { VMInstanceFixture.removeBundle(of: instance) }
        try VMInstanceFixture.writeSaveFile(for: instance)

        try makeTestLifecycle().discardSavedState(instance)

        #expect(!instance.hasSaveFile)
        #expect(instance.phase == .stopped)
        #expect(instance.activity.admits(.edit(.machineKeys)))
        #expect(!instance.activity.admits(.resume))
    }

    /// The operation's own body decides where it rests — a save drops the slot
    /// the guest's end left half-written — so the event only tells it.
    @Test("A guest that dies during an operation leaves the operation holding the VM")
    func didStopWithErrorDuringAnOperationKeepsIt() throws {
        let sessionID = UUID()
        let live = VMLifecyclePhase.running(sessionID: sessionID)
        let error = NSError(domain: "test", code: 1)
        for phase: VMLifecyclePhase in [
            .operating(.saving, from: live),
            .operating(.bringUp(.guestStart(.restoringSavedState)), from: .suspended, boundSession: sessionID),
        ] {
            let instance = VMInstanceFixture.make(phase: phase)
            defer { VMInstanceFixture.removeBundle(of: instance) }
            try VMInstanceFixture.writeSaveFile(for: instance)

            instance.handleSessionEvent(.didStopWithError(error))

            #expect(instance.phase.operation?.kind == phase.operation?.kind, "\(phase)")
            #expect(instance.phase.operation?.session == nil, "\(phase)")
            #expect(
                instance.phase.operation?.sessionEnd
                    == .stoppedWithError(message: error.localizedDescription), "\(phase)")
            #expect(instance.hasSaveFile, "\(phase)")
        }
    }

    /// VZ consumes the slot only once a restore has resumed, so a guest that
    /// died still has the session on disk — and a VM holding one is resumable,
    /// not stuck, whatever ended the session.
    @Test("A guest that dies over a kept slot rests the VM back on its saved state")
    func didStopWithErrorOverAKeptSlotRestsSuspended() throws {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        defer { VMInstanceFixture.removeBundle(of: instance) }
        try VMInstanceFixture.writeSaveFile(for: instance)

        instance.handleSessionEvent(.didStopWithError(NSError(domain: "test", code: 1)))

        #expect(instance.phase == .suspended)
        #expect(instance.hasSaveFile)
        // No banner: the VM is one the user can bring back up.
        #expect(instance.errorMessage == nil)
    }

    @Test("A guest that dies with no slot to come back on rests at the failure")
    func didStopWithErrorWithoutASlotRestsFailed() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))

        instance.handleSessionEvent(
            .didStopWithError(
                NSError(
                    domain: "test", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The guest panicked."])))

        #expect(instance.status == .error)
        #expect(instance.errorMessage == "The guest panicked.")
    }

    @Test("A power-off rests the VM on a slot that survived it, and stopped otherwise")
    func powerOffReadsTheBundle() throws {
        let holding = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        defer { VMInstanceFixture.removeBundle(of: holding) }
        try VMInstanceFixture.writeSaveFile(for: holding)

        holding.handleSessionEvent(.guestDidStop)

        #expect(holding.phase == .suspended)
        #expect(holding.hasSaveFile)

        let emptied = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        emptied.handleSessionEvent(.guestDidStop)
        #expect(emptied.phase == .stopped)
    }

    @Test("A VM answers admission as it will stand once its saved state is discarded")
    func decideAsIfSavedStateDiscardedLiftsOnlyThatTerm() throws {
        let instance = VMInstanceFixture.make(phase: .suspended)
        defer { VMInstanceFixture.removeBundle(of: instance) }
        try VMInstanceFixture.writeSaveFile(for: instance)
        let edit = VMAdmission.Request.edit(.machineKeys)

        #expect(!instance.activity.admits(edit))
        #expect(instance.activity.decideAsIfSavedStateDiscarded(edit, posture: .commit) == .admit)
        // The file is untouched, and the answer goes on reading it.
        #expect(instance.hasSaveFile)
        #expect(!instance.activity.admits(edit))

        // Only that term is lifted: a VM no phase admits the edit in stays
        // refused.
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        #expect(instance.activity.decideAsIfSavedStateDiscarded(edit, posture: .commit) != .admit)
    }

    // MARK: - isColdPaused

    @Test("isColdPaused is true when paused with no live session")
    func isColdPausedTrue() {
        let instance = VMInstanceFixture.make(phase: .suspended)
        #expect(instance.session == nil)
        #expect(instance.isColdPaused == true)
    }

    @Test("isColdPaused is false when stopped")
    func isColdPausedFalseWhenStopped() {
        let instance = VMInstanceFixture.make(phase: .stopped)
        #expect(instance.isColdPaused == false)
    }

    @Test("isColdPaused is false when running")
    func isColdPausedFalseWhenRunning() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        #expect(instance.isColdPaused == false)
    }

    // MARK: - hasLiveSession

    @Test(
        "hasLiveSession is true for a running or live-paused VM",
        arguments: [VMLifecyclePhase.running(sessionID: UUID()), .livePaused(sessionID: UUID())])
    func hasLiveSessionWithLiveVM(phase: VMLifecyclePhase) {
        #expect(VMInstanceFixture.make(phase: phase).hasLiveSession == true)
    }

    @Test(
        "hasLiveSession is false without a live virtual machine",
        arguments: [
            VMLifecyclePhase.suspended, .stopped, .failed(message: "Boot failed."), .initialBoot,
        ])
    func hasLiveSessionWithoutLiveVM(phase: VMLifecyclePhase) {
        #expect(VMInstanceFixture.make(phase: phase).hasLiveSession == false)
    }

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

    @Test("effectiveMachineIdentifierData prefers the configuration field")
    func effectiveMachineIDPrefersConfiguration() {
        let instance = VMInstanceFixture.make { $0.machineIdentifierData = Data([1, 2, 3]) }
        #expect(instance.effectiveMachineIdentifierData == Data([1, 2, 3]))
    }

    @Test("effectiveMachineIdentifierData falls back to the bundle's identifier file")
    func effectiveMachineIDFallsBackToFile() throws {
        let instance = VMInstanceFixture.make()
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }
        try Data([4, 5, 6]).write(to: instance.machineIdentifierURL)

        #expect(instance.configuration.machineIdentifierData == nil)
        #expect(instance.effectiveMachineIdentifierData == Data([4, 5, 6]))
    }

    @Test("effectiveMachineIdentifierData is nil with neither a configuration field nor a file")
    func effectiveMachineIDNilWhenAbsent() {
        let instance = VMInstanceFixture.make()
        #expect(instance.effectiveMachineIdentifierData == nil)
    }

    // MARK: - isKeepingAppAlive

    @Test("isKeepingAppAlive is true for active statuses")
    func isKeepingAppAliveActive() {
        for phase in [VMLifecyclePhase.running(sessionID: UUID())] + VMLifecyclePhaseFixtures.operations {
            let instance = VMInstanceFixture.make(phase: phase)
            #expect(instance.isKeepingAppAlive == true, "\(phase)")
        }
    }

    @Test("isKeepingAppAlive is false when cold-paused")
    func isKeepingAppAliveColdPaused() {
        let instance = VMInstanceFixture.make(phase: .suspended)
        #expect(instance.session == nil)
        #expect(instance.isKeepingAppAlive == false)
    }

    @Test("isKeepingAppAlive is false when stopped or error")
    func isKeepingAppAliveStoppedOrError() {
        for phase in [VMLifecyclePhase.stopped, .failed(message: "Boot failed.")] {
            let instance = VMInstanceFixture.make(phase: phase)
            #expect(instance.isKeepingAppAlive == false)
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

    @Test("A power-off clears serial pipes")
    func powerOffClearsSerialPipes() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        let context = instance.beginSessionContextForTesting()
        context.serialInputPipe = Pipe()
        context.serialOutputPipe = Pipe()

        instance.handleSessionEvent(.guestDidStop)

        #expect(instance.sessionContext == nil)
        #expect(context.serialInputPipe == nil)
        #expect(context.serialOutputPipe == nil)
        #expect(instance.status == .stopped)
    }

    @Test("serialLogURL is forwarded from bundleLayout")
    func serialLogURL() {
        let instance = VMInstanceFixture.make()
        #expect(instance.serialLogURL.lastPathComponent == "serial.log")
    }

    // MARK: - Status Display Properties

    @Test("statusDisplayName returns Suspended when cold-paused")
    func statusDisplayNameColdPaused() {
        let instance = VMInstanceFixture.make(phase: .suspended)
        #expect(instance.isColdPaused == true)
        #expect(instance.statusDisplayName == "Suspended")
    }

    @Test("statusDisplayName delegates to status.displayName for non-paused states")
    func statusDisplayNameDelegates() {
        for phase in Self.nonPausedPhases {
            #expect(VMInstanceFixture.make(phase: phase).statusDisplayName == phase.status.displayName)
        }
    }

    @Test("statusDisplayNSColor returns systemOrange when cold-paused")
    func statusDisplayNSColorColdPaused() {
        let instance = VMInstanceFixture.make(phase: .suspended)
        #expect(instance.isColdPaused == true)
        #expect(instance.statusDisplayNSColor == .systemOrange)
    }

    @Test("statusDisplayNSColor maps non-paused states")
    func statusDisplayNSColorByStatus() {
        // Concrete gray (not `.secondaryLabelColor`) so the OS icon keeps its
        // stopped color on the selection highlight instead of inverting to white.
        #expect(VMInstanceFixture.make(phase: .stopped).statusDisplayNSColor == .systemGray)
        #expect(VMInstanceFixture.make(phase: .running(sessionID: UUID())).statusDisplayNSColor == .systemGreen)
        #expect(
            VMInstanceFixture.make(phase: .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped))
                .statusDisplayNSColor == .systemOrange)
        #expect(VMInstanceFixture.make(phase: .failed(message: "Boot failed.")).statusDisplayNSColor == .systemRed)
    }

    @Test("statusToolTip mentions disk when cold-paused")
    func statusToolTipColdPaused() {
        let instance = VMInstanceFixture.make(phase: .suspended)
        #expect(instance.isColdPaused == true)
        let tip = instance.statusToolTip
        #expect(tip != nil)
        #expect(tip!.contains("disk"))
    }

    @Test("statusToolTip returns nil for every phase but the two that carry one")
    func statusToolTipNilForNonPaused() {
        // Suspended names the disk its state is on, a failure names its
        // message, and an unbooted VM names the install Start runs.
        for phase in Self.nonPausedPhases
        where phase.status != .error && phase != .initialBoot {
            #expect(VMInstanceFixture.make(phase: phase).statusToolTip == nil, "\(phase)")
        }
    }

    @Test("statusToolTip carries the stored message in the error state")
    func statusToolTipError() {
        let instance = VMInstanceFixture.make(phase: .failed(message: "The virtual machine failed to start."))
        #expect(instance.statusToolTip == "The virtual machine failed to start.")
    }

    // MARK: - Network Attachment Recovery

    @Test("A running VM awaiting network reattach shows the warning tint and says why")
    func networkPendingShowsWarningTintAndToolTip() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        let library = makeWiredLibrary(holding: [instance])
        instance.beginSessionContextForTesting().networkAttachmentPending = true

        #expect(instance.statusDisplayNSColor == StatusColor.warning)
        // The wording names what is actually unavailable: the app-managed
        // network for Shared and Host Only, a host interface for Bridged.
        library.editConfiguration(of: instance) { $0.networkMode = .shared }
        #expect(
            instance.statusToolTip
                == "The Shared Network is unavailable. Kernova reconnects automatically.")
        library.editConfiguration(of: instance) { $0.networkMode = .hostOnly }
        #expect(
            instance.statusToolTip
                == "The Host Only network is unavailable. Kernova reconnects automatically.")
        library.editConfiguration(of: instance) { $0.networkMode = .bridged }
        #expect(instance.statusToolTip?.contains("network interface") == true)
    }

    @Test("applyLivePolicy forwards a network mode change to the coordinator")
    func applyLivePolicyForwardsNetworkChange() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID())) {
            $0.networkEnabled = true
            $0.networkMode = .shared
        }
        let library = makeWiredLibrary(holding: [instance])
        let device = MockNetworkDeviceControl(plan: .nat)
        let coordinator = attachNetworkCoordinator(
            to: instance, device: device,
            provider: MockBridgedInterfaceProvider(
                available: [BridgedInterface(identifier: "en0", localizedDisplayName: "Wi-Fi")]))
        coordinator.activate()
        #expect(device.appliedPlans.isEmpty)

        library.editConfiguration(of: instance) {
            $0.networkMode = .bridged
            $0.bridgedInterfaceIdentifier = "en0"
        }

        #expect(device.appliedPlans == [.bridged("en0")])
    }

    @Test("applyLivePolicy ignores a network change while the VM is stopped")
    func applyLivePolicyIgnoresNetworkChangeWhileStopped() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID())) {
            $0.networkEnabled = true
            $0.networkMode = .shared
        }
        let library = makeWiredLibrary(holding: [instance])
        let device = MockNetworkDeviceControl()
        let coordinator = attachNetworkCoordinator(to: instance, device: device)
        coordinator.activate()
        #expect(device.appliedPlans == [.nat])
        instance.activity.placeForTesting(.stopped)

        library.editConfiguration(of: instance) { $0.networkMode = .bridged }

        #expect(device.appliedPlans == [.nat])
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
        #expect(!context.networkAttachmentPending)
        #expect(!observer.isObserving)
    }

    // MARK: - Lifecycle Action Labels

    @Test("startAction is .start without a pending install context")
    func startActionDefault() {
        let instance = VMInstanceFixture.make(phase: .stopped)
        #expect(instance.startAction == .start)
        #expect(instance.startAction.label == "Start")
    }

    @Test("startAction is .install with a pending install context and no resumable download")
    func startActionInstall() {
        let instance = VMInstanceFixture.make(phase: .stopped) {
            $0.installContext = MacOSInstallContext(source: .downloadLatest)
        }
        #expect(instance.hasResumableInstallDownload == false)
        #expect(instance.startAction == .install)
        #expect(instance.startAction.label == "Install")
    }

    /// Builds a stopped VM with an install context whose download destination has
    /// a sibling `.kernovadownload` bundle seeded on disk.
    ///
    /// `partialBytes` is what the bundle's `data` file holds: pass `nil` for the
    /// husk a finalize leaves when its disposal fails (directory and metadata
    /// present, `data` already moved to the destination). Returns the temp
    /// directory so the caller can clean it up.
    private func makeInstanceWithSeededDownloadBundle(
        partialBytes: Data?,
        source: MacOSInstallContext.Source = .downloadLatest
    ) throws -> (instance: VMInstance, temp: URL) {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMInstanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)

        let destination = temp.appendingPathComponent("RestoreImage.ipsw")
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
        return (instance, temp)
    }

    @Test("startAction is .install when the bundle is a data-less husk")
    func startActionInstallWithHuskBundle() throws {
        // A finalize whose disposal failed leaves the bundle directory (and its
        // metadata) behind with `data` already moved to the destination. It has
        // no bytes to resume from, so it must not offer "Resume Install".
        let (instance, temp) = try makeInstanceWithSeededDownloadBundle(partialBytes: nil)
        defer { try? FileManager.default.removeItem(at: temp) }

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
        let (instance, temp) = try makeInstanceWithSeededDownloadBundle(
            partialBytes: Data(repeating: 0x11, count: 1024),
            source: source
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        #expect(instance.hasResumableInstallDownload == true)
        #expect(instance.startAction == .resumeInstall)
        #expect(instance.startAction.label == "Resume Install")
    }

    @Test("startAction is .install for a local-file install beside a partial bundle")
    func startActionInstallForLocalFileSource() throws {
        // A local-file install never downloads, so a bundle left at the same
        // path by an earlier attempt says nothing about what Start will do.
        let (instance, temp) = try makeInstanceWithSeededDownloadBundle(
            partialBytes: Data(repeating: 0x11, count: 1024),
            source: .localFile
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        #expect(instance.hasResumableInstallDownload == false)
        #expect(instance.startAction == .install)
    }

    @Test("startAction is .download with a pending Linux image and nothing partial on disk")
    func startActionDownload() {
        let instance = VMInstanceFixture.make(phase: .stopped) {
            $0.linuxInstallContext = LinuxInstallContext(
                source: .catalogEntry(makeLinuxCatalogEntry()))
        }

        // No destination until the mirror is asked, which is exactly when there
        // is nothing to resume from.
        #expect(instance.hasResumableInstallDownload == false)
        #expect(instance.startAction == .download)
        #expect(instance.startAction.label == "Download")
    }

    @Test("startAction is .resumeDownload when a Linux image's bundle holds partial bytes")
    func startActionResumeDownload() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMInstanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let destination = temp.appendingPathComponent("debian-13.6.0-arm64-netinst.iso")
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

    @Test("The stop labels name the discard consequence when the stop discards")
    func stopActionTitlesNameTheDiscard() {
        #expect(VMInstance.StopAction.discardSavedState.menuTitle == "Discard Saved State…")
        #expect(VMInstance.StopAction.discardSavedState.toolbarLabel == "Discard Saved State")
    }

    @Test("The stop labels are Stop for a stop that shuts the guest down")
    func stopActionTitlesDefault() {
        #expect(VMInstance.StopAction.stop.menuTitle == "Stop")
        #expect(VMInstance.StopAction.stop.toolbarLabel == "Stop")
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
    ) throws -> (
        instance: VMInstance, baseline: VMSnapshot, temp: URL
    ) {
        let baseline = VMSnapshot(name: "Ephemeral", macAddress: nil)
        let instance = VMInstanceFixture.make(
            name: "Ephemeral VM", phase: .suspended,
            hostState: ephemeralModeEnabled ? .ephemeral(baseline: baseline.id) : VMHostState())
        let temp = instance.bundleURL
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [baseline]))

        let snapshotLayout = instance.bundleLayout.snapshotLayout(id: baseline.id)
        try FileManager.default.createDirectory(
            at: snapshotLayout.bundleURL, withIntermediateDirectories: true)
        try Data("captured".utf8).write(to: snapshotLayout.saveFileURL)
        return (instance, baseline, temp)
    }

    @Test("A suspended Ephemeral VM holding the baseline's own saved state rests at it")
    func restingAtEphemeralBaseline() throws {
        let (instance, baseline, temp) = try makeEphemeralInstanceWithBundle()
        defer { try? FileManager.default.removeItem(at: temp) }
        let captured = instance.bundleLayout.snapshotLayout(id: baseline.id).saveFileURL

        try FileManager.default.copyItem(at: captured, to: instance.bundleLayout.saveFileURL)
        #expect(instance.isRestingAtEphemeralBaseline)
    }

    @Test("A suspend of its own leaves an Ephemeral VM away from its baseline")
    func ownSuspendIsNotTheEphemeralBaseline() throws {
        let (instance, _, temp) = try makeEphemeralInstanceWithBundle()
        defer { try? FileManager.default.removeItem(at: temp) }

        try Data("captured".utf8).write(to: instance.bundleLayout.saveFileURL)
        #expect(!instance.isRestingAtEphemeralBaseline)
    }

    @Test("A VM that is not suspended never reads as resting at its baseline")
    func restingAtBaselineNeedsASuspendedVM() throws {
        let (instance, baseline, temp) = try makeEphemeralInstanceWithBundle()
        defer { try? FileManager.default.removeItem(at: temp) }
        let captured = instance.bundleLayout.snapshotLayout(id: baseline.id).saveFileURL
        try FileManager.default.copyItem(at: captured, to: instance.bundleLayout.saveFileURL)

        instance.activity.placeForTesting(.running(sessionID: UUID()))
        #expect(!instance.isRestingAtEphemeralBaseline)
    }

    @Test("Ephemeral Mode off leaves the baseline comparison unasked")
    func restingAtBaselineNeedsEphemeralMode() throws {
        let (instance, baseline, temp) = try makeEphemeralInstanceWithBundle(ephemeralModeEnabled: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        let captured = instance.bundleLayout.snapshotLayout(id: baseline.id).saveFileURL
        try FileManager.default.copyItem(at: captured, to: instance.bundleLayout.saveFileURL)

        #expect(!instance.isRestingAtEphemeralBaseline)
    }

    // MARK: - Arrival labels

    @Test("An arrival's label names its operation")
    func arrivalLabelNamesItsOperation() {
        #expect(VMArrival.Kind.creating.displayLabel == "Creating\u{2026}")
        #expect(VMArrival.Kind.cloning(sourceID: UUID()).displayLabel == "Cloning\u{2026}")
        #expect(VMArrival.Kind.importing.displayLabel == "Importing\u{2026}")
    }

    @Test("An arrival reads Cancelling… once a cancel is taken")
    func arrivalLabelReadsCancellingOnceCancelled() {
        let configuration = VMConfiguration(name: "Copy", guestOS: .linux, bootMode: .efi)
        let arrival = VMArrival(
            id: configuration.id, kind: .importing, configuration: configuration,
            destinationURL: VMInstanceFixture.bundleURL(for: configuration.id)
        ) { _ in throw CancellationError() }
        #expect(arrival.displayLabel == "Importing\u{2026}")

        #expect(arrival.requestCancel() == .cancelled)

        #expect(arrival.displayLabel == "Cancelling\u{2026}")
    }

    @Test("Arrival kind cancelLabel and cancelAlertTitle")
    func arrivalKindCancelLabels() {
        #expect(VMArrival.Kind.cloning(sourceID: UUID()).cancelLabel == "Cancel Clone")
        #expect(VMArrival.Kind.cloning(sourceID: UUID()).cancelAlertTitle == "Cancel Clone?")
        #expect(VMArrival.Kind.importing.cancelLabel == "Cancel Import")
        #expect(VMArrival.Kind.importing.cancelAlertTitle == "Cancel Import?")
    }

    @Test("Arrival kind displayNoun")
    func arrivalKindDisplayNoun() {
        #expect(VMArrival.Kind.cloning(sourceID: UUID()).displayNoun == "Clone")
        #expect(VMArrival.Kind.importing.displayNoun == "Import")
    }

    // MARK: - agentStatus dispatch
    //
    // `VMInstance.agentStatus` is the single read site for the UI; it must
    // dispatch by `configuration.guestOS`:
    //   - macOS guests source it from `vsockControlService` (the always-on
    //     control channel, independent of clipboard sharing).
    //   - Linux guests source it from `clipboardService` cast to
    //     `SpiceClipboardService` (`spice-vdagent` is user-installed; only
    //     `.waiting` / `.current` are reachable).
    //
    // These tests lock in the switch so a future refactor can't accidentally
    // fall through to the wrong service per OS.

    @Test("agentStatus is .waiting on a macOS instance with no control service set")
    func agentStatusMacOSDefaultsToWaiting() {
        let instance = VMInstanceFixture.make(guestOS: .macOS)
        #expect(instance.vsockControlService == nil)
        #expect(instance.agentStatus == .waiting)
    }

    @Test("agentStatus is .waiting on a Linux instance with no clipboard service set")
    func agentStatusLinuxDefaultsToWaiting() {
        let instance = VMInstanceFixture.make(guestOS: .linux)
        #expect(instance.clipboardService == nil)
        #expect(instance.agentStatus == .waiting)
    }

    @Test("agentStatus on macOS does NOT fall through to clipboardService — control is the only source")
    func agentStatusMacOSIgnoresClipboardService() {
        // Set a SpiceClipboardService on a macOS instance — an obvious
        // misconfiguration the dispatch shouldn't dignify. macOS should still
        // report `.waiting` because vsockControlService is nil; if dispatch
        // accidentally fell through to clipboardService, this would surface
        // the SPICE service's own `.waiting` (same value, but for the wrong
        // reason — and `.current` if the SPICE service were connected).
        let instance = VMInstanceFixture.make(guestOS: .macOS)
        instance.beginSessionContextForTesting().clipboardService = SpiceClipboardService(
            inputPipe: Pipe(),
            outputPipe: Pipe()
        )
        #expect(instance.vsockControlService == nil)
        #expect(instance.agentStatus == .waiting)
    }

    @Test("agentStatus on Linux dispatches to clipboardService cast as SpiceClipboardService")
    func agentStatusLinuxDispatchesToSpice() {
        let instance = VMInstanceFixture.make(guestOS: .linux)
        let spice = SpiceClipboardService(inputPipe: Pipe(), outputPipe: Pipe())
        instance.beginSessionContextForTesting().clipboardService = spice
        // Newly-constructed SPICE service is `.waiting` (no handshake yet) —
        // dispatch returns that same value, proving the cast + access path runs.
        #expect(spice.agentStatus == .waiting)
        #expect(instance.agentStatus == .waiting)
    }

    // MARK: - An operation's ending

    /// The wedge this rules out: a VM resting live over no session offers
    /// neither Stop, Force Stop nor Start.
    @Test("An operation that ends live over a session that went away rests where that end says")
    func endingLiveOverAnEndedSessionRestsAtItsEnd() async throws {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))

        try await instance.activity.perform(.pausing) { _ in
            instance.handleSessionEvent(
                .didStopWithError(
                    NSError(
                        domain: "test", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The guest stopped unexpectedly."])))
            return .rest(.live(.paused), ())
        }

        #expect(instance.errorMessage == "The guest stopped unexpectedly.")
        #expect(!instance.hasLiveVirtualMachine)
        #expect(instance.activity.admits(.start(recovery: false)))
    }

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
        defer {
            instance.cancelAgentPostStartWatchdog()
            VMInstanceFixture.removeBundle(of: instance)
        }
        if row.slot { try VMInstanceFixture.writeSaveFile(for: instance) }
        let observer = MockNetworkLinkObserver()

        switch row.kind {
        case .bringUp(let kind):
            try await instance.activity.bringUp(kind) { context in
                // A revert ends the session it started from before it brings
                // the snapshot up.
                context.operation.endSession()
                instance.beginSessionContext(context)
                attachNetworkCoordinator(
                    to: instance, device: MockNetworkDeviceControl(), linkObserver: observer)
                context.bindSessionForTesting(UUID())
                return .rest(.live(.running), ())
            }
        default:
            instance.beginSessionContextForTesting()
            attachNetworkCoordinator(
                to: instance, device: MockNetworkDeviceControl(), linkObserver: observer)
            try await instance.activity.perform(row.kind) { _ in .rest(.live(.running), ()) }
        }

        #expect(instance.status == .running)
        #expect(observer.isObserving == row.activatesNetwork)
        #expect((instance.agentPostStartTaskForTesting != nil) == row.armsWatchdog)
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

    @Test("guestDidStop resets the instance to stopped")
    func guestDidStopEventResets() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting().serialInputPipe = Pipe()
        instance.handleSessionEvent(.guestDidStop)
        #expect(instance.status == .stopped)
        #expect(instance.sessionContext == nil)
    }

    @Test("didStopWithError tears the session down and records the error")
    func didStopWithErrorEventRecordsError() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting().serialInputPipe = Pipe()
        let failure = NSError(
            domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        instance.handleSessionEvent(.didStopWithError(failure))
        #expect(instance.status == .error)
        #expect(instance.errorMessage == "boom")
        #expect(instance.sessionContext == nil)
    }

    @Test("networkAttachmentDisconnected forwards to the recovery coordinator")
    func networkDisconnectedEventForwardsToCoordinator() {
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID())) {
            $0.networkEnabled = true
            $0.networkMode = .shared
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

    // MARK: - Agent Post-Start Watchdog
    //
    // The watchdog flips `agentExpectedButMissing` after a grace period when:
    //   - The guest is macOS,
    //   - The VM is `.running` (a frozen guest can't answer),
    //   - `lastSeenAgentVersion` is set (so we have a baseline expectation),
    //   - No agent is connected on the control channel already,
    //   - No `setupState` is in progress, and
    //   - No Hello arrives during the grace window.
    // Tests inject a millisecond-scale grace so the suite stays fast.

    /// Builds a macOS VMInstance with a known `lastSeenAgentVersion` and an
    /// open session context — the watchdog is session state, so it arms into
    /// one or not at all.
    ///
    /// The caller is responsible for explicitly clearing the watchdog if needed
    /// across tests.
    private func makeMacOSInstanceWithAgentInstalled(
        lastSeen: String = "0.9.2",
        lastSeenGuestOSVersion: String? = nil,
        setupState: GuestSetupState? = nil,
        bootedIntoRecovery: Bool = false,
        agentInstallNudgeDismissed: Bool = false
    ) -> VMInstance {
        let instance = VMInstanceFixture.make(
            name: "macOS Watchdog Test", guestOS: .macOS, phase: .running(sessionID: UUID()),
            hostState: VMHostState(agentInstallNudgeDismissed: agentInstallNudgeDismissed)
        ) {
            $0.lastSeenAgentVersion = lastSeen
            $0.lastSeenGuestOSVersion = lastSeenGuestOSVersion
        }
        instance.setupState = setupState
        instance.beginSessionContextForTesting(bootedIntoRecovery: bootedIntoRecovery)
        return instance
    }

    /// Guest-side `Hello` for tests that drive a real `VsockControlService`.
    private func makeGuestHelloFrame(agentVersion: String) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = KernovaCapability.controlChannelDefaults
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = "26.0"
                $0.agentVersion = agentVersion
            }
        }
        return frame
    }

    // Sized past GitHub Actions MainActor jitter, which far exceeds local
    // hardware.
    private static let testWatchdogGrace: Duration = .milliseconds(200)

    @Test("Watchdog flips agentExpectedButMissing when no Hello arrives in the grace window")
    func watchdogFiresWhenSilent() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)

        // Await the watchdog task itself rather than polling the flag: the task
        // completes exactly when the grace elapses and flips the flag, so there
        // is no wall-clock deadline to lose under CI MainActor contention.
        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentExpectedButMissing == true)
        #expect(instance.agentStatus == .expectedMissing(expected: "0.9.2"))
    }

    @Test("Cancelling the watchdog before grace prevents firing")
    func watchdogCancelledStaysQuiet() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.startAgentPostStartWatchdog(grace: .seconds(5))

        // Cancel well before the grace elapses — the timer task must not
        // flip the flag after cancellation. Use a comfortably long
        // settle window (5× the grace would be 1 s, but 5× of *what we
        // expect* doesn't help here; we just need to outlast scheduler
        // jitter on a cancelled task that should never fire).
        instance.cancelAgentPostStartWatchdog()
        try await Task.sleep(for: .milliseconds(500))
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test("Watchdog is a no-op when lastSeenAgentVersion is nil")
    func watchdogNoopWithoutPersistedVersion() async throws {
        // Fresh macOS VM, no prior agent — the .waiting nudge stays the
        // appropriate signal, the louder "didn't reconnect" badge would be
        // misleading.
        let instance = VMInstanceFixture.make(
            name: "Fresh macOS", guestOS: .macOS, phase: .running(sessionID: UUID()))
        instance.beginSessionContextForTesting()

        // Wait noticeably past the grace so a broken guard would have a
        // real chance to mis-fire. 3× grace is plenty.
        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        try await Task.sleep(for: Self.testWatchdogGrace * 3)
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test("Watchdog is a no-op for Linux guests")
    func watchdogNoopForLinux() async throws {
        // Linux uses spice-vdagent, which the host doesn't fingerprint —
        // the watchdog has no business firing here.
        let instance = VMInstanceFixture.make(
            name: "Linux VM", phase: .running(sessionID: UUID())
        ) { $0.lastSeenAgentVersion = "should-be-ignored" }
        instance.beginSessionContextForTesting()

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        try await Task.sleep(for: Self.testWatchdogGrace * 3)
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test("Watchdog is a no-op for the whole of a recovery-booted session")
    func watchdogNoopAfterRecoveryBoot() async throws {
        // Recovery never runs the agent, so its silence proves nothing — the
        // "didn't reconnect" badge would be false and clearing the stored guest
        // OS version would erase a value that is not in doubt. Session state,
        // not a per-call flag: a pause/resume inside a Recovery session reaches
        // the same arm site with no idea a Recovery boot happened.
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)",
            bootedIntoRecovery: true)

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        try await Task.sleep(for: Self.testWatchdogGrace * 3)
        #expect(instance.agentExpectedButMissing == false)
        #expect(instance.configuration.lastSeenGuestOSVersion == "Version 26.0 (Build 25A123)")
        #expect(instance.hostState.agentInstallNudgeDismissed == false)
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
    func watchdogNoopDuringMacOSInstall() async throws {
        // No agent exists during install; no point arming the watchdog.
        let setupState = GuestSetupState.macOSInstall(hasDownloadStep: true)
        let instance = makeMacOSInstanceWithAgentInstalled(setupState: setupState)

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        try await Task.sleep(for: Self.testWatchdogGrace * 3)
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test(
        "Watchdog is a no-op unless the VM is running",
        arguments: [
            PhaseFixture.settled(.livePaused(sessionID: UUID())),
            .operating(.saving, from: .running(sessionID: UUID())),
            .operating(.bringUp(.guestStart(.restoringSavedState)), from: .suspended, boundSession: UUID()),
            .settled(.stopped),
        ])
    func watchdogNoopUnlessRunning(phase fixture: PhaseFixture) async throws {
        // A live-paused guest is frozen: it cannot say Hello, so a grace clock
        // running against it would blame the agent for the user's pause. The
        // control channel settles for silence at the same time, which is what
        // re-arms the watchdog — hence the guard rather than caller discipline.
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.activity.placeForTesting(fixture.phase)

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        #expect(instance.agentPostStartTaskForTesting == nil)
        try await Task.sleep(for: Self.testWatchdogGrace * 3)
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test("Watchdog is a no-op while the agent is connected")
    func watchdogNoopWhileAgentConnected() async throws {
        // Re-arm sites (resume, and the control channel dying) fire without
        // checking whether an agent is already talking; nothing to wait for
        // means nothing to arm.
        let instance = makeMacOSInstanceWithAgentInstalled()
        let (guestFd, hostFd) = try makeRawSocketPair()
        let guest = VsockChannel(fileDescriptor: guestFd)
        let host = VsockChannel(fileDescriptor: hostFd)
        guest.start()
        host.start()
        defer { guest.close() }

        let control = VsockControlService(channel: host, label: "watchdog-test")
        instance.sessionContext?.vsock.control = control
        control.start()
        defer { control.stop() }

        try guest.send(makeGuestHelloFrame(agentVersion: "0.9.2"))
        try await waitForChange { control.agentVersion != nil }

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        #expect(instance.agentPostStartTaskForTesting == nil)
    }

    @Test("startAgentPostStartWatchdog is idempotent when already armed")
    func watchdogIdempotent() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        // Original timer with a long grace so we can be sure the second
        // call's would-be tiny grace has elapsed long before the original
        // would naturally fire. If the second call had taken effect, the
        // flag would be true after we sleep below.
        instance.startAgentPostStartWatchdog(grace: .seconds(30))
        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)

        try await Task.sleep(for: Self.testWatchdogGrace * 3)
        #expect(instance.agentExpectedButMissing == false)
    }

    @Test("Watchdog firing also clears a previously-dismissed install nudge and persists the change")
    func watchdogClearsAgentInstallNudgeDismissed() async throws {
        // Scenario: user previously installed the agent (lastSeenAgentVersion
        // set) and earlier dismissed the install nudge for this VM. The
        // agent now fails to reconnect after boot; the watchdog fires
        // .expectedMissing AND resets the dismissed flag so any future
        // .waiting (e.g. they wipe + reinstall the VM) is not silently
        // suppressed by their old preference.
        let instance = makeMacOSInstanceWithAgentInstalled(agentInstallNudgeDismissed: true)
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(holding: [instance], storage: storage)
        defer { withExtendedLifetime(library) {} }

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)

        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentExpectedButMissing == true)
        #expect(instance.hostState.agentInstallNudgeDismissed == false)
        #expect(storage.saveHostStateCallCount == 1)
        #expect(storage.hostStates[instance.bundleURL]?.agentInstallNudgeDismissed == false)
    }

    @Test("Watchdog firing clears the stored guest OS version in the same persist")
    func watchdogClearsGuestOSVersion() async throws {
        // The agent that vouched for the OS version never reconnected, so the
        // value is unverifiable — Unknown must overwrite it rather than let a
        // stale version linger (the guest may have been wiped or upgraded).
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)")
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(holding: [instance], storage: storage)
        defer { withExtendedLifetime(library) {} }

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)

        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentExpectedButMissing == true)
        #expect(instance.configuration.lastSeenGuestOSVersion == nil)
        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("Watchdog firing leaves an undismissed nudge alone (no spurious persist)")
    func watchdogDoesNotPersistWhenDismissalAlreadyClear() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        // Default: agentInstallNudgeDismissed == false
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(holding: [instance], storage: storage)
        defer { withExtendedLifetime(library) {} }

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)

        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentExpectedButMissing == true)
        #expect(storage.saveConfigurationCallCount == 0)
        #expect(storage.saveHostStateCallCount == 0)
    }

    @Test(
        "A watchdog whose reset cannot be saved leaves the configuration as the bundle holds it, and the surfaces show the guest version as unknown"
    )
    func watchdogWhoseResetFailsShowsTheVersionAsUnknown() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)", agentInstallNudgeDismissed: true)
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(holding: [instance], storage: storage)
        defer { withExtendedLifetime(library) {} }
        storage.saveConfigurationError = NSError(domain: "test", code: 1)
        let held = instance.settings

        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)

        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentExpectedButMissing == true)
        #expect(instance.settings == held)
        #expect(storage.bundles[instance.bundleURL] == held.configuration)
        #expect(storage.hostStates[instance.bundleURL] == held.hostState)
        #expect(instance.agentStatus == .expectedMissing(expected: "0.9.2"))
        #expect(instance.guestOSVersionDisplay == nil)
        #expect(instance.effectiveConfiguration.effectiveGuestMacOSVersion == nil)
    }

    @Test("A mid-session firing leaves the nudge dismissal and guest OS version alone")
    func watchdogPreservesPersistedStateAfterAMidSessionDeath() async throws {
        // The clearing exists for an agent that never showed up: nothing
        // vouched for the stored OS version, and the install nudge should come
        // back. After a Hello this session both facts are backed by evidence
        // the session produced, and `agentInstallNudgeDismissed` is a user
        // preference nothing restores — a dropped channel is not enough to
        // reverse it.
        let instance = makeMacOSInstanceWithAgentInstalled(agentInstallNudgeDismissed: true)
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(holding: [instance], storage: storage)
        defer { withExtendedLifetime(library) {} }

        instance.recordObservedAgentInfo(
            ObservedAgentInfo(agentVersion: "0.9.2", osVersion: "Version 26.0 (Build 25A123)"))
        #expect(instance.hasSeenAgentThisSession)
        let persistsAfterHello = storage.saveConfigurationCallCount
        let hostStatePersistsAfterHello = storage.saveHostStateCallCount

        // The agent goes away mid-session and never comes back.
        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        await instance.agentPostStartTaskForTesting?.value

        // The badge still escalates — that is the whole point of #706.
        #expect(instance.agentExpectedButMissing == true)
        #expect(instance.agentStatus == .expectedMissing(expected: "0.9.2"))
        #expect(instance.hostState.agentInstallNudgeDismissed == true)
        #expect(instance.configuration.lastSeenGuestOSVersion == "Version 26.0 (Build 25A123)")
        #expect(storage.saveConfigurationCallCount == persistsAfterHello)
        #expect(storage.saveHostStateCallCount == hostStatePersistsAfterHello)
    }

    @Test("A session's end clears hasSeenAgentThisSession")
    func sessionEndClearsSeenAgentFlag() throws {
        // The flag is per-session: the next boot's no-show must be free to
        // rewrite persisted agent state again.
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.recordObservedAgentInfo(ObservedAgentInfo(agentVersion: "0.9.2", osVersion: "26.0"))
        #expect(instance.hasSeenAgentThisSession)
        let context = try #require(instance.sessionContext)

        instance.handleSessionEvent(.guestDidStop)
        #expect(!context.hasSeenAgentThisSession)
    }

    @Test("A session's end clears agentExpectedButMissing and cancels the watchdog")
    func sessionEndResetsWatchdogState() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        // Drive the flag manually to simulate the watchdog having fired.
        instance.sessionContext?.agentExpectedButMissing = true
        instance.startAgentPostStartWatchdog(grace: .seconds(60))
        let context = try #require(instance.sessionContext)

        instance.handleSessionEvent(.guestDidStop)

        #expect(context.agentExpectedButMissing == false)
        // The next session's context arms cleanly — the prior task was
        // cancelled, so nothing carries over to block it.
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentExpectedButMissing == true)
    }

    /// The cross-context ABA the generation counter alone cannot close: each
    /// context starts counting at zero, so a task armed at generation 1 in one
    /// session matches generation 1 in the next. Cancellation does not cover
    /// it — a sleep that returned just before the teardown is past the point
    /// `cancel()` can reach.
    @Test("A watchdog armed in a torn-down session never fires on its successor")
    func watchdogFromAPriorContextDoesNotFireOnTheNext() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        // Held to the end of the test: without it the released context
        // deallocates and the task's weak capture answers the question before
        // the identity check is reached, which is not what is under test.
        let staleContext = instance.sessionContext
        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        let stale = instance.agentPostStartTaskForTesting
        #expect(stale != nil)

        // Teardown, then a fresh session arming its own watchdog on a grace
        // long enough that it cannot legitimately fire during this test.
        instance.handleSessionEvent(.guestDidStop)
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
        instance.startAgentPostStartWatchdog(grace: .seconds(60))
        #expect(instance.agentPostStartTaskForTesting != nil)

        // The stale task's sleep elapses here; it must disown itself.
        await stale?.value

        #expect(instance.agentExpectedButMissing == false)
        #expect(instance.agentStatus != .expectedMissing(expected: "0.9.2"))
        // And it must not have cleared the successor's slot on the way out —
        // an emptied slot is what would let the next arm site double-arm.
        #expect(instance.agentPostStartTaskForTesting != nil)
        instance.cancelAgentPostStartWatchdog()
        #expect(staleContext !== instance.sessionContext)
    }

    @Test("agentStatus surfaces .expectedMissing only when both the flag and persisted version are set")
    func agentStatusExpectedMissingRequiresBoth() {
        let instance = makeMacOSInstanceWithAgentInstalled()
        let library = makeWiredLibrary(holding: [instance])
        // Flag alone but version present → .expectedMissing
        instance.sessionContext?.agentExpectedButMissing = true
        #expect(instance.agentStatus == .expectedMissing(expected: "0.9.2"))

        // Wipe the persisted version: the synthesizer guard falls back to
        // .waiting rather than producing .expectedMissing(expected: "").
        library.editConfiguration(of: instance) { $0.lastSeenAgentVersion = nil }
        #expect(instance.agentStatus == .waiting)
    }

    // MARK: - VMEditPermit.updateConfiguration

    @Test("A mutation the persistence pipeline could not write reports that it did not land")
    func mutationReportsAFailedWrite() throws {
        let instance = VMInstanceFixture.make()
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(holding: [instance], storage: storage)
        defer { withExtendedLifetime(library) {} }
        storage.saveConfigurationError = NSError(domain: "test", code: 1)
        let before = instance.configuration

        let outcome = try instance.activity.edit(.machineKeys) {
            $0.updateConfiguration { $0.displayHiDPI.toggle() }
        }

        // Memory stays what the bundle holds, and the caller is told the save
        // did not land.
        #expect(outcome.failedToSave)
        #expect(instance.configuration == before)
        #expect(storage.bundles[instance.bundleURL]?.displayHiDPI == before.displayHiDPI)
    }

    @Test("A mutation on an instance no library has wired changes nothing")
    func mutationWithoutPersistenceChangesNothing() throws {
        let instance = VMInstanceFixture.make()
        let before = instance.configuration

        #expect(
            try instance.activity.edit(.machineKeys) {
                $0.updateConfiguration { $0.displayHiDPI.toggle() }
            }.refusedForNoLibrary)
        #expect(instance.configuration == before)
    }

    // MARK: - recordObservedAgentInfo

    @Test("recordObservedAgentInfo persists when the version changes")
    func recordObservedPersistsOnChange() {
        let instance = makeMacOSInstanceWithAgentInstalled(lastSeen: "0.9.0")
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(holding: [instance], storage: storage)
        defer { withExtendedLifetime(library) {} }

        instance.recordObservedAgentInfo(ObservedAgentInfo(agentVersion: "0.9.2", osVersion: nil))

        #expect(instance.configuration.lastSeenAgentVersion == "0.9.2")
        #expect(storage.bundles[instance.bundleURL]?.lastSeenAgentVersion == "0.9.2")
    }

    @Test("recordObservedAgentInfo populates both last-seen fields for fresh VMs")
    func recordObservedSetsFromNil() {
        // Simulates the very first time an agent connects to a fresh VM —
        // the persisted fields start nil and the observer must seed them,
        // in a single write.
        let instance = VMInstanceFixture.make(
            name: "Fresh", guestOS: .macOS, phase: .running(sessionID: UUID()))
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(holding: [instance], storage: storage)
        defer { withExtendedLifetime(library) {} }

        instance.recordObservedAgentInfo(
            ObservedAgentInfo(agentVersion: "0.9.0", osVersion: "Version 26.0 (Build 25A123)"))

        #expect(instance.configuration.lastSeenAgentVersion == "0.9.0")
        #expect(instance.configuration.lastSeenGuestOSVersion == "Version 26.0 (Build 25A123)")
        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("recordObservedAgentInfo does not persist when both fields are unchanged")
    func recordObservedSkipsRedundantWrites() {
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeen: "0.9.2", lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)")
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(holding: [instance], storage: storage)
        defer { withExtendedLifetime(library) {} }

        let info = ObservedAgentInfo(
            agentVersion: "0.9.2", osVersion: "Version 26.0 (Build 25A123)")
        instance.recordObservedAgentInfo(info)
        instance.recordObservedAgentInfo(info)

        // Two identical Hellos must not produce a single disk write.
        // Storage churn would re-fire VMDirectoryWatcher reconcile on every
        // heartbeat-driven reconnect.
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("recordObservedAgentInfo persists an OS-version change on a same-agent-version reconnect")
    func recordObservedPersistsOSVersionChangeAlone() {
        // The guest took a macOS update; the agent survived it at the same
        // version. The new OS version must still land on disk.
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeen: "0.9.2", lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)")
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(holding: [instance], storage: storage)
        defer { withExtendedLifetime(library) {} }

        instance.recordObservedAgentInfo(
            ObservedAgentInfo(agentVersion: "0.9.2", osVersion: "Version 26.1 (Build 25B456)"))

        #expect(instance.configuration.lastSeenGuestOSVersion == "Version 26.1 (Build 25B456)")
        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("recordObservedAgentInfo overwrites a stored OS version with nil when the agent reports none")
    func recordObservedNilOSVersionOverwrites() {
        // An agent that stops vouching for an OS version must clear the stored
        // one — Unknown beats stale.
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeen: "0.9.2", lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)")
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }

        instance.recordObservedAgentInfo(ObservedAgentInfo(agentVersion: "0.9.2", osVersion: nil))

        #expect(instance.configuration.lastSeenGuestOSVersion == nil)
    }

    @Test("recordObservedAgentInfo fires onAgentBecameCurrent for a current version")
    func recordObservedFiresBecameCurrentOnCurrentVersion() throws {
        let bundled = try #require(KernovaMacOSAgentInfo.bundledVersion)
        // lastSeen must differ from the reported version so the persist guard
        // doesn't short-circuit before the auto-eject hook.
        let instance = makeMacOSInstanceWithAgentInstalled(lastSeen: "0.0.0")
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }
        var fired = 0
        instance.onAgentBecameCurrent = { fired += 1 }

        instance.recordObservedAgentInfo(ObservedAgentInfo(agentVersion: bundled, osVersion: nil))

        #expect(fired == 1)
    }

    @Test("recordObservedAgentInfo does not fire onAgentBecameCurrent for an outdated version")
    func recordObservedSkipsBecameCurrentOnOutdated() throws {
        let bundled = try #require(KernovaMacOSAgentInfo.bundledVersion)
        // Only meaningful when the bundled version is strictly newer than the
        // sentinel, so "0.0.1" genuinely classifies as outdated.
        try #require(bundled.compare("0.0.1", options: .numeric) == .orderedDescending)
        let instance = makeMacOSInstanceWithAgentInstalled(lastSeen: "0.0.0")
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }
        var fired = 0
        instance.onAgentBecameCurrent = { fired += 1 }

        instance.recordObservedAgentInfo(ObservedAgentInfo(agentVersion: "0.0.1", osVersion: nil))

        #expect(fired == 0)
    }

    @Test("recordObservedAgentInfo does not fire onAgentBecameCurrent on an unchanged-version reconnect")
    func recordObservedSkipsBecameCurrentWhenUnchanged() throws {
        let bundled = try #require(KernovaMacOSAgentInfo.bundledVersion)
        // Same version as last seen → the became-current guard short-circuits,
        // so a disk mounted to run uninstall.command is never yanked out by a
        // same-version reconnect — even when an OS-version change makes the
        // write itself go through.
        let instance = makeMacOSInstanceWithAgentInstalled(lastSeen: bundled)
        let library = makeWiredLibrary(holding: [instance])
        defer { withExtendedLifetime(library) {} }
        var fired = 0
        instance.onAgentBecameCurrent = { fired += 1 }

        instance.recordObservedAgentInfo(
            ObservedAgentInfo(agentVersion: bundled, osVersion: "Version 26.0 (Build 25A123)"))

        #expect(fired == 0)
        #expect(instance.configuration.lastSeenGuestOSVersion == "Version 26.0 (Build 25A123)")
    }

    @Test("recordObservedAgentInfo cancels the watchdog and clears expected-missing")
    func recordObservedClearsWatchdogState() async throws {
        let instance = makeMacOSInstanceWithAgentInstalled()
        instance.sessionContext?.agentExpectedButMissing = true
        instance.startAgentPostStartWatchdog(grace: .seconds(10))

        instance.recordObservedAgentInfo(ObservedAgentInfo(agentVersion: "0.9.2", osVersion: nil))

        #expect(instance.agentExpectedButMissing == false)
        // Re-arming after the cancel must succeed (proves the prior task
        // was cancelled — the idempotency guard does not block this).
        instance.startAgentPostStartWatchdog(grace: Self.testWatchdogGrace)
        await instance.agentPostStartTaskForTesting?.value
        #expect(instance.agentExpectedButMissing == true)
    }

    @Test(
        "A Hello whose record cannot be saved leaves the configuration as the bundle holds it, and the surfaces show the reported versions"
    )
    func helloWhoseRecordFailsShowsTheReportedVersions() {
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeen: "0.9.0", lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)")
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(holding: [instance], storage: storage)
        defer { withExtendedLifetime(library) {} }
        storage.saveConfigurationError = NSError(domain: "test", code: 1)
        let held = instance.configuration

        instance.recordObservedAgentInfo(
            ObservedAgentInfo(agentVersion: "0.9.2", osVersion: "Version 26.1 (Build 25B456)"))

        #expect(instance.configuration == held)
        #expect(storage.bundles[instance.bundleURL] == held)
        #expect(instance.lastSeenAgentVersion == "0.9.2")
        #expect(instance.guestOSVersionDisplay == "26.1")
        #expect(instance.effectiveConfiguration.lastSeenAgentVersion == "0.9.2")
        #expect(instance.effectiveConfiguration.effectiveGuestMacOSVersion == MacOSVersion("26.1"))
    }

    // MARK: - guestOSVersionDisplay

    @Test("guestOSVersionDisplay reduces an operatingSystemVersionString report to its version")
    func guestOSVersionDisplayReducesDisplayStringReport() {
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeenGuestOSVersion: "Version 26.0 (Build 25A123)")
        #expect(instance.guestOSVersionDisplay == "26.0")
    }

    @Test("guestOSVersionDisplay reduces a guest-localized report the same way")
    func guestOSVersionDisplayReducesLocalizedReport() {
        let instance = makeMacOSInstanceWithAgentInstalled(
            lastSeenGuestOSVersion: "Versión 26.0 (Compilación 25A123)")
        #expect(instance.guestOSVersionDisplay == "26.0")
    }

    @Test("guestOSVersionDisplay passes the numeric shape through untouched")
    func guestOSVersionDisplayPassthrough() {
        #expect(
            makeMacOSInstanceWithAgentInstalled(lastSeenGuestOSVersion: "26.0")
                .guestOSVersionDisplay == "26.0")
        #expect(
            makeMacOSInstanceWithAgentInstalled(lastSeenGuestOSVersion: "26.0.1")
                .guestOSVersionDisplay == "26.0.1")
    }

    @Test("guestOSVersionDisplay passes a report holding no digits through untouched")
    func guestOSVersionDisplayNoDigitsPassthrough() {
        let instance = makeMacOSInstanceWithAgentInstalled(lastSeenGuestOSVersion: "macOS")
        #expect(instance.guestOSVersionDisplay == "macOS")
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

    @Test("bundledStorageDisks falls back to the synthesized main disk for a nil or empty list")
    func bundledStorageDisksFallBackToTheMainDisk() {
        for disks in [nil, []] as [[StorageDisk]?] {
            let instance = VMInstanceFixture.make { $0.storageDisks = disks }
            #expect(instance.bundledStorageDisks.count == 1)
            #expect(instance.bundledStorageDisks[0].isInternal)
        }
    }

    @Test("isSoleStorageDisk is true for a VM's only disk and false for either of two")
    func isSoleStorageDiskFollowsTheCount() {
        let instance = VMInstanceFixture.make()
        let library = makeWiredLibrary(holding: [instance])
        // A nil list resolves to the synthesized main disk alone.
        let main = instance.effectiveStorageDisks[0]
        #expect(instance.isSoleStorageDisk(main))

        let extra = StorageDisk(
            path: "AdditionalDisks/extra.asif", readOnly: false, label: "Extra",
            isInternal: true, kind: .virtio)
        library.editConfiguration(of: instance) { $0.storageDisks = [main, extra] }
        #expect(!instance.isSoleStorageDisk(main))
        #expect(!instance.isSoleStorageDisk(extra))

        library.editConfiguration(of: instance) { $0.storageDisks = [extra] }
        #expect(instance.isSoleStorageDisk(extra))
    }

    @Test("hasGuestAgentInstallerMounted reflects whether the bundled DMG is attached")
    func hasGuestAgentInstallerMountedReflectsState() throws {
        let installerURL = try #require(KernovaMacOSAgentInfo.installerDiskImageURL)
        let instance = VMInstanceFixture.make()
        let library = makeWiredLibrary(holding: [instance])

        #expect(!instance.hasGuestAgentInstallerMounted)

        library.editConfiguration(of: instance) {
            $0.removableMedia = [
                RemovableMediaItem(path: installerURL.path(percentEncoded: false), readOnly: true)
            ]
        }
        #expect(instance.hasGuestAgentInstallerMounted)

        // An unrelated removable item must not count as the installer.
        library.editConfiguration(of: instance) {
            $0.removableMedia = [
                RemovableMediaItem(path: "/some/other/disk.img", readOnly: false)
            ]
        }
        #expect(!instance.hasGuestAgentInstallerMounted)
    }

    @Test("guestOSVersionDisplay is nil for nil and empty values, so the row hides")
    func guestOSVersionDisplayUnknown() {
        #expect(makeMacOSInstanceWithAgentInstalled().guestOSVersionDisplay == nil)
        // "" can only come from a hand-edited config.json (the service and
        // recorder both normalize it to nil) but must not render as a blank row.
        #expect(
            makeMacOSInstanceWithAgentInstalled(lastSeenGuestOSVersion: "").guestOSVersionDisplay
                == nil)
    }
}
