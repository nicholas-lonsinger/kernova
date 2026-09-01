import Foundation
import KernovaKit
import os
import Virtualization

/// The VM display's current hosting location.
enum VMDisplayMode: Sendable {
    /// Display is embedded in the main window's detail pane.
    case inline
    /// Display is in its own resizable window (not fullscreen).
    case popOut
    /// Display is in its own window in native macOS fullscreen.
    case fullscreen
    /// No display surface — the user closed the display window while the VM
    /// keeps running headless. `displayPreference` is retained so the next
    /// reopen uses the previous style.
    case hidden
}

/// Which inline detail pane the user has chosen to view for a running VM.
///
/// Ignored when the VM is stopped (settings are always shown then).
enum DetailPaneMode: Sendable {
    case display
    case settings
}

/// Runtime wrapper around a VM configuration, its backing virtual machine, and current status.
@MainActor
@Observable
final class VMInstance {
    // MARK: - Properties

    let instanceID: UUID
    var configuration: VMConfiguration

    /// Where this VM is in its lifecycle — the one stored value its status, its
    /// failure message and every liveness predicate here are read off.
    ///
    /// Moved by ``enter(_:)`` for a transition that names no session, by
    /// ``settle(_:for:)`` for one concluding work a session did, and by
    /// ``tearDownSession(restingAt:)``, which releases the session and rests in
    /// the same call.
    private(set) var phase: VMLifecyclePhase

    /// The vocabulary the wire and every label read.
    var status: VMStatus { phase.status }

    /// The permanent-failure message the error banner and the status tooltip
    /// show.
    ///
    /// A payload of ``VMLifecyclePhase/failed(message:)`` rather than a field of
    /// its own, so it cannot survive the move to another phase.
    var errorMessage: String? { phase.errorMessage }

    /// Everything scoped to the current `VZVirtualMachine`'s lifetime, opened by
    /// ``beginSessionContext(bootedIntoRecovery:)`` and released whole by
    /// ``tearDownSession(restingAt:)``.
    ///
    /// The read-only projections below (``liveRemovableMedia``, etc.) are the
    /// read surface; the methods in "Runtime Removable Media" below are the
    /// write surface for the fields they cover. A write that arrives with no
    /// session open is dropped and logged rather than resurrecting a
    /// torn-down context.
    private(set) var sessionContext: VMSessionContext?

    /// The live VM's isolation domain — the only type that calls into the
    /// `VZVirtualMachine` and its device objects.
    var session: VMSession? { sessionContext?.session }

    let bundleURL: URL

    /// Progress of the guest setup running for this VM — a macOS install,
    /// or a Linux installer image being fetched and verified.
    var setupState: GuestSetupState?

    /// The guest-setup pipeline in flight, owned by `VMCommandCore` — armed for
    /// exactly the setup phase, so its presence is also `allowedVerbs(for:)`'s
    /// gate for offering `.cancelGuestSetup`.
    var setupTask: Task<Void, Never>?

    // MARK: - Preparing State (Clone/Import)

    enum PreparingOperation: Sendable {
        case cloning
        case importing

        var displayLabel: String {
            switch self {
            case .cloning: "Cloning\u{2026}"
            case .importing: "Importing\u{2026}"
            }
        }

        /// The user-facing noun for this operation ("Clone" / "Import").
        var displayNoun: String {
            switch self {
            case .cloning: "Clone"
            case .importing: "Import"
            }
        }

        var cancelLabel: String { "Cancel \(displayNoun)" }

        var cancelAlertTitle: String { "Cancel \(displayNoun)?" }
    }

    /// Tracks an in-flight clone or import operation.
    struct PreparingState {
        let operation: PreparingOperation
        var task: Task<Void, Never>

        /// `true` once the user has cancelled but the uninterruptible copy is still settling.
        ///
        /// The row stays visible until the copy task finishes and removes it, so the
        /// destination stays reconcile-protected and is trashed exactly once.
        var isCancelling = false

        var displayLabel: String { isCancelling ? "Cancelling\u{2026}" : operation.displayLabel }
    }

    /// Non-nil when this instance is a phantom row awaiting a clone or import to finish.
    var preparingState: PreparingState?

    var isPreparing: Bool { preparingState != nil }

    /// The named restore points this VM's bundle holds, mirrored from
    /// `Snapshots/manifest.json`.
    ///
    /// The library and its adapter are the only writers — they keep this and the
    /// on-disk manifest in step; every surface reads it.
    var snapshotManifest = VMSnapshotManifest()

    /// Where this VM's display currently lives.
    ///
    /// ``VMDisplayPlacementController`` owns every transition; the model writes
    /// this only in ``tearDownSession(restingAt:)``, to the sole mode a
    /// sessionless VM can rest in.
    var displayMode: VMDisplayMode = .inline

    var detailPaneMode: DetailPaneMode = .display

    // MARK: - Clipboard Sharing

    /// Active clipboard service: `SpiceClipboardService` for Linux,
    /// `VsockClipboardService` for macOS.
    ///
    /// Nil on macOS until the guest agent connects. The two transports are
    /// owned separately — the vsock one by this session's feature coordinator,
    /// the SPICE one by the session context — and projected into one existential
    /// here, so no window controller branches on transport.
    var clipboardService: (any ClipboardServicing)? {
        sessionContext?.vsock.clipboard ?? sessionContext?.clipboardService
    }

    /// Host-pasteboard writer shared by the clipboard window's "Copy to Mac" and
    /// the passthrough coordinator.
    ///
    /// One per VM so echo suppression sees both writers — the coordinator's poll
    /// skips whatever change count this publisher last produced.
    @ObservationIgnored let hostClipboardPublisher = HostClipboardPublisher()

    /// Where this VM's clipboard and drop producers publish, and the owner of the
    /// value below.
    ///
    /// One per VM rather than per connection: a promise a clipboard service
    /// published outlives that service, so a refusal belongs to the VM
    /// (docs/CLIPBOARD.md §13).
    @ObservationIgnored let clipboardTransfers = ClipboardTransferReporter()

    /// This VM's clipboard transfer state — running, finished, or idle — which
    /// every surface renders.
    ///
    /// Mirrored from ``clipboardTransfers`` because KernovaKit deploys to
    /// macOS 12 and cannot be `@Observable` itself.
    private(set) var clipboardTransferReport: ClipboardTransferReport = .idle

    // MARK: - Vsock Channel (macOS guests)

    var vsockLogService: VsockGuestLogService? { sessionContext?.vsock.log }

    var vsockControlService: VsockControlService? { sessionContext?.vsock.control }

    /// Serves files dropped on this VM's display; populated once the guest
    /// agent's drop client connects.
    var vsockDropService: VsockDropService? { sessionContext?.vsock.drop }

    /// Where the feature listeners read admission verdicts, off the main actor.
    ///
    /// One per VM across every control-service generation: the accept path
    /// reads it without touching this instance. The live control service
    /// publishes into it; replaced or torn down, the gate is cleared.
    @ObservationIgnored let vsockAdmissionGate = VsockAdmissionGate()

    /// Where the clipboard data listener lands each accepted transfer
    /// connection, pointed at the live `VsockClipboardService`.
    @ObservationIgnored let clipboardDataSink = VsockDataConnectionSink()

    /// Where the drop data listener lands each accepted item connection,
    /// pointed at the live `VsockDropService`.
    @ObservationIgnored let dropDataSink = VsockDataConnectionSink()

    /// `true` when this VM has reached `.running`, the host previously saw a
    /// guest agent connect (`configuration.lastSeenAgentVersion != nil`), and a
    /// grace period has elapsed without a `Hello` arriving over the control
    /// channel.
    var agentExpectedButMissing: Bool { sessionContext?.agentExpectedButMissing ?? false }

    /// `true` once a `Hello` has arrived on this VM session.
    ///
    /// Separates a mid-session agent disappearance from an agent that never
    /// appeared: only the latter is evidence about what is installed in the
    /// guest, so only the latter may rewrite persisted agent state.
    var hasSeenAgentThisSession: Bool { sessionContext?.hasSeenAgentThisSession ?? false }

    /// `true` when this session cold-booted into macOS Recovery, which never
    /// runs the guest agent — so agent silence is evidence of nothing for the
    /// whole session, not just at the moment of boot.
    var bootedIntoRecovery: Bool { sessionContext?.bootedIntoRecovery ?? false }

    /// Performs a host-side mutation of this instance's configuration and routes
    /// it through the library's `updateConfiguration` pipeline (persist + apply
    /// live policy).
    ///
    /// Wired by `VMLibrary.wirePersistence(for:)`; `nil` for instances created
    /// outside a library.
    @ObservationIgnored var onUpdateConfiguration: (@MainActor ((inout VMConfiguration) -> Void) -> Void)?

    /// Fired when the guest agent handshakes a new version that is current
    /// (matches or exceeds what the host bundles) — i.e. an install/update just
    /// completed.
    ///
    /// The host uses it to auto-eject the guest-agent installer disk.
    @ObservationIgnored var onAgentBecameCurrent: (@MainActor () -> Void)?

    /// Fired at the end of ``tearDownSession()``, once this VM's
    /// `VZVirtualMachine` and everything riding it are released — a stop, a
    /// force stop, an error, or a completed save-suspend alike.
    ///
    /// Wired by `VMLibrary.wirePersistence(for:)`; the library uses it for work
    /// that can only run while no VM holds the resource it touches.
    @ObservationIgnored var onSessionTornDown: (@MainActor () -> Void)?

    /// Fired from ``resetToStopped()`` — the guest powering off, however it got
    /// there: a graceful shutdown from inside, Stop, or Force Stop.
    ///
    /// Wired by `VMLibrary.wirePersistence(for:)`, whose handler reverts an
    /// Ephemeral Mode VM to its baseline here. A suspend does not reach it:
    /// `save` tears the session down and rests at `.paused`.
    @ObservationIgnored var onPoweredOff: (@MainActor () -> Void)?

    /// Applies a configuration mutation, routing it through the persistence
    /// pipeline when `onUpdateConfiguration` is wired.
    func performConfigurationMutation(_ mutate: (inout VMConfiguration) -> Void) {
        if let onUpdateConfiguration {
            onUpdateConfiguration(mutate)
        } else {
            mutate(&configuration)
        }
    }

    /// The current install/version/liveness state of the guest agent for this VM.
    ///
    /// The single read site for the UI. macOS guests source it from the
    /// always-on `VsockControlService`, so it is meaningful whether or not
    /// clipboard sharing is enabled; `.expectedMissing` is synthesized here
    /// because that service has no access to persisted host state. Linux guests
    /// source it from `SpiceClipboardService`, which only ever reaches
    /// `.waiting` / `.current`.
    var agentStatus: AgentStatus {
        switch configuration.guestOS {
        case .macOS:
            return AgentStatus.synthesize(
                upstream: vsockControlService?.agentStatus ?? .waiting,
                lastSeenAgentVersion: configuration.lastSeenAgentVersion,
                isInLiveSession: hasLiveVirtualMachine,
                agentExpectedButMissing: agentExpectedButMissing
            )
        case .linux:
            return (clipboardService as? SpiceClipboardService)?.agentStatus ?? .waiting
        }
    }

    private static let logger = Logger(subsystem: "app.kernova", category: "VMInstance")

    nonisolated var id: UUID { instanceID }
    var name: String { configuration.name }

    // MARK: - Network Attachment Recovery

    /// Keeps the live network attachment realizing the configured mode;
    /// created with the `VZVirtualMachine` for network-enabled VMs, activated
    /// once the session reaches `.running`, torn down with the session.
    var networkAttachmentCoordinator: NetworkAttachmentCoordinator? {
        sessionContext?.networkAttachmentCoordinator
    }

    /// Reconciles the live attachment with the configured mode, once the
    /// session has reached a state VZ will swap an attachment on.
    ///
    /// A no-op for a VM whose session has no network device — or none at all.
    func activateNetworkAttachment() {
        sessionContext?.networkAttachmentCoordinator?.activate()
    }

    /// `true` while a live session's network device is detached and recovery
    /// is waiting for a usable host interface.
    var networkAttachmentPending: Bool { sessionContext?.networkAttachmentPending ?? false }

    // MARK: - Bundle Layout

    let bundleLayout: VMBundleLayout

    // MARK: - Preferences

    /// App-wide settings this session honors — today, the clipboard paste
    /// ceiling, which is app-wide rather than per-VM because it trades against
    /// *this Mac's* throughput and a `VMConfiguration` field would travel inside
    /// the bundle.
    ///
    /// Injected rather than read from `.shared` at the use site so a test can
    /// drive it without writing the real defaults domain.
    let preferences: AppPreferences

    // MARK: - Initializer

    init(
        configuration: VMConfiguration, bundleURL: URL, phase: VMLifecyclePhase = .stopped,
        preferences: AppPreferences = .shared
    ) {
        self.instanceID = configuration.id
        self.configuration = configuration
        self.bundleURL = bundleURL
        self.bundleLayout = VMBundleLayout(bundleURL: bundleURL)
        self.phase = phase
        self.preferences = preferences
        clipboardTransfers.onReportChanged = { [weak self] report in
            self?.clipboardTransferReport = report
        }
    }

    // MARK: - VM Bundle Paths (forwarded from VMBundleLayout)

    var diskImageURL: URL { bundleLayout.diskImageURL }
    var auxiliaryStorageURL: URL { bundleLayout.auxiliaryStorageURL }
    var hardwareModelURL: URL { bundleLayout.hardwareModelURL }
    var machineIdentifierURL: URL { bundleLayout.machineIdentifierURL }
    var saveFileURL: URL { bundleLayout.saveFileURL }
    var hasSaveFile: Bool { bundleLayout.hasSaveFile }
    var serialLogURL: URL { bundleLayout.serialLogURL }

    // MARK: - Machine Identity

    /// Memoized `MachineIdentifier` file read: the outer optional separates "not
    /// read yet" from "read, and there is no file".
    @ObservationIgnored private var machineIdentifierFileData: Data??

    /// The macOS machine identifier this VM boots with — the configuration field
    /// when set, otherwise the bundle's identifier file.
    ///
    /// The fallback mirrors ``ConfigurationBuilder``, which reads the file when
    /// the configuration carries no identifier, so a bundle holding its identity
    /// only on disk compares equal to one holding it in the configuration. The
    /// file is read at most once per instance.
    var effectiveMachineIdentifierData: Data? {
        if let fromConfiguration = configuration.machineIdentifierData { return fromConfiguration }
        if let cached = machineIdentifierFileData { return cached }
        let fromFile = try? Data(contentsOf: machineIdentifierURL)
        machineIdentifierFileData = .some(fromFile)
        return fromFile
    }

    // MARK: - Runtime Removable Media

    /// USB mass storage devices currently attached on the XHCI controller.
    ///
    /// One entry per item in `configuration.removableMedia` while the VM is
    /// running; cleared on stop/teardown.
    var liveRemovableMedia: [USBDeviceInfo] { sessionContext?.liveRemovableMedia ?? [] }

    /// Records a device that was just attached, live, on the session
    /// `sessionID` names.
    ///
    /// Dropped and logged, rather than asserting, once that session is no
    /// longer the live one — see ``liveSessionID``:
    /// `VMLibrary.runRemovableMediaReconciliation` awaits the framework
    /// attach call, and a power-off (or a power-off and restart) landing on
    /// main during that suspension resolves the continuation against a VM this
    /// record no longer describes — the same race its own
    /// `USBDeviceError.noVirtualMachine` handling already treats as a normal
    /// bail, not a programming error.
    func recordAttachedMedia(_ info: USBDeviceInfo, for sessionID: UUID) {
        guard let context = mediaWriteTarget(for: sessionID, deviceID: info.id, "attached-media record")
        else { return }
        context.liveRemovableMedia.append(info)
    }

    /// Removes a device's tracking entry and releases the security-scoped
    /// access grant backing it, in that order.
    ///
    /// A no-op, logged, when `sessionID` no longer names the live session — see
    /// ``recordAttachedMedia(_:for:)``. Nothing is released in that case: the
    /// grant this would have dropped belongs to whichever session is live now.
    func forgetAttachedMedia(deviceID: UUID, for sessionID: UUID) {
        guard let context = mediaWriteTarget(for: sessionID, deviceID: deviceID, "detached-media record")
        else { return }
        context.liveRemovableMedia.removeAll { $0.id == deviceID }
        context.fileAccess.releaseHotAttach(id: deviceID)
    }

    /// Registers the security-scoped access grant backing a hot-attached
    /// device with the session `sessionID` names, so it is released at detach
    /// or teardown instead of the caller's local scope.
    ///
    /// When that session is no longer the live one, `scope` is released here
    /// directly — see ``recordAttachedMedia(_:for:)`` — rather than left for
    /// the caller's local `deinit`, since `ScopedAccess.release()` is
    /// idempotent.
    func retainMediaScope(_ scope: ScopedAccess, deviceID: UUID, for sessionID: UUID) {
        guard let context = mediaWriteTarget(for: sessionID, deviceID: deviceID, "media scope") else {
            scope.release()
            return
        }
        context.fileAccess.addHotAttach(id: deviceID, scope)
    }

    /// The context a removable-media write issued against `sessionID` belongs
    /// to, or `nil` — logged — when that session has been released.
    private func mediaWriteTarget(
        for sessionID: UUID,
        deviceID: UUID,
        _ what: StaticString
    ) -> VMSessionContext? {
        guard let sessionContext, liveSessionID == sessionID else {
            Self.logger.notice(
                "Dropping \(what, privacy: .public) for '\(self.name, privacy: .public)' device \(deviceID, privacy: .public): session \(sessionID, privacy: .public) is no longer live"
            )
            return nil
        }
        return sessionContext
    }

    /// The live session's identity — the token every asynchronous hand-off and
    /// delivered event carries, so one raised against a session this instance
    /// has already released is dropped instead of landing on its successor or
    /// on a stopped VM.
    ///
    /// Read off ``phase``, which is what makes the drop reliable: the phase and
    /// the session move together, so no window exists where a released session
    /// still answers as live.
    var liveSessionID: UUID? { phase.sessionID }

    /// Whether a `VZVirtualMachine` for this VM is live in memory — the single
    /// liveness read every predicate here shares.
    var hasLiveVirtualMachine: Bool { liveSessionID != nil }

    /// Whether a live `VZVirtualMachine` is attached and settled at a state VZ
    /// can act on — the VMs a termination save-suspends, and the ones a device
    /// can be attached to.
    ///
    /// A cold-paused VM is excluded: its state is already on disk, with nothing
    /// live to act on.
    var hasLiveSession: Bool { phase.hasLiveSession }

    /// The session a removable-media attach or detach acts on, or `nil` when
    /// the VM has none to act on.
    ///
    /// The token every step of a reconcile pass carries, so the pass and the
    /// capability it was admitted by cannot answer for different sessions.
    var attachableSessionID: UUID? { hasLiveSession ? liveSessionID : nil }

    var canAttachUSBDevices: Bool { attachableSessionID != nil }

    /// `true` when the bundled guest-agent installer disk can be attached to or
    /// ejected from this VM.
    ///
    /// macOS guests only: the disk carries a `.app` and an `install.command`
    /// that stages a user LaunchAgent, neither of which a Linux guest can run.
    var canManageGuestAgentDisk: Bool {
        canAttachUSBDevices && configuration.guestOS == .macOS
    }

    /// Whether this VM may be holding — or be about to take — an attachment on
    /// the app-managed network of `kind`, so recreating that network would pull
    /// it out from under a session.
    ///
    /// The recovery coordinator answers whenever it exists: its main-actor
    /// mirror of what was last installed on the session's queue is the
    /// attachment the VM is *on*, which the configuration disagrees with from a
    /// live mode switch until the swap lands, in both directions.
    ///
    /// Without one — a VM with no session or no network device, and a session
    /// between its creation and its coordinator being built — the configuration
    /// decides, and only while a session could be forming or settling: the
    /// configuration build attaches the VM to the network before this instance
    /// holds anything that can be read back, and off-main configuration
    /// assembly can already hold a handle this VM has not been given yet.
    func mayHoldAttachment(on kind: VmnetNetworkKind) -> Bool {
        if let networkAttachmentCoordinator {
            return networkAttachmentCoordinator.appliedVmnetKind == kind
        }
        guard configuration.networkEnabled,
            VmnetNetworkKind(mode: configuration.networkMode) == kind
        else { return false }
        return phase.isTransitioning || hasLiveVirtualMachine
    }

    /// `true` when the VM is paused-to-disk but has no live `VZVirtualMachine` in memory.
    var isColdPaused: Bool { phase.isColdPaused }

    /// `true` when the VM is paused with its `VZVirtualMachine` still live in
    /// memory — the resumable counterpart of ``isColdPaused``.
    var isLivePaused: Bool { phase.isLivePaused }

    /// `true` while the VM is in an active lifecycle phase — see
    /// ``VMLifecyclePhase/isActive``.
    var isActive: Bool { phase.isActive }

    /// `true` when this VM should keep the app alive: preparing, in an active
    /// lifecycle phase, or live-paused in memory.
    var isKeepingAppAlive: Bool {
        isPreparing || isActive || isLivePaused
    }

    /// `true` while the VM is mid-operation — see
    /// ``VMLifecyclePhase/isTransitioning``.
    var isTransitioning: Bool { phase.isTransitioning }

    var canStart: Bool { phase.canStart }

    var canStop: Bool { phase.canStop }

    var canPause: Bool { phase.canPause }

    var canResume: Bool { phase.canResume }

    var canSave: Bool { phase.canSave }

    var canEditSettings: Bool { phase.canEditSettings }

    var canRename: Bool { !isPreparing && phase.canRename }

    /// Whether a rename committed now survives — see
    /// ``VMLifecyclePhase/renamePersists``.
    var renamePersists: Bool { phase.renamePersists }

    /// Whether the VM has a display session a backing view should present.
    var hasActiveDisplay: Bool { phase.hasActiveDisplay }

    /// How a capture started right now would be taken — the one place that
    /// choice is made — or `nil` when the VM is in no state to capture.
    ///
    /// The other at-rest phases are excluded. `.initialBoot` holds disks with no
    /// installed guest, so a revert would land the VM stopped over an unbootable
    /// disk. `.failed` may still hold a suspend slot the VM would resume from
    /// (see ``VirtualizationService/restingPhaseAfterRestoreFailure(on:)``).
    /// Every transitional phase (`.starting`, `.saving`, `.capturingLive`, …) is
    /// excluded too — a capture mid-operation would race the operation itself.
    ///
    /// Suspended additionally needs ``hasSaveFile``, unlike the other branches:
    /// the phase says the guest's memory is on disk, and only the file says it
    /// is still there — a slot removed underneath the VM leaves a suspension
    /// with nothing to capture, the same dead end
    /// ``VirtualizationService/restingPhaseAfterRestoreFailure(on:)`` names.
    var snapshotCaptureMode: VMSnapshotCaptureMode? {
        if canSave {
            .live
        } else if isColdPaused && hasSaveFile {
            .suspended
        } else if phase == .stopped {
            .stopped
        } else {
            nil
        }
    }

    /// `true` when a snapshot can be captured in some form.
    var canTakeSnapshot: Bool { snapshotCaptureMode != nil }

    /// `true` when this VM has a snapshot to go back to and is settled enough
    /// to be taken there.
    ///
    /// A live VM qualifies: the revert discards the running session, which is
    /// what the confirmation asks the user to accept.
    var canRevertToSnapshot: Bool {
        !isPreparing && !phase.isTransitioning && !snapshotManifest.isEmpty
    }

    // MARK: - Ephemeral Mode

    /// The snapshot a power-off returns this VM to, or `nil` when Ephemeral
    /// Mode is off or names a snapshot the manifest no longer lists.
    ///
    /// The one read every ephemeral path gates on, so a mode left on with a
    /// baseline that has gone reverts nothing rather than failing at power-off.
    var ephemeralBaselineSnapshot: VMSnapshot? {
        guard configuration.ephemeralModeEnabled,
            let id = configuration.ephemeralBaselineSnapshotID
        else { return nil }
        return snapshotManifest.snapshot(id: id)
    }

    /// `true` while a session this VM's baseline will discard is in memory —
    /// what the running Ephemeral marker reports.
    var hasLiveEphemeralSession: Bool {
        ephemeralBaselineSnapshot != nil && hasLiveVirtualMachine
    }

    /// `true` when `snapshot` is pinned as this VM's Ephemeral baseline, which
    /// bars deleting it.
    func isEphemeralBaseline(_ snapshot: VMSnapshot) -> Bool {
        ephemeralBaselineSnapshot?.id == snapshot.id
    }

    /// `true` when the VM is eligible for forceful termination — see
    /// ``VMLifecyclePhase/canForceStop``.
    var canForceStop: Bool { phase.canForceStop }

    /// `true` when the VM can be deleted — nothing live in memory, no
    /// transitional phase, and no import or clone writing into the bundle.
    ///
    /// Suspended VMs are included: the saved state is a file inside the bundle
    /// and is removed along with it, so no discard step is needed first.
    ///
    /// Enablement only.
    /// ``VMLibraryViewModel/deleteConfirmed(_:deletingExternalIDs:permanently:)``
    /// revalidates against the lifecycle lock at confirm time.
    var canDelete: Bool {
        !isPreparing && (phase.canEditSettings || isColdPaused)
    }

    /// `true` when the VM can be cold-booted into macOS Recovery.
    ///
    /// Stopped macOS guests only — Virtualization.framework has no recovery
    /// start option for Linux/EFI guests.
    var canStartInRecovery: Bool {
        phase == .stopped && configuration.guestOS == .macOS
    }

    var canUseExternalDisplay: Bool { hasLiveSession }

    var isInFullscreen: Bool { displayMode == .fullscreen }

    /// `true` when the display is not hosted inline — pop-out, fullscreen, or
    /// closed-while-headless (`.hidden`), all of which offer "Pop In".
    var isDisplayDetached: Bool { displayMode != .inline }

    var canShowClipboard: Bool {
        configuration.clipboardSharingEnabled && hasLiveSession
    }

    // MARK: - Session Events

    /// Builds the event sink a new session delivers into.
    ///
    /// Events hop to the main actor and apply only while the delivering
    /// session is still the one this instance holds: delivery is asynchronous,
    /// so a stop event from a torn-down session can arrive after a fresh
    /// session is attached and must not reset it.
    func makeSessionEvents() -> VMSessionEvents {
        VMSessionEvents { [weak self] sessionID, event in
            Task { @MainActor in
                self?.deliverSessionEvent(event, from: sessionID)
            }
        }
    }

    /// Applies `event` if `sessionID` still names the live session; drops it
    /// otherwise.
    func deliverSessionEvent(_ event: VMSessionEvent, from sessionID: UUID) {
        guard liveSessionID == sessionID else { return }
        handleSessionEvent(event)
    }

    func handleSessionEvent(_ event: VMSessionEvent) {
        switch event {
        case .guestDidStop:
            resetToStopped()
            Self.logger.notice("Guest stopped for VM '\(self.name, privacy: .public)'")
        case .didStopWithError(let error):
            tearDownSession(restingAt: .failed(message: error.localizedDescription))
            Self.logger.error(
                "VM '\(self.name, privacy: .public)' stopped with error: \(error.localizedDescription, privacy: .public)"
            )
        case .networkAttachmentDisconnected(let error):
            networkAttachmentCoordinator?.attachmentWasDisconnected(error: error)
        }
    }

    // MARK: - Phase Transitions

    /// Places the VM at `phase`.
    ///
    /// The write every transition that names no session goes through — a
    /// start's configuration-build window, a disks-only capture, a revert, an
    /// install pipeline, a discarded suspend slot. A phase that *does* name one
    /// is installed by ``settle(_:for:)`` or by ``attachSession(from:)``, and
    /// released by ``tearDownSession(restingAt:)``.
    func enter(_ phase: VMLifecyclePhase) {
        self.phase = phase
    }

    /// Applies `phase` only while `sessionID` still names the live session,
    /// reporting whether it landed.
    ///
    /// What every asynchronous operation concludes through, for the reason
    /// ``deliverSessionEvent(_:from:)`` exists: an operation's awaits give a
    /// `didStopWithError`, a force stop or a successor session time to land, and
    /// a phase written over that would claim a `VZVirtualMachine` this instance
    /// no longer holds — leaving a VM nothing can stop, force stop, or start.
    @discardableResult
    func settle(_ phase: VMLifecyclePhase, for sessionID: UUID) -> Bool {
        guard liveSessionID == sessionID else { return false }
        self.phase = phase
        return true
    }

    /// Marks a guest setup as running: a macOS install, or a Linux installer
    /// image being fetched.
    ///
    /// The one way into ``VMLifecyclePhase/installing(sessionID:)``, for both
    /// macOS install paths and the Linux download pipeline. A session the
    /// installer creates is promoted in by ``attachSession(from:)``.
    func beginGuestSetup() {
        enter(.installing(sessionID: nil))
    }

    /// Ends a guest setup that ran no VZ session, so no power-off takes the VM
    /// out of ``beginGuestSetup()`` — the Linux image pipeline, whose caller
    /// chains a Start straight off it.
    func endGuestSetup() {
        enter(.stopped)
    }

    // MARK: - State Helpers

    /// Opens the context one boot attempt's session state lives in, replacing
    /// any prior one, and takes the security scopes its configuration build
    /// needs.
    ///
    /// Called at the top of every bring-up — including an install-time build,
    /// where a pre-install VM can already carry bookmarked external attachments
    /// from settings. The two are one call because a scope with no context to
    /// hold it is a leak, and a context with no scopes cannot build.
    @discardableResult
    func beginSessionContext(bootedIntoRecovery: Bool = false) -> VMSessionContext {
        // A displaced context is released rather than dropped: the boot paths
        // tear down before retrying, so reaching here with one open means a
        // caller skipped that — and the dropped context's VZ session, pipes and
        // security scopes would outlive the last reference to them.
        sessionContext?.tearDown()
        let context = VMSessionContext(
            label: name,
            bootedIntoRecovery: bootedIntoRecovery,
            vsock: VsockFeatureCoordinator(
                instance: self,
                admissionGate: vsockAdmissionGate,
                clipboardDataSink: clipboardDataSink,
                dropDataSink: dropDataSink))
        openRuntimeFileAccess(into: context.fileAccess)
        sessionContext = context
        return context
    }

    /// Takes the pipes and cold-attached removable media a configuration build
    /// produced into the open session context.
    func adoptBuildResult(_ result: ConfigurationBuilder.BuildResult) {
        guard let sessionContext else {
            Self.logger.fault(
                "No session context to adopt a build result for '\(self.name, privacy: .public)'")
            assertionFailure("adoptBuildResult without beginSessionContext for '\(name)'")
            return
        }
        sessionContext.serialInputPipe = result.serialInputPipe
        sessionContext.serialOutputPipe = result.serialOutputPipe
        sessionContext.clipboardInputPipe = result.clipboardInputPipe
        sessionContext.clipboardOutputPipe = result.clipboardOutputPipe
        sessionContext.liveRemovableMedia = result.coldRemovableMedia
    }

    /// Brings a built configuration all the way up: adopts its pipes and media,
    /// creates the `VZVirtualMachine`, and starts the serial, clipboard and
    /// vsock plumbing that rides it.
    ///
    /// The whole of what a boot path does between building a configuration and
    /// telling VZ to run, so a cold boot and a restore cannot drift apart. The
    /// install path stops short of the vsock listeners and stays hand-wired.
    ///
    /// `nil` for the same reason ``attachSession(from:)`` returns `nil`, and the
    /// caller must not proceed to start anything.
    func bringUpSession(with result: ConfigurationBuilder.BuildResult) async -> VMSession? {
        adoptBuildResult(result)
        guard let session = await attachSession(from: result.configuration) else { return nil }
        startSerialReading()
        startClipboardService()
        await startVsockServices()
        return session
    }

    /// Tears the live VM session down and rests the VM at `phase`.
    ///
    /// The two are one call because a phase naming a session that is gone is
    /// exactly the state this type exists to make unrepresentable — so
    /// `restingAt` must name none. A retry that deliberately stays mid-operation
    /// passes the sessionless form of the phase it is in
    /// (``VMLifecyclePhase/starting(sessionID:)`` with `nil`, say).
    func tearDownSession(restingAt phase: VMLifecyclePhase) {
        if let strandedSessionID = phase.sessionID {
            Self.logger.fault(
                "Teardown of '\(self.name, privacy: .public)' asked to rest at a phase naming session \(strandedSessionID, privacy: .public)"
            )
            assertionFailure("tearDownSession(restingAt:) given a phase naming a session")
        }
        sessionContext?.tearDown()
        sessionContext = nil
        self.phase = phase
        // A VM with no session has no display to place, and `.hidden`
        // (headless) has no window whose close would say so.
        displayMode = .inline
        onSessionTornDown?()
    }

    func resetToStopped() {
        tearDownSession(restingAt: .stopped)
        // Reset so the next start lands on the display rather than inheriting
        // a stuck settings mode from the previous session.
        detailPaneMode = .display
        onPoweredOff?()
    }

    /// Creates the VM on its own queue, stores the session, promotes the
    /// in-flight phase to name it, and builds the network-attachment coordinator
    /// for network-enabled configurations.
    ///
    /// The promotion is part of storing the session rather than the caller's
    /// next step: liveness is read off the phase, so a gap between the two would
    /// be a window in which a `VZVirtualMachine` exists and every predicate
    /// answers that none does.
    ///
    /// `nil` when no session context is open, or when the phase admits no
    /// session identity to promote — both programming errors, since every
    /// bring-up path opens a context and stands in an admitting phase before
    /// building the configuration this takes. Either way the just-created
    /// `VZVirtualMachine` is released rather than handed back: a session this
    /// instance does not hold is one nothing can stop, so a caller starting it
    /// would leave the guest running past every liveness predicate, force stop
    /// included.
    func attachSession(from vzConfig: VZVirtualMachineConfiguration) async -> VMSession? {
        // The configuration was assembled off-main and is handed over whole:
        // nothing touches it after the VM is created from it.
        nonisolated(unsafe) let vzConfig = vzConfig
        let session = await VMSession.make(configuration: vzConfig, events: makeSessionEvents())
        guard let sessionContext else {
            Self.logger.fault(
                "No session context to attach a session to for '\(self.name, privacy: .public)'")
            assertionFailure("attachSession without beginSessionContext for '\(name)'")
            return nil
        }
        guard let promoted = phase.naming(session.id) else {
            Self.logger.fault(
                "Session attached to '\(self.name, privacy: .public)' while at \(self.status.rawValue, privacy: .public), which names no session"
            )
            assertionFailure("attachSession from a phase that admits no session identity")
            return nil
        }
        sessionContext.session = session
        phase = promoted
        await setupNetworkAttachmentCoordinator(for: session, in: sessionContext)
        return session
    }

    /// Builds this session's attachment-recovery coordinator, replacing any
    /// prior one.
    private func setupNetworkAttachmentCoordinator(
        for session: VMSession, in context: VMSessionContext
    ) async {
        context.networkAttachmentCoordinator?.stop()
        context.networkAttachmentCoordinator = nil
        context.networkAttachmentPending = false
        guard configuration.networkEnabled, session.hasNetworkDevice else { return }
        let networks = VmnetNetworkService.shared
        let initialPlan = await session.inspectNetworkAttachment { attachment in
            VZNetworkDeviceHandle.plan(of: attachment, in: networks)
        }
        guard self.session === session else { return }
        context.networkAttachmentCoordinator = NetworkAttachmentCoordinator(
            vmName: name,
            device: VZNetworkDeviceHandle(
                session: session, initialPlan: initialPlan, vmnetNetworks: networks),
            interfaces: HostBridgedInterfaceProvider(),
            linkObserver: HostNetworkLinkObserver(),
            isEligible: { [weak self] in self?.hasLiveSession ?? false },
            choice: { [weak self] in self?.configuration.networkChoice },
            onPendingChange: { [weak context] pending in
                context?.networkAttachmentPending = pending
            })
    }

    /// Removes the persisted save file from the bundle, if it exists.
    func removeSaveFile() {
        do {
            try FileManager.default.removeItem(at: saveFileURL)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError
        {
            // File already absent — expected in some flows
        } catch {
            Self.logger.warning(
                "Failed to remove save file for '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Serial Console I/O

    /// Begins reading from the serial output pipe.
    ///
    /// Output is written to the on-disk `serial.log` (size-capped by
    /// `SerialLogWriter`) and tee'd to the `SerialSocketRelay` when enabled.
    func startSerialReading() {
        guard let context = sessionContext, let outputPipe = context.serialOutputPipe else {
            return
        }

        // Created once per session so the readability handler can capture them
        // as `Sendable` locals — the handler must never touch `self` off-actor.
        let writer = SerialLogWriter(
            logURL: bundleLayout.serialLogURL, rotatedURL: bundleLayout.serialLogRotatedURL,
            label: name)
        context.serialLogWriter = writer
        let relay = makeSerialRelay(in: context)

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            writer.write(data)
            relay?.forwardOutput(data)
        }

        Self.logger.info("Serial reading started for '\(self.name, privacy: .public)'")
    }

    /// Creates the per-session serial relay and, when enabled, starts it.
    ///
    /// Also stores it on `context`; returns `nil` when the input pipe is missing.
    private func makeSerialRelay(in context: VMSessionContext) -> SerialSocketRelay? {
        guard let inputPipe = context.serialInputPipe else { return nil }
        let relay = SerialSocketRelay(
            path: Self.serialSocketPath(for: instanceID),
            guestInputWriteHandle: inputPipe.fileHandleForWriting,
            label: name
        )
        context.serialSocketRelay = relay
        if configuration.serialSocketRelayEnabled {
            relay.start()
        }
        return relay
    }

    /// On-disk path for a VM's serial relay socket.
    ///
    /// Short filename under the temporary directory: the VM bundle path exceeds
    /// the 104-byte cap on `sockaddr_un.sun_path`. 16 hex digits of the UUID
    /// keep two VMs from colliding while staying within it.
    static func serialSocketPath(for id: UUID) -> String {
        let short = id.uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("knv-\(short).sock")
    }

    func stopSerialReading() {
        sessionContext?.stopSerialReading()
    }

    // MARK: - Clipboard Service Lifecycle

    /// Starts clipboard sharing if enabled in this configuration.
    ///
    /// Linux uses the SPICE agent over the console-port pipes set up at config
    /// build. macOS constructs its `VsockClipboardService` only when the guest
    /// agent connects to the listener installed in `startVsockServices()`.
    func startClipboardService() {
        // Passthrough is host-side and gated on sharing internally, so it must
        // be refreshed even when sharing is off — hence before the guard.
        defer { refreshClipboardPassthrough() }
        guard configuration.clipboardSharingEnabled else { return }
        switch configuration.guestOS {
        case .linux:
            startSpiceClipboardService()
        case .macOS:
            Self.logger.info(
                "Clipboard sharing armed (vsock) for '\(self.name, privacy: .public)' — awaiting guest agent")
        }
    }

    /// Starts or stops automatic clipboard passthrough to match the current
    /// configuration and session state.
    ///
    /// Host-side only — no guest cooperation and no wire change — so it drives
    /// both transports and works with the clipboard window closed.
    func refreshClipboardPassthrough() {
        guard let context = sessionContext else { return }
        let shouldRun =
            configuration.clipboardSharingEnabled && configuration.clipboardPassthroughEnabled
            && hasLiveVirtualMachine
        if shouldRun {
            let coordinator =
                context.clipboardPassthroughCoordinator
                ?? ClipboardPassthroughCoordinator(
                    instance: self, publisher: hostClipboardPublisher,
                    reporter: clipboardTransfers)
            context.clipboardPassthroughCoordinator = coordinator
            coordinator.start()
        } else {
            context.clipboardPassthroughCoordinator?.stop()
            context.clipboardPassthroughCoordinator = nil
        }
    }

    private func startSpiceClipboardService() {
        guard let context = sessionContext,
            let inputPipe = context.clipboardInputPipe,
            let outputPipe = context.clipboardOutputPipe
        else {
            Self.logger.error("SPICE clipboard pipes not configured for '\(self.name, privacy: .public)'")
            return
        }
        let service = SpiceClipboardService(inputPipe: inputPipe, outputPipe: outputPipe)
        service.start()
        context.clipboardService = service
        Self.logger.info("SPICE clipboard service started for '\(self.name, privacy: .public)'")
    }

    /// Stops and releases the clipboard service and (for SPICE) closes pipe file handles.
    ///
    /// Safe to call when no service is active.
    func stopClipboardService() {
        sessionContext?.stopClipboardService()
    }

    // MARK: - Vsock Service Lifecycle

    /// Installs vsock listeners on the live session's `VZVirtioSocketDevice`.
    ///
    /// A no-op when no socket device is present. Idempotent: any previously
    /// installed listeners are torn down first. The control listener is always
    /// installed; the log, clipboard and drop listeners are gated on
    /// `agentLogForwardingEnabled` / `clipboardSharingEnabled` /
    /// `dropFilesEnabled`.
    func startVsockServices() async {
        stopVsockServices()
        guard let session, session.hasVirtioSocketDevice, let vsock = sessionContext?.vsock
        else { return }

        await session.attach(
            vsock.listenerHosts(for: configuration, sessionID: session.id))
        // Torn down while installing: these hosts live and die with the
        // session that retains them, so nothing is left dangling on a device
        // the teardown already walked — and there is no start to announce.
        guard self.session === session else { return }

        Self.logger.info("Vsock services started for '\(self.name, privacy: .public)'")
    }

    // MARK: - Agent Policy

    /// The policy pushed to a guest with nothing to push through — every
    /// capability off, and the built-in paste ceiling.
    static let disabledAgentPolicy = AgentPolicySnapshot(
        logForwardingEnabled: false,
        clipboardSharingEnabled: false,
        dropFilesEnabled: false,
        clipboardMaxPasteBytes: ClipboardPasteLimit.defaultBytes)

    /// The policy a given configuration produces, combined with the app-wide
    /// clipboard preference.
    ///
    /// The one place a snapshot is built, so the initial Hello push, a live
    /// toggle, and a preference change can never send differently shaped policy.
    func agentPolicySnapshot(for configuration: VMConfiguration) -> AgentPolicySnapshot {
        AgentPolicySnapshot(
            logForwardingEnabled: configuration.agentLogForwardingEnabled,
            clipboardSharingEnabled: configuration.clipboardSharingEnabled,
            dropFilesEnabled: configuration.dropFilesEnabled,
            clipboardMaxPasteBytes: preferences.clipboardMaxPasteBytes)
    }

    /// This instance's current policy.
    var agentPolicySnapshot: AgentPolicySnapshot { agentPolicySnapshot(for: configuration) }

    /// The ceiling the **host** enforces: the user's value, always.
    ///
    /// Each direction has exactly one enforcer, and it is the receiver — the side
    /// whose paste deadline is at risk. This governs guest→host only
    /// (`materializeForCopy` / `pasteBoundSnapshot`); the guest's own
    /// `allowsFileURLPull` governs host→guest, and neither side caps what it
    /// *sends*. So the guest's capability, and the control channel's health, say
    /// nothing about what belongs here: clamping on either would drop the user's
    /// setting over a peer that is only ever the sender in this direction.
    var effectiveClipboardMaxPasteBytes: Int { preferences.clipboardMaxPasteBytes }

    /// Asks any live passthrough session to replay an offer a lower ceiling
    /// refused.
    ///
    /// No-ops when passthrough is off.
    func republishPassthroughIfCeilingRaised() {
        sessionContext?.clipboardPassthroughCoordinator?.republishIfCeilingRaised()
    }

    /// Re-pushes the current policy to a connected guest agent.
    ///
    /// For app-wide settings that reach the guest but produce no `VMConfiguration`
    /// diff for `applyLivePolicy` to notice. No-ops with no control channel — the
    /// next Hello sends the current snapshot anyway.
    func resendAgentPolicy() {
        vsockControlService?.sendPolicyUpdate(agentPolicySnapshot)
    }

    /// Builds the control service for one accepted channel, wired to this
    /// instance's policy, agent-info and guest-suspension hooks. Channel loss is
    /// the accept site's to wire, uniformly for every feature.
    ///
    /// Every hook reads through `self` lazily, so all three track live
    /// configuration edits and pause/resume without being re-pushed.
    func makeControlService(for channel: VsockChannel) -> VsockControlService {
        VsockControlService(
            channel: channel,
            label: name,
            policyProvider: { [weak self] in
                self?.agentPolicySnapshot ?? Self.disabledAgentPolicy
            },
            onAgentInfoObserved: { [weak self] info in
                self?.recordObservedAgentInfo(info)
            },
            isGuestSuspended: { [weak self] in self?.isLivePaused ?? false },
            admissionGate: vsockAdmissionGate)
    }

    // MARK: - Agent Post-Start Watchdog

    /// Default grace period before the post-start watchdog fires.
    static let defaultAgentPostStartGrace: Duration = .seconds(120)

    /// Starts a one-shot timer that flips `agentExpectedButMissing = true` if
    /// the guest agent doesn't say Hello within `grace`.
    ///
    /// Armed after a start, a hot resume, or an accepted control channel, and
    /// again whenever the control channel dies under us, so a mid-session
    /// disappearance escalates the same way a no-show after boot does. A no-op
    /// unless the guest is macOS, the VM is running (a paused guest isn't
    /// executing, so its silence proves nothing), the session didn't boot into
    /// Recovery (which never runs the agent), an agent has been seen before on
    /// this VM, the agent isn't already connected, no install is in progress,
    /// and no watchdog is already armed. Cancelled by any inbound Hello, by a
    /// pause, and by `tearDownSession`.
    func startAgentPostStartWatchdog(grace: Duration = VMInstance.defaultAgentPostStartGrace) {
        guard let context = sessionContext else { return }
        guard configuration.guestOS == .macOS else { return }
        guard !context.bootedIntoRecovery else { return }
        guard status == .running else { return }
        guard configuration.lastSeenAgentVersion != nil else { return }
        guard context.vsock.control?.agentVersion == nil else { return }
        guard setupState == nil else { return }
        guard context.agentPostStartTask == nil else { return }

        context.agentPostStartGeneration &+= 1
        let generation = context.agentPostStartGeneration
        Self.logger.debug(
            "Agent arrival watchdog armed for '\(self.name, privacy: .public)' (grace=\(grace, privacy: .public))"
        )
        // The context is captured weakly: a strong hold would keep this
        // session's `VZVirtualMachine`, pipes and services alive for the whole
        // grace period after a teardown.
        context.agentPostStartTask = Task { [weak self, weak context] in
            do {
                try await Task.sleep(for: grace)
            } catch {
                return
            }
            // Both halves of the disowning check: the context this was armed on
            // must still be the live one, and its generation must still be the
            // one armed here. Generation alone is an ABA test across sessions —
            // each context counts from zero — and identity alone is one within a
            // session, so either on its own lets a stale task fire
            // `.expectedMissing` before a successor's grace elapsed and clear
            // that successor's slot on the way out.
            guard let self, let armed = context, armed === self.sessionContext,
                armed.agentPostStartGeneration == generation
            else { return }
            if armed.vsock.control?.agentVersion == nil {
                Self.logger.notice(
                    "Guest agent expected (last seen \(self.configuration.lastSeenAgentVersion ?? "?", privacy: .public)) but never reconnected for '\(self.name, privacy: .public)' — surfacing reinstall affordance"
                )
                armed.agentExpectedButMissing = true
                // An agent that never showed up at all outranks the nudge the
                // user silenced — reset the dismissal so a future `.waiting`
                // surfaces normally. The reported guest OS version goes with
                // it: nothing vouched for it this session, and "Unknown" beats
                // a stale value. Both stay untouched when the agent did say
                // Hello earlier in this session: it demonstrably exists, and
                // reversing a preference nothing restores needs better evidence
                // than one dropped channel.
                if !armed.hasSeenAgentThisSession,
                    self.configuration.agentInstallNudgeDismissed
                        || self.configuration.lastSeenGuestOSVersion != nil
                {
                    self.performConfigurationMutation {
                        $0.agentInstallNudgeDismissed = false
                        $0.lastSeenGuestOSVersion = nil
                    }
                }
            }
            armed.agentPostStartTask = nil
        }
    }

    /// Cancels the agent-arrival watchdog if armed.
    ///
    /// Does not clear `agentExpectedButMissing` — callers do that explicitly.
    func cancelAgentPostStartWatchdog() {
        sessionContext?.cancelAgentPostStartWatchdog()
    }

    #if DEBUG
    /// The in-flight post-start watchdog task, or `nil` when none is armed.
    ///
    /// Test-only seam: tests await its completion rather than polling
    /// `agentExpectedButMissing`.
    var agentPostStartTaskForTesting: Task<Void, Never>? { sessionContext?.agentPostStartTask }
    #endif

    /// Reacts to a `Hello` whose `agent_version` is non-empty.
    ///
    /// Empty agent versions are filtered upstream by `VsockControlService`:
    /// persisting "" would silence both the install nudge and the watchdog. The
    /// OS version has no such filter — a `nil` overwrites a stored value, so a
    /// guest that stops vouching for its version reads Unknown, not stale.
    func recordObservedAgentInfo(_ info: ObservedAgentInfo) {
        // Any Hello proves the agent is alive, so clear the watchdog state
        // before the changed guards below.
        cancelAgentPostStartWatchdog()
        sessionContext?.agentExpectedButMissing = false
        sessionContext?.hasSeenAgentThisSession = true
        // Skip the no-op write: a `config.json` rewrite on every Hello would
        // re-fire `VMDirectoryWatcher` reconcile.
        let agentVersionChanged = configuration.lastSeenAgentVersion != info.agentVersion
        if agentVersionChanged || configuration.lastSeenGuestOSVersion != info.osVersion {
            performConfigurationMutation {
                $0.lastSeenAgentVersion = info.agentVersion
                $0.lastSeenGuestOSVersion = info.osVersion
            }
        }
        // Only on an agent-version change: a same-version reconnect (e.g. while
        // the disk is mounted to run uninstall.command) must not yank the
        // installer disk out from under the user.
        guard agentVersionChanged else { return }
        if AgentStatus.isObservedVersionCurrent(info.agentVersion, bundled: KernovaMacOSAgentInfo.bundledVersion) {
            onAgentBecameCurrent?()
        }
    }

    /// Stops every vsock service and unbinds the listeners that fed them —
    /// see ``VMSessionContext/stopVsockServices()``.
    func stopVsockServices() {
        sessionContext?.stopVsockServices()
    }

    /// Reacts to a configuration change while the VM is running by installing
    /// or tearing down vsock listeners and pushing a fresh `PolicyUpdate` to
    /// the guest agent.
    ///
    /// Only `agentLogForwardingEnabled`, `clipboardSharingEnabled` and
    /// `dropFilesEnabled` are honored at runtime, and the clipboard branch is
    /// skipped for Linux guests: the SPICE port must be declared at config-build
    /// time, so sharing is restart-only there.
    func applyLivePolicy(oldConfig: VMConfiguration, newConfig: VMConfiguration) {
        guard status == .running || status == .paused else { return }

        // Ahead of the live-VM guard: the coordinator exists exactly while the
        // session has a network device, which is the guard this hot swap needs.
        if oldConfig.networkEnabled != newConfig.networkEnabled
            || oldConfig.networkMode != newConfig.networkMode
            || oldConfig.bridgedInterfaceIdentifier != newConfig.bridgedInterfaceIdentifier
        {
            networkAttachmentCoordinator?.configurationChanged()
        }

        guard hasLiveVirtualMachine else { return }

        // Host-only (no vsock device), so handle it before the socket-device
        // guard returns early for guests without a `VZVirtioSocketDevice`.
        if oldConfig.serialSocketRelayEnabled != newConfig.serialSocketRelayEnabled {
            applyLiveSerialRelayPolicy(enabled: newConfig.serialSocketRelayEnabled)
        }

        // Likewise host-side only, so apply it before the socket-device guard —
        // it must work for Linux/SPICE guests too.
        if oldConfig.clipboardPassthroughEnabled != newConfig.clipboardPassthroughEnabled
            || oldConfig.clipboardSharingEnabled != newConfig.clipboardSharingEnabled
        {
            refreshClipboardPassthrough()
        }

        guard let context = sessionContext, let session = context.session,
            session.hasVirtioSocketDevice
        else { return }

        context.vsock.applyLivePolicy(
            oldConfig: oldConfig, newConfig: newConfig, on: session)
    }

    /// Starts or stops the host-side serial relay live.
    ///
    /// Flips the socket on the session's existing relay object — the output
    /// readability handler already holds a reference to it.
    private func applyLiveSerialRelayPolicy(enabled: Bool) {
        if enabled {
            sessionContext?.serialSocketRelay?.start()
        } else {
            sessionContext?.serialSocketRelay?.stop()
        }
        Self.logger.notice(
            "Serial relay \(enabled ? "enabled" : "disabled", privacy: .public) live for '\(self.name, privacy: .public)'"
        )
    }
}
