import Foundation
import KernovaKit
import KernovaLogging
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
final class VMInstance: VMActivityOwner {
    // MARK: - Properties

    let instanceID: UUID

    /// The bundle this VM's state and machine files are written through.
    ///
    /// Replaced only by ``rebind(to:)``, when the bundle has moved.
    private(set) var bundle: VMBundle

    /// The configuration committed to the bundle.
    var configuration: VMConfiguration { bundle.configuration }

    /// Kernova's own state for this VM, as committed to `host-state.json`.
    var hostState: VMHostState { bundle.hostState }

    /// ``configuration`` and ``hostState`` as one value.
    var settings: VMSettings { VMSettings(configuration: configuration, hostState: hostState) }

    /// Where this VM is in its lifecycle, and the live session it holds.
    let activity: VMActivity

    var bundleURL: URL { bundle.url }

    /// Progress of the guest setup running for this VM — a macOS install,
    /// or a Linux installer image being fetched and verified.
    var setupState: GuestSetupState?

    /// The named restore points this VM's bundle holds, as committed to
    /// `Snapshots/manifest.json`.
    var snapshotManifest: VMSnapshotManifest { bundle.snapshotManifest }

    /// The host USB accessories this VM takes back on its own, as committed to
    /// `usb-accessories.json`.
    var usbPairings: USBAccessoryPairingSet { bundle.usbPairings }

    /// Where this VM's display currently lives.
    ///
    /// ``VMDisplayPlacementController`` owns every transition; the model writes
    /// this only once the session ends (``sessionDidEnd()``), to the sole mode a
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
    @ObservationIgnored let hostClipboardPublisher = HostClipboardPublisher(
        stagingRoot: ClipboardFileStaging.processRoot)

    /// Where this VM's clipboard and drop producers publish, and the owner of the
    /// value below.
    ///
    /// One per VM rather than per connection: a promise a clipboard service
    /// published outlives that service, so a refusal belongs to the VM.
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
    /// guest agent connect (``lastSeenAgentVersion`` is not `nil`), and a
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

    /// Routes a host-side mutation of this instance's configuration through
    /// ``VMLibrary/updateConfiguration(of:mutate:)``, answering what that
    /// answers.
    ///
    /// Wired by `VMLibrary.wireHooks(for:)`; `nil` for instances created
    /// outside a library.
    @ObservationIgnored
    var onUpdateConfiguration: (@MainActor ((inout VMConfiguration) -> Void) -> VMLibrary.SettingsWrite)?

    /// Routes a host-side mutation of both halves of this instance's settings
    /// through ``VMLibrary/updateSettings(of:configuration:hostState:)``,
    /// answering what that answers; wired alongside ``onUpdateConfiguration``.
    @ObservationIgnored
    var onUpdateSettings:
        (
            @MainActor ((inout VMConfiguration) -> Void, (inout VMHostState) -> Void)
                -> VMLibrary.SettingsWrite
        )?

    /// Fired when the guest agent handshakes a new version that is current
    /// (matches or exceeds what the host bundles) — i.e. an install/update just
    /// completed.
    ///
    /// The host uses it to auto-eject the guest-agent installer disk.
    @ObservationIgnored var onAgentBecameCurrent: (@MainActor () -> Void)?

    /// Applies a configuration mutation through ``onUpdateConfiguration``,
    /// answering how the write ended. An instance no library has wired changes
    /// nothing and is refused as ``VMLibrary/SettingsRefusal/noLibrary``.
    @discardableResult
    func performConfigurationMutation(_ mutate: (inout VMConfiguration) -> Void)
        -> VMLibrary.SettingsWrite
    {
        onUpdateConfiguration?(mutate) ?? .refused(.noLibrary)
    }

    /// ``performConfigurationMutation(_:)`` for a mutation of both halves of
    /// the settings, through ``onUpdateSettings``.
    @discardableResult
    func performSettingsMutation(
        configuration: (inout VMConfiguration) -> Void, hostState: (inout VMHostState) -> Void
    ) -> VMLibrary.SettingsWrite {
        onUpdateSettings?(configuration, hostState) ?? .refused(.noLibrary)
    }

    // MARK: - Session Projection

    /// The guest agent version this VM last reported: this session's Hello when
    /// one arrived, the committed record otherwise.
    var lastSeenAgentVersion: String? {
        if let observed = sessionContext?.observedAgentInfo { return observed.agentVersion }
        return configuration.lastSeenAgentVersion
    }

    /// The guest OS version this VM last reported, on the same terms as
    /// ``lastSeenAgentVersion`` — and unknown once this session's watchdog has
    /// found no agent, since nothing vouched for the recorded one.
    var reportedGuestOSVersion: String? {
        if let observed = sessionContext?.observedAgentInfo { return observed.osVersion }
        if sessionContext?.agentExpectedButMissing == true { return nil }
        return configuration.lastSeenGuestOSVersion
    }

    /// The committed configuration with what this session re-derived laid over
    /// it: the file references its boot healed, and what the guest agent
    /// reported (``lastSeenAgentVersion``, ``reportedGuestOSVersion``).
    ///
    /// What a configuration build and every guest-version floor read, so each
    /// acts on what the session knows whether or not the write recording it
    /// landed.
    var effectiveConfiguration: VMConfiguration {
        var config = configuration
        guard let context = sessionContext else { return config }
        for heal in context.heals {
            config.healExternalReference(heal.reference, movedTo: heal.path, bookmark: heal.bookmark)
        }
        config.lastSeenAgentVersion = lastSeenAgentVersion
        config.lastSeenGuestOSVersion = reportedGuestOSVersion
        return config
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
                lastSeenAgentVersion: lastSeenAgentVersion,
                isInLiveSession: hasLiveVirtualMachine,
                agentExpectedButMissing: agentExpectedButMissing
            )
        case .linux:
            return (clipboardService as? SpiceClipboardService)?.agentStatus ?? .waiting
        }
    }

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMInstance")

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

    var bundleLayout: VMBundleLayout { VMBundleLayout(bundleURL: bundleURL) }

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

    /// A VM whose bundle is on disk.
    init(bundle: VMBundle, phase: VMLifecyclePhase, preferences: AppPreferences) {
        self.instanceID = bundle.configuration.id
        self.bundle = bundle
        self.activity = VMActivity(phase: phase)
        self.preferences = preferences
        activity.owner = self
        clipboardTransfers.onReportChanged = { [weak self] report in
            self?.clipboardTransferReport = report
        }
    }

    /// Points this VM at `bundle`, read from where its bundle now lives.
    func rebind(to bundle: VMBundle) {
        guard bundle.configuration.id == instanceID else {
            assertionFailure("rebind of '\(name)' to a bundle of another VM")
            return
        }
        self.bundle = bundle
    }

    // MARK: - VM Bundle Paths (forwarded from VMBundleLayout)

    /// ``VMConfiguration/effectiveStorageDisks(layout:)`` for this instance's bundle.
    var effectiveStorageDisks: [StorageDisk] {
        configuration.effectiveStorageDisks(layout: bundleLayout)
    }

    /// The in-bundle (internal) disks, shown read-only in the delete sheet's
    /// "Removed with the VM" section.
    var bundledStorageDisks: [StorageDisk] {
        effectiveStorageDisks.filter(\.isInternal)
    }

    /// `true` when `disk` is the only storage disk this VM has — the one a
    /// removal refuses, whichever file backs it.
    func isSoleStorageDisk(_ disk: StorageDisk) -> Bool {
        let disks = effectiveStorageDisks
        return disks.count == 1 && disks[0].id == disk.id
    }

    /// `true` when the bundled Guest Agent installer DMG is in this VM's
    /// `removableMedia` list (live-attached, pending attach, or cold).
    var hasGuestAgentInstallerMounted: Bool {
        guard let path = KernovaMacOSAgentInfo.installerPath else { return false }
        return (configuration.removableMedia ?? []).contains { $0.path == path }
    }

    var diskImageURL: URL { bundleLayout.diskImageURL }
    var machineIdentifierURL: URL { bundleLayout.machineIdentifierURL }
    var serialLogURL: URL { bundleLayout.serialLogURL }

    /// Whether the bundle holds a suspend slot.
    var hasSaveFile: Bool { bundleLayout.hasSaveFile }

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
    var liveRemovableMedia: [RemovableMediaDeviceInfo] { sessionContext?.liveRemovableMedia ?? [] }

    /// Records a device that was just attached, live, on the session
    /// `sessionID` names.
    ///
    /// Dropped and logged, rather than asserting, once that session is no
    /// longer the live one — see ``VMActivity/liveSessionID``:
    /// `VMLibrary.runRemovableMediaReconciliation` awaits the framework
    /// attach call, and a power-off (or a power-off and restart) landing on
    /// main during that suspension resolves the continuation against a VM this
    /// record no longer describes — the same race its own
    /// `RemovableMediaDeviceError.noVirtualMachine` handling already treats as a normal
    /// bail, not a programming error.
    func recordAttachedMedia(_ info: RemovableMediaDeviceInfo, for sessionID: UUID) {
        guard let context = sessionWriteTarget(for: sessionID, deviceID: info.id, "attached-media record")
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
        guard let context = sessionWriteTarget(for: sessionID, deviceID: deviceID, "detached-media record")
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
        guard let context = sessionWriteTarget(for: sessionID, deviceID: deviceID, "media scope") else {
            scope.release()
            return
        }
        context.fileAccess.addHotAttach(id: deviceID, scope)
    }

    // MARK: - Runtime USB Accessories

    /// Host USB accessories passed through to this VM's guest; cleared on
    /// stop/teardown.
    var liveUSBAccessories: [AttachedUSBAccessory] { sessionContext?.liveUSBAccessories ?? [] }

    /// Records an accessory that was just attached, live, on the session
    /// `sessionID` names.
    ///
    /// Dropped and logged once that session is no longer the live one — see
    /// ``recordAttachedMedia(_:for:)`` for why that is a normal bail.
    func recordAttachedAccessory(_ attached: AttachedUSBAccessory, for sessionID: UUID) {
        guard
            let context = sessionWriteTarget(
                for: sessionID, deviceID: attached.deviceID, "attached-accessory record")
        else { return }
        context.liveUSBAccessories.append(attached)
    }

    /// Drops an accessory's tracking entry — on detach, on a surprise unplug,
    /// or before a save.
    ///
    /// A no-op, logged, when `sessionID` no longer names the live session.
    /// Unlike removable media there is no security-scoped grant to release:
    /// the user's assignment is macOS's to hold, not Kernova's.
    func forgetAttachedAccessory(deviceID: UUID, for sessionID: UUID) {
        guard
            let context = sessionWriteTarget(
                for: sessionID, deviceID: deviceID, "detached-accessory record")
        else { return }
        context.liveUSBAccessories.removeAll { $0.deviceID == deviceID }
    }

    /// The context a live-session write issued against `sessionID` belongs to,
    /// or `nil` — logged — when that session has been released.
    ///
    /// `deviceID` names the device the write concerns, when it concerns one;
    /// it only shapes the log line.
    private func sessionWriteTarget(
        for sessionID: UUID,
        deviceID: UUID? = nil,
        _ what: StaticString
    ) -> VMSessionContext? {
        guard let sessionContext, liveSessionID == sessionID else {
            let device = deviceID.map { " device \($0)" } ?? ""
            #log(
                Self.logger, .notice,
                "Dropping \(what, privacy: .public) for '\(self.name, privacy: .public)'\(device, privacy: .public): session \(sessionID, privacy: .public) is no longer live"
            )
            return nil
        }
        return sessionContext
    }

    // MARK: - Activity

    // Forwarded to ``activity``, which documents each.

    var phase: VMLifecyclePhase { activity.phase }
    var status: VMStatus { activity.status }
    var errorMessage: String? { activity.errorMessage }
    var sessionContext: VMSessionContext? { activity.sessionContext }
    var session: VMSession? { activity.session }
    var liveSessionID: UUID? { activity.liveSessionID }
    var hasLiveVirtualMachine: Bool { activity.hasLiveVirtualMachine }
    var hasLiveSession: Bool { activity.hasLiveSession }
    var attachableSessionID: UUID? { activity.attachableSessionID }
    var isColdPaused: Bool { activity.isColdPaused }
    var isLivePaused: Bool { activity.isLivePaused }
    var holdsLiveIdentity: Bool { activity.holdsLiveIdentity }
    var isAtRest: Bool { activity.isAtRest }
    var isKeepingAppAlive: Bool { activity.isKeepingAppAlive }
    var hasActiveDisplay: Bool { activity.hasActiveDisplay }

    var onPoweredOff: (@MainActor () -> Void)? {
        get { activity.onPoweredOff }
        set { activity.onPoweredOff = newValue }
    }

    var onSessionBecameAttachable: (@MainActor () -> Void)? {
        get { activity.onSessionBecameAttachable }
        set { activity.onSessionBecameAttachable = newValue }
    }

    func restingPhase(withoutSlot fallback: VMRestPhase) -> VMLifecyclePhase {
        activity.restingPhase(withoutSlot: fallback)
    }

    func deliverSessionEvent(_ event: VMSessionEvent, from sessionID: UUID) {
        activity.deliverSessionEvent(event, from: sessionID)
    }

    func handleSessionEvent(_ event: VMSessionEvent) {
        activity.handleSessionEvent(event)
    }

    func adoptBuildResult(
        _ bringUp: borrowing VMBringUpContext, _ result: ConfigurationBuilder.BuildResult
    ) {
        activity.adoptBuildResult(bringUp, result)
    }

    // MARK: - Admission Facts

    /// What the library contributes to this VM's admission — wired by
    /// `VMLibrary.wireHooks(for:)`. An instance outside a library has no
    /// peers, no clone in flight, no USB passthrough, and no termination.
    @ObservationIgnored weak var peers: (any VMAdmissionPeers)?

    var admissionFacts: VMAdmission.Facts {
        VMAdmission.Facts(
            hasSaveFile: hasSaveFile,
            hasSnapshots: !snapshotManifest.isEmpty,
            guestOS: configuration.guestOS,
            networkEnabled: configuration.networkEnabled,
            clipboardSharingEnabled: configuration.clipboardSharingEnabled,
            hasPendingGuestSetup: configuration.pendingGuestSetup != nil,
            usbSupported: peers?.supportsUSBAccessories ?? false,
            cloneInFlight: peers?.hasCloneInFlight(from: self) ?? false,
            identityConflict: nil,
            terminating: peers?.isTerminating ?? false)
    }

    func identityConflict(for kind: VMBringUpKind) -> VMIdentityConflict? {
        peers?.identityConflict(for: self, bringingUp: configuration(broughtUpBy: kind))
    }

    /// The configuration `kind` puts in front of VZ: this VM's own, except for
    /// a revert, which lands the snapshot's address
    /// (``VMConfiguration/adoptingSnapshotState(_:)`` keeps only the machine
    /// identity across).
    private func configuration(broughtUpBy kind: VMBringUpKind) -> VMConfiguration {
        guard case .reverting(let snapshotID, _) = kind,
            let snapshot = snapshotManifest.snapshot(id: snapshotID)
        else { return configuration }
        var landing = configuration
        landing.macAddress = snapshot.macAddress
        return landing
    }

    /// `true` when the bundle holds a saved state and nothing is live — the VM
    /// a Resume restores and a Discard Saved State empties, whatever phase it
    /// rests at.
    ///
    /// The file rather than the phase, because the two can disagree: a
    /// bring-up that gives up before the restore leaves the slot exactly as it
    /// found it, however that failure was classified.
    var holdsSuspendedSession: Bool { isAtRest && hasSaveFile }

    /// How a capture started right now would be taken, or `nil` when the VM is
    /// in no state to capture — see ``VMAdmission/captureMode(phase:facts:)``.
    var snapshotCaptureMode: VMSnapshotCaptureMode? {
        VMAdmission.captureMode(phase: phase, facts: admissionFacts)
    }

    // MARK: - Wire Projection

    /// This VM as any refusal or listing names it.
    ///
    /// The address is a parameter because only ``GuestAddressObserver``
    /// resolves one, and both callers already hold it — so a summary is built
    /// one way whichever of them is naming the VM.
    func summary(ipAddress: GuestIPAddress) -> VMSummary {
        VMSummary(id: instanceID, name: name, status: status.rawValue, ipAddress: ipAddress)
    }

    // MARK: - Ephemeral Mode

    /// The snapshot a power-off returns this VM to, or `nil` when Ephemeral
    /// Mode is off or names a snapshot the manifest no longer lists.
    ///
    /// The one read every ephemeral path gates on, so a mode left on with a
    /// baseline that has gone reverts nothing rather than failing at power-off.
    var ephemeralBaselineSnapshot: VMSnapshot? {
        guard hostState.ephemeralModeEnabled,
            let id = hostState.ephemeralBaselineSnapshotID
        else { return nil }
        return snapshotManifest.snapshot(id: id)
    }

    /// `true` while a session this VM's baseline will discard is in memory —
    /// what the running Ephemeral marker reports.
    var hasLiveEphemeralSession: Bool {
        ephemeralBaselineSnapshot != nil && hasLiveVirtualMachine
    }

    /// `true` when this VM is resting on its Ephemeral baseline's own saved
    /// state — the state a revert produces, so reverting again changes nothing.
    ///
    /// Read as a computed value rather than tracked: the bundle's suspend slot
    /// only changes as the VM changes phase — a suspend writes it, a discard
    /// removes it, a revert clones the baseline's in — so an observer tracking
    /// `phase` through the guard below re-reads this at every moment it can
    /// differ.
    var isRestingAtEphemeralBaseline: Bool {
        guard holdsSuspendedSession, let baseline = ephemeralBaselineSnapshot else { return false }
        return bundleLayout.saveFileIsCopyOfSnapshot(id: baseline.id)
    }

    /// `true` when `snapshot` is pinned as this VM's Ephemeral baseline, which
    /// bars deleting it.
    func isEphemeralBaseline(_ snapshot: VMSnapshot) -> Bool {
        ephemeralBaselineSnapshot?.id == snapshot.id
    }

    var isInFullscreen: Bool { displayMode == .fullscreen }

    /// `true` when the display is not hosted inline — pop-out, fullscreen, or
    /// closed-while-headless (`.hidden`), all of which offer "Pop In".
    var isDisplayDetached: Bool { displayMode != .inline }

    // MARK: - Session Lifecycle

    /// Opens the context one boot attempt's session state lives in, and takes
    /// the security scopes its configuration build needs.
    ///
    /// Called at the top of every bring-up — including an install-time build,
    /// where a pre-install VM can already carry bookmarked external attachments
    /// from settings. The two are one call because a scope with no context to
    /// hold it is a leak, and a context with no scopes cannot build.
    @discardableResult
    func beginSessionContext(
        _ bringUp: borrowing VMBringUpContext, bootedIntoRecovery: Bool = false
    ) -> VMSessionContext {
        activity.beginSessionContext(bringUp) {
            makeSessionContext(bootedIntoRecovery: bootedIntoRecovery)
        }
    }

    #if DEBUG
    /// ``beginSessionContext(_:bootedIntoRecovery:)`` with no bring-up behind
    /// it, replacing and releasing any prior context; tests only.
    @discardableResult
    func beginSessionContextForTesting(bootedIntoRecovery: Bool = false) -> VMSessionContext {
        activity.installSessionContextForTesting {
            makeSessionContext(bootedIntoRecovery: bootedIntoRecovery)
        }
    }
    #endif

    private func makeSessionContext(bootedIntoRecovery: Bool) -> VMSessionContext {
        let context = VMSessionContext(
            label: name,
            bootedIntoRecovery: bootedIntoRecovery,
            vsock: VsockFeatureCoordinator(
                instance: self,
                admissionGate: vsockAdmissionGate,
                clipboardDataSink: clipboardDataSink,
                dropDataSink: dropDataSink))
        openRuntimeFileAccess(into: context)
        return context
    }

    /// Brings a built configuration all the way up: adopts its pipes and media,
    /// creates the `VZVirtualMachine`, and starts the serial, clipboard and
    /// vsock plumbing that rides it.
    ///
    /// The whole of what a boot path does between building a configuration and
    /// telling VZ to run, so a cold boot and a restore cannot drift apart. The
    /// install path stops short of the vsock listeners and stays hand-wired.
    ///
    /// `nil` for the same reason ``attachSession(_:from:)`` returns `nil`, and
    /// the caller must not proceed to start anything.
    func bringUpSession(
        _ context: borrowing VMBringUpContext, with result: ConfigurationBuilder.BuildResult
    ) async -> VMSession? {
        adoptBuildResult(context, result)
        guard let session = await attachSession(context, from: result) else { return nil }
        startSerialReading()
        startClipboardService()
        await startVsockServices()
        return session
    }

    /// Attaches the session created from `result`
    /// (``VMActivity/beginSession(_:from:)``) and builds the network-attachment
    /// coordinator for network-enabled configurations.
    ///
    /// `nil` exactly when ``VMActivity/beginSession(_:from:)`` is.
    func attachSession(
        _ context: borrowing VMBringUpContext, from result: ConfigurationBuilder.BuildResult
    ) async -> VMSession? {
        guard let attached = await activity.beginSession(context, from: result) else { return nil }
        await setupNetworkAttachmentCoordinator(
            for: attached.session, in: attached.context, vmnetNetworks: result.vmnetNetworks,
            entitlements: result.entitlements)
        return attached.session
    }

    /// Builds this session's attachment-recovery coordinator, replacing any
    /// prior one.
    private func setupNetworkAttachmentCoordinator(
        for session: VMSession, in context: VMSessionContext,
        vmnetNetworks networks: any VmnetNetworkProviding, entitlements: EntitlementService
    ) async {
        context.networkAttachmentCoordinator?.stop()
        context.networkAttachmentCoordinator = nil
        context.networkAttachmentPending = false
        guard configuration.networkEnabled, session.hasNetworkDevice else { return }
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
            vmnetNetworks: networks,
            isVMNetworkingEntitled: entitlements.hasVMNetworking,
            isEligible: { [weak self] in self?.hasLiveSession ?? false },
            choice: { [weak self] in self?.configuration.networkChoice },
            onPendingChange: { [weak context] pending in
                context?.networkAttachmentPending = pending
            })
    }

    // MARK: - Activity Owner

    func sessionDidEnd() {
        // A VM with no session has no display to place, and `.hidden`
        // (headless) has no window whose close would say so.
        displayMode = .inline
    }

    func guestDidPowerOff() {
        // Reset so the next start lands on the display rather than inheriting
        // a stuck settings mode from the previous session.
        detailPaneMode = .display
    }

    func operationDidSettleRunning(_ kind: VMOperationKind) {
        switch kind {
        case .bringUp(.guestStart(.starting)), .resuming:
            activateNetworkAttachment()
            startAgentPostStartWatchdog()
        case .bringUp(.guestStart(.restoringSavedState)), .bringUp(.reverting):
            // Arms no watchdog: a restore resumes whatever guest state was
            // frozen, which may be a Recovery session that never runs the
            // agent, and no host-side flag survives the save to say which.
            // The accept path arms once a control channel actually shows up.
            activateNetworkAttachment()
        case .bringUp(.settingUp), .pausing, .saving, .capturingSnapshot, .deletingSnapshot,
            .attachingUSB, .detachingUSB, .reconcilingMedia, .forceStopping,
            .discardingSavedState, .deleting, .copyingOut:
            break
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

        #log(Self.logger, .info, "Serial reading started for '\(self.name, privacy: .public)'")
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
            #log(
                Self.logger, .info,
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
        let shouldRun = configuration.clipboardPassthroughIsEffective && hasLiveVirtualMachine
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
            #log(Self.logger, .error, "SPICE clipboard pipes not configured for '\(self.name, privacy: .public)'")
            return
        }
        let service = SpiceClipboardService(inputPipe: inputPipe, outputPipe: outputPipe)
        service.start()
        context.clipboardService = service
        #log(Self.logger, .info, "SPICE clipboard service started for '\(self.name, privacy: .public)'")
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

        #log(Self.logger, .info, "Vsock services started for '\(self.name, privacy: .public)'")
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
    /// pause, and by the session's teardown.
    func startAgentPostStartWatchdog(grace: Duration = VMInstance.defaultAgentPostStartGrace) {
        guard let context = sessionContext else { return }
        guard configuration.guestOS == .macOS else { return }
        guard !context.bootedIntoRecovery else { return }
        guard status == .running else { return }
        guard lastSeenAgentVersion != nil else { return }
        guard context.vsock.control?.agentVersion == nil else { return }
        guard setupState == nil else { return }
        guard context.agentPostStartTask == nil else { return }

        context.agentPostStartGeneration &+= 1
        let generation = context.agentPostStartGeneration
        #log(
            Self.logger, .debug,
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
                #log(
                    Self.logger, .notice,
                    "Guest agent expected (last seen \(self.lastSeenAgentVersion ?? "?", privacy: .public)) but never reconnected for '\(self.name, privacy: .public)' — surfacing reinstall affordance"
                )
                // Set first: it is also what ``reportedGuestOSVersion`` reads
                // as unknown for the rest of the session, whether or not the
                // write below lands — and a write that fails is attempted
                // again by the next session's watchdog.
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
                    self.hostState.agentInstallNudgeDismissed
                        || self.configuration.lastSeenGuestOSVersion != nil
                {
                    self.performSettingsMutation(
                        configuration: { $0.lastSeenGuestOSVersion = nil },
                        hostState: { $0.agentInstallNudgeDismissed = false })
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
        let agentVersionChanged = lastSeenAgentVersion != info.agentVersion
        sessionContext?.agentExpectedButMissing = false
        sessionContext?.hasSeenAgentThisSession = true
        // The session holds what the guest reported, so every surface shows it
        // whether or not the write below lands; the next Hello that differs
        // from the committed record writes again.
        sessionContext?.observedAgentInfo = info
        // Skip the no-op write: a `config.json` rewrite on every Hello would
        // re-fire `VMDirectoryWatcher` reconcile.
        if configuration.lastSeenAgentVersion != info.agentVersion
            || configuration.lastSeenGuestOSVersion != info.osVersion
        {
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
        #log(
            Self.logger, .notice,
            "Serial relay \(enabled ? "enabled" : "disabled", privacy: .public) live for '\(self.name, privacy: .public)'"
        )
    }
}
