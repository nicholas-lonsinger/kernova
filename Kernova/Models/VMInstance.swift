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
    var status: VMStatus

    /// The live VM's isolation domain — the only type that calls into the
    /// `VZVirtualMachine` and its device objects.
    private(set) var session: VMSession?

    let bundleURL: URL

    /// Security-scoped access grants held for the live session; populated by
    /// `openRuntimeFileAccess()` at boot, drained in `tearDownSession()`.
    let runtimeFileAccess = RuntimeFileAccess()

    /// Progress of the guest setup running for this VM — a macOS install,
    /// or a Linux installer image being fetched and verified.
    var setupState: GuestSetupState?

    /// The guest-setup pipeline in flight, owned by `VMLibraryViewModel`.
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

    var errorMessage: String?

    var displayMode: VMDisplayMode = .inline

    var detailPaneMode: DetailPaneMode = .display

    // MARK: - Clipboard Sharing

    /// Bidirectional pipes for the SPICE clipboard console port (Linux guests only).
    var clipboardInputPipe: Pipe?
    var clipboardOutputPipe: Pipe?

    /// Active clipboard service: `SpiceClipboardService` for Linux,
    /// `VsockClipboardService` for macOS.
    ///
    /// Nil on macOS until the guest agent connects.
    var clipboardService: (any ClipboardServicing)?

    /// Host-pasteboard writer shared by the clipboard window's "Copy to Mac" and
    /// the passthrough coordinator.
    ///
    /// One per VM so echo suppression sees both writers — the coordinator's poll
    /// skips whatever change count this publisher last produced.
    @ObservationIgnored let hostClipboardPublisher = HostClipboardPublisher()

    /// Automatic clipboard passthrough driver, created and torn down by
    /// `refreshClipboardPassthrough()`.
    @ObservationIgnored private var clipboardPassthroughCoordinator: ClipboardPassthroughCoordinator?

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

    var vsockLogService: VsockGuestLogService?

    var vsockControlService: VsockControlService?

    /// Serves files dropped on this VM's display; populated once the guest
    /// agent's drop client connects.
    var vsockDropService: VsockDropService?

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
    ///
    /// Reset on `tearDownSession` and on the next successful Hello.
    var agentExpectedButMissing: Bool = false

    /// `true` once a `Hello` has arrived on this VM session.
    ///
    /// Separates a mid-session agent disappearance from an agent that never
    /// appeared: only the latter is evidence about what is installed in the
    /// guest, so only the latter may rewrite persisted agent state.
    ///
    /// Reset on `tearDownSession`.
    private(set) var hasSeenAgentThisSession = false

    /// `true` when this session cold-booted into macOS Recovery, which never
    /// runs the guest agent — so agent silence is evidence of nothing for the
    /// whole session, not just at the moment of boot.
    ///
    /// Set by `VirtualizationService` at cold boot; reset on `tearDownSession`.
    var bootedIntoRecovery = false

    /// Backing task for the agent-arrival watchdog, re-armed each time the
    /// control channel is lost.
    private var agentPostStartTask: Task<Void, Never>?

    /// Bumped by every arm and every cancel, so a watchdog task that finished
    /// sleeping just before a cancel-and-re-arm can tell it has been disowned.
    ///
    /// A task holds the generation it was armed with; only the current one may
    /// act. Without it, the slot check is an ABA test that a stale task passes
    /// against a *successor's* task — firing `.expectedMissing` before that
    /// successor's grace elapsed, and clearing its slot on the way out.
    private var agentPostStartGeneration: UInt64 = 0

    /// Performs a host-side mutation of this instance's configuration and routes
    /// it through the view model's `updateConfiguration` pipeline (persist +
    /// apply live policy).
    ///
    /// Wired by `VMLibraryViewModel.wirePersistence(for:)`; `nil` for instances
    /// created without a view model.
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
    /// Wired by `VMLibraryViewModel.wirePersistence(for:)`; the library uses it
    /// for work that can only run while no VM holds the resource it touches.
    @ObservationIgnored var onSessionTornDown: (@MainActor () -> Void)?

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

    // MARK: - Serial Console

    var serialInputPipe: Pipe?
    var serialOutputPipe: Pipe?

    private var serialLogWriter: SerialLogWriter?

    /// Host-side AF_UNIX relay exposing the serial port to an external terminal.
    ///
    /// Created once per running session and captured by the output readability
    /// handler; it only binds a socket while started.
    private var serialSocketRelay: SerialSocketRelay?

    private static let logger = Logger(subsystem: "app.kernova", category: "VMInstance")

    nonisolated var id: UUID { instanceID }
    var name: String { configuration.name }

    // MARK: - Network Attachment Recovery

    /// Keeps the live network attachment realizing the configured mode;
    /// created with the `VZVirtualMachine` for network-enabled VMs, activated
    /// once the session reaches `.running`, torn down with the session.
    @ObservationIgnored var networkAttachmentCoordinator: NetworkAttachmentCoordinator?

    /// `true` while a live session's network device is detached and recovery
    /// is waiting for a usable host interface.
    var networkAttachmentPending = false

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
        configuration: VMConfiguration, bundleURL: URL, status: VMStatus = .stopped,
        preferences: AppPreferences = .shared
    ) {
        self.instanceID = configuration.id
        self.configuration = configuration
        self.bundleURL = bundleURL
        self.bundleLayout = VMBundleLayout(bundleURL: bundleURL)
        self.status = status
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
    var liveRemovableMedia: [USBDeviceInfo] = []

    #if DEBUG
    /// Test stand-in for `session != nil`: constructing a real
    /// `VZVirtualMachine` requires the virtualization entitlement, which CI
    /// test hosts lack.
    var hasLiveVirtualMachineOverrideForTesting: Bool?

    /// Test stand-in for the live session's identity, for the same reason.
    var liveSessionIDOverrideForTesting: UUID?
    #endif

    /// The live session's identity — the token every asynchronous hand-off and
    /// delivered event carries, so one raised against a session this instance
    /// has already released is dropped instead of landing on its successor or
    /// on a stopped VM.
    var liveSessionID: UUID? {
        #if DEBUG
        if let liveSessionIDOverrideForTesting { return liveSessionIDOverrideForTesting }
        #endif
        return session?.id
    }

    /// Whether a `VZVirtualMachine` for this VM is live in memory — the single
    /// liveness read every predicate here shares.
    var hasLiveVirtualMachine: Bool {
        #if DEBUG
        if let hasLiveVirtualMachineOverrideForTesting { return hasLiveVirtualMachineOverrideForTesting }
        #endif
        return liveSessionID != nil
    }

    /// Whether a live `VZVirtualMachine` is attached and settled at a state VZ
    /// can act on — the VMs a termination save-suspends, and the ones a device
    /// can be attached to.
    ///
    /// A cold-paused VM is excluded: its state is already on disk, with nothing
    /// live to act on.
    var hasLiveSession: Bool {
        status.canSave && hasLiveVirtualMachine
    }

    var canAttachUSBDevices: Bool {
        hasLiveSession
    }

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
        return status.isTransitioning || hasLiveVirtualMachine
    }

    /// `true` when the VM is paused-to-disk but has no live `VZVirtualMachine` in memory.
    var isColdPaused: Bool {
        status == .paused && !hasLiveVirtualMachine
    }

    /// `true` when the VM is paused with its `VZVirtualMachine` still live in
    /// memory — the resumable counterpart of ``isColdPaused``.
    var isLivePaused: Bool {
        status == .paused && hasLiveVirtualMachine
    }

    /// `true` when this VM should keep the app alive: preparing, in an active
    /// lifecycle state, or live-paused in memory.
    var isKeepingAppAlive: Bool {
        isPreparing || status.isActive || isLivePaused
    }

    var canStop: Bool {
        status.canStop && !isColdPaused
    }

    var canSave: Bool {
        status.canSave && !isColdPaused
    }

    /// `true` when the VM is eligible for forceful termination.
    ///
    /// Cold-paused VMs are excluded — there is nothing in memory to terminate.
    var canForceStop: Bool {
        status.canForceStop && !isColdPaused
    }

    /// `true` when the VM can be deleted — nothing live in memory, no
    /// transitional status, and no import or clone writing into the bundle.
    ///
    /// Cold-paused VMs are included: the saved state is a file inside the
    /// bundle and is removed along with it, so no discard step is needed first.
    ///
    /// Enablement only. A cold resume holds `.paused` with no live VM while it
    /// builds its configuration, so this stays `true` after one starts;
    /// ``VMLibraryViewModel/deleteConfirmed(_:deletingExternalIDs:permanently:)``
    /// revalidates against the lifecycle lock at confirm time.
    var canDelete: Bool {
        !isPreparing && (status.canEditSettings || isColdPaused)
    }

    /// `true` when the VM can be cold-booted into macOS Recovery.
    ///
    /// Stopped macOS guests only — Virtualization.framework has no recovery
    /// start option for Linux/EFI guests.
    var canStartInRecovery: Bool {
        status == .stopped && configuration.guestOS == .macOS
    }

    var canUseExternalDisplay: Bool {
        (status == .running || status == .paused) && hasLiveVirtualMachine
    }

    var isInFullscreen: Bool { displayMode == .fullscreen }

    /// `true` when the display is not hosted inline — pop-out, fullscreen, or
    /// closed-while-headless (`.hidden`), all of which offer "Pop In".
    var isDisplayDetached: Bool { displayMode != .inline }

    var canShowClipboard: Bool {
        configuration.clipboardSharingEnabled && (status == .running || status == .paused)
            && hasLiveVirtualMachine
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
            tearDownSession()
            status = .error
            errorMessage = error.localizedDescription
            Self.logger.error(
                "VM '\(self.name, privacy: .public)' stopped with error: \(error.localizedDescription, privacy: .public)"
            )
        case .networkAttachmentDisconnected(let error):
            networkAttachmentCoordinator?.attachmentWasDisconnected(error: error)
        }
    }

    // MARK: - State Helpers

    /// Tears down the live VM session.
    ///
    /// Does **not** change `status` — callers set the appropriate status after calling this.
    func tearDownSession() {
        networkAttachmentCoordinator?.stop()
        networkAttachmentCoordinator = nil
        networkAttachmentPending = false
        clipboardPassthroughCoordinator?.stop()
        clipboardPassthroughCoordinator = nil
        stopVsockServices()
        stopClipboardService()
        stopSerialReading()
        cancelAgentPostStartWatchdog()
        agentExpectedButMissing = false
        hasSeenAgentThisSession = false
        bootedIntoRecovery = false
        serialInputPipe = nil
        serialOutputPipe = nil
        liveRemovableMedia = []
        // Releasing the session releases the actor, its delegate adapter, and
        // the `VZVirtualMachine`; the boot paths' file-lock retry covers the
        // lagging deallocation of the VM's advisory locks.
        session = nil
        runtimeFileAccess.releaseAll()
        // An open display window resets this itself when it auto-closes;
        // `.hidden` (headless) has no window to do so — reset here so it
        // can't leak into the next session.
        displayMode = .inline
        onSessionTornDown?()
    }

    func resetToStopped() {
        tearDownSession()
        status = .stopped
        // Reset so the next start lands on the display rather than inheriting
        // a stuck settings mode from the previous session.
        detailPaneMode = .display
    }

    /// Creates the VM on its own queue, stores the session, and builds the
    /// network-attachment coordinator for network-enabled configurations.
    @discardableResult
    func attachSession(from vzConfig: VZVirtualMachineConfiguration) async -> VMSession {
        // The configuration was assembled off-main and is handed over whole:
        // nothing touches it after the VM is created from it.
        nonisolated(unsafe) let vzConfig = vzConfig
        let session = await VMSession.make(configuration: vzConfig, events: makeSessionEvents())
        self.session = session
        await setupNetworkAttachmentCoordinator(for: session)
        return session
    }

    /// Builds this session's attachment-recovery coordinator, replacing any
    /// prior one.
    private func setupNetworkAttachmentCoordinator(for session: VMSession) async {
        networkAttachmentCoordinator?.stop()
        networkAttachmentCoordinator = nil
        networkAttachmentPending = false
        guard configuration.networkEnabled, session.hasNetworkDevice else { return }
        let networks = VmnetNetworkService.shared
        let initialPlan = await session.inspectNetworkAttachment { attachment in
            VZNetworkDeviceHandle.plan(of: attachment, in: networks)
        }
        guard self.session === session else { return }
        networkAttachmentCoordinator = NetworkAttachmentCoordinator(
            vmName: name,
            device: VZNetworkDeviceHandle(
                session: session, initialPlan: initialPlan, vmnetNetworks: networks),
            interfaces: HostBridgedInterfaceProvider(),
            linkObserver: HostNetworkLinkObserver(),
            isEligible: { [weak self] in
                guard let self else { return false }
                return self.status == .running || self.status == .paused
            },
            choice: { [weak self] in self?.configuration.networkChoice },
            onPendingChange: { [weak self] pending in
                self?.networkAttachmentPending = pending
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
        guard let outputPipe = serialOutputPipe else { return }

        // Created once per session so the readability handler can capture them
        // as `Sendable` locals — the handler must never touch `self` off-actor.
        let writer = SerialLogWriter(
            logURL: bundleLayout.serialLogURL, rotatedURL: bundleLayout.serialLogRotatedURL,
            label: name)
        serialLogWriter = writer
        let relay = makeSerialRelay()

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
    /// Also stores it on `self`; returns `nil` when the input pipe is missing.
    private func makeSerialRelay() -> SerialSocketRelay? {
        guard let inputPipe = serialInputPipe else { return nil }
        let relay = SerialSocketRelay(
            path: Self.serialSocketPath(for: instanceID),
            guestInputWriteHandle: inputPipe.fileHandleForWriting,
            label: name
        )
        serialSocketRelay = relay
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
        serialOutputPipe?.fileHandleForReading.readabilityHandler = nil
        serialSocketRelay?.stop()
        serialSocketRelay = nil
        serialLogWriter?.close()
        serialLogWriter = nil
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
        let shouldRun =
            configuration.clipboardSharingEnabled && configuration.clipboardPassthroughEnabled
            && hasLiveVirtualMachine
        if shouldRun {
            let coordinator =
                clipboardPassthroughCoordinator
                ?? ClipboardPassthroughCoordinator(
                    instance: self, publisher: hostClipboardPublisher,
                    reporter: clipboardTransfers)
            clipboardPassthroughCoordinator = coordinator
            coordinator.start()
        } else {
            clipboardPassthroughCoordinator?.stop()
            clipboardPassthroughCoordinator = nil
        }
    }

    private func startSpiceClipboardService() {
        guard let inputPipe = clipboardInputPipe,
            let outputPipe = clipboardOutputPipe
        else {
            Self.logger.error("SPICE clipboard pipes not configured for '\(self.name, privacy: .public)'")
            return
        }
        let service = SpiceClipboardService(inputPipe: inputPipe, outputPipe: outputPipe)
        service.start()
        clipboardService = service
        Self.logger.info("SPICE clipboard service started for '\(self.name, privacy: .public)'")
    }

    /// Stops and releases the clipboard service and (for SPICE) closes pipe file handles.
    ///
    /// Safe to call when no service is active.
    func stopClipboardService() {
        clipboardService?.stop()
        clipboardService = nil
        clipboardDataSink.set(nil)
        closeSpiceClipboardPipes()
    }

    private func closeSpiceClipboardPipes() {
        do {
            try clipboardInputPipe?.fileHandleForReading.close()
        } catch {
            Self.logger.warning(
                "Failed to close clipboard input read handle for VM '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
        do {
            try clipboardInputPipe?.fileHandleForWriting.close()
        } catch {
            Self.logger.warning(
                "Failed to close clipboard input write handle for VM '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
        do {
            try clipboardOutputPipe?.fileHandleForReading.close()
        } catch {
            Self.logger.warning(
                "Failed to close clipboard output read handle for VM '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
        do {
            try clipboardOutputPipe?.fileHandleForWriting.close()
        } catch {
            Self.logger.warning(
                "Failed to close clipboard output write handle for VM '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
        clipboardInputPipe = nil
        clipboardOutputPipe = nil
    }

    // MARK: - Vsock Service Lifecycle

    /// Installs vsock listeners on the live session's `VZVirtioSocketDevice`.
    ///
    /// A no-op when no socket device is present. Idempotent: any previously
    /// installed listeners are torn down first. The control listener is always
    /// installed; the log and clipboard listeners are gated on
    /// `agentLogForwardingEnabled` / `clipboardSharingEnabled`.
    func startVsockServices() async {
        stopVsockServices()
        guard let session, session.hasVirtioSocketDevice else { return }

        let sessionID = session.id
        let controlHost = makeControlListenerHost(sessionID: sessionID)

        // Drop is unconditional, like control: there is no drop setting — the
        // display simply refuses the gesture when the guest can't take it.
        let dropHost = makeDropListenerHost(sessionID: sessionID)
        let dropDataHost = makeDropDataListenerHost()
        let logHost =
            configuration.agentLogForwardingEnabled
            ? makeLogListenerHost(sessionID: sessionID) : nil
        let clipHost =
            configuration.clipboardSharingEnabled
            ? makeClipboardListenerHost(sessionID: sessionID) : nil
        let clipDataHost =
            configuration.clipboardSharingEnabled ? makeClipboardDataListenerHost() : nil

        let hosts = [controlHost, dropHost, dropDataHost, logHost, clipHost, clipDataHost]
            .compactMap { $0 }
        await session.attach(hosts)
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
        clipboardPassthroughCoordinator?.republishIfCeilingRaised()
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
    /// instance's policy, agent-info, guest-suspension and channel-loss hooks.
    ///
    /// Every hook reads through `self` lazily, so all four track live
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
            onChannelLost: { [weak self] in
                // The agent went away mid-session. Re-arm the same grace clock
                // the post-start path uses, so a channel that never comes back
                // escalates to `.expectedMissing` instead of spinning at
                // `.connecting` for the rest of the session.
                self?.startAgentPostStartWatchdog()
            },
            admissionGate: vsockAdmissionGate
        )
    }

    /// Builds the control-channel listener for the session identified by
    /// `sessionID`; each accepted channel replaces any prior control service.
    func makeControlListenerHost(sessionID: UUID) -> VsockListenerHost {
        VsockListenerHost(port: KernovaVsockPort.control) { [weak self] channel in
            guard let self, self.liveSessionID == sessionID else {
                channel.close()
                return
            }
            // Replace any prior service from a previous reconnect.
            self.vsockControlService?.stop()
            let service = self.makeControlService(for: channel)
            self.vsockControlService = service
            service.start()
            // Any accepted channel that never completes its Hello is on a
            // clock. Replacing a live service settles the old one as
            // owner-requested, so `onChannelLost` does not fire and nothing
            // else would arm here — and an agent that connects but cannot
            // handshake (a half-finished update) is exactly when the reinstall
            // affordance is wanted. Idempotent; the Hello cancels it.
            self.startAgentPostStartWatchdog()
        }
    }

    /// Builds the log-channel listener for the session identified by
    /// `sessionID`; each accepted channel replaces any prior log service.
    func makeLogListenerHost(sessionID: UUID) -> VsockListenerHost {
        VsockListenerHost(
            port: KernovaVsockPort.log,
            shouldAdmit: { [gate = vsockAdmissionGate] in gate.admission(for: .none) }
        ) { [weak self] channel in
            // The accept ran on the VM's queue and this hand-off is a
            // main-actor hop behind it, so the setting is re-read rather than
            // captured: a toggle-off landing in between has already stopped the
            // service and unbound the port, and this connection must not put
            // them back.
            guard let self, self.liveSessionID == sessionID,
                self.configuration.agentLogForwardingEnabled
            else {
                channel.close()
                return
            }
            self.vsockLogService?.stop()
            let service = VsockGuestLogService(channel: channel, label: self.name)
            self.vsockLogService = service
            service.start()
        }
    }

    /// Builds the drop-channel listener for the session identified by
    /// `sessionID`; each accepted channel replaces any prior drop service.
    func makeDropListenerHost(sessionID: UUID) -> VsockListenerHost {
        VsockListenerHost(
            port: KernovaVsockPort.drop,
            shouldAdmit: { [gate = vsockAdmissionGate] in gate.admission(for: .dropFiles) }
        ) { [weak self] channel in
            guard let self, self.liveSessionID == sessionID else {
                channel.close()
                return
            }
            self.vsockDropService?.stop()
            let service = VsockDropService(
                channel: channel, label: self.name, reporter: self.clipboardTransfers)
            self.vsockDropService = service
            self.dropDataSink.set(service)
            service.start()
        }
    }

    /// Builds the drop data listener, which hands each accepted connection to
    /// the live drop service as one item's transfer.
    private func makeDropDataListenerHost() -> VsockListenerHost {
        VsockListenerHost(
            port: KernovaVsockPort.dropData,
            shouldAdmit: { [gate = vsockAdmissionGate] in gate.admission(for: .dropFiles) },
            onAcceptFd: { [sink = dropDataSink] fd in sink.accept(fd: fd) })
    }

    /// Builds the clipboard data listener, which hands each accepted connection
    /// to the live clipboard service as one transfer.
    private func makeClipboardDataListenerHost() -> VsockListenerHost {
        VsockListenerHost(
            port: KernovaVsockPort.clipboardData,
            shouldAdmit: { [gate = vsockAdmissionGate] in
                gate.admission(for: .clipboardStreaming)
            },
            onAcceptFd: { [sink = clipboardDataSink] fd in sink.accept(fd: fd) })
    }

    /// Builds the clipboard-channel listener for the session identified by
    /// `sessionID`; each accepted channel replaces any prior clipboard service.
    func makeClipboardListenerHost(sessionID: UUID) -> VsockListenerHost {
        VsockListenerHost(
            port: KernovaVsockPort.clipboard,
            shouldAdmit: { [gate = vsockAdmissionGate] in
                gate.admission(for: .clipboardStreaming)
            }
        ) { [weak self] channel in
            // Re-read on the hop, as the log listener does: a toggle-off
            // between the accept and this hand-off must not reinstate the
            // service and data sink it just cleared.
            guard let self, self.liveSessionID == sessionID,
                self.configuration.clipboardSharingEnabled
            else {
                channel.close()
                return
            }
            self.clipboardService?.stop()
            // Read through `self` at each budget check, so a Settings change
            // lands on the live session without restarting the service.
            let service = VsockClipboardService(
                channel: channel, label: self.name, reporter: self.clipboardTransfers,
                maxPasteBytes: { [weak self] in
                    self?.effectiveClipboardMaxPasteBytes ?? ClipboardPasteLimit.defaultBytes
                })
            let publisher = self.hostClipboardPublisher
            service.hostPasteboardHoldsOurWrite = { publisher.pasteboardHoldsLastWrite }
            service.retractStaleHostWrite = { [weak self] in
                // With passthrough on, the newer offer's automatic re-publish is
                // what supersedes the stale write; retracting too would only
                // flash an empty pasteboard and a Copy-to-Mac hint for a button
                // passthrough hides.
                guard let self, self.clipboardPassthroughCoordinator == nil else { return false }
                return publisher.retractPromisedWrite()
            }
            self.clipboardService = service
            self.clipboardDataSink.set(service)
            service.start()
        }
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
        guard configuration.guestOS == .macOS else { return }
        guard !bootedIntoRecovery else { return }
        guard status == .running else { return }
        guard configuration.lastSeenAgentVersion != nil else { return }
        guard vsockControlService?.agentVersion == nil else { return }
        guard setupState == nil else { return }
        guard agentPostStartTask == nil else { return }

        agentPostStartGeneration &+= 1
        let generation = agentPostStartGeneration
        Self.logger.debug(
            "Agent arrival watchdog armed for '\(self.name, privacy: .public)' (grace=\(grace, privacy: .public))"
        )
        agentPostStartTask = Task { [weak self] in
            do {
                try await Task.sleep(for: grace)
            } catch {
                return
            }
            guard let self else { return }
            guard self.agentPostStartGeneration == generation else { return }
            if self.vsockControlService?.agentVersion == nil {
                Self.logger.notice(
                    "Guest agent expected (last seen \(self.configuration.lastSeenAgentVersion ?? "?", privacy: .public)) but never reconnected for '\(self.name, privacy: .public)' — surfacing reinstall affordance"
                )
                self.agentExpectedButMissing = true
                // An agent that never showed up at all outranks the nudge the
                // user silenced — reset the dismissal so a future `.waiting`
                // surfaces normally. The reported guest OS version goes with
                // it: nothing vouched for it this session, and "Unknown" beats
                // a stale value. Both stay untouched when the agent did say
                // Hello earlier in this session: it demonstrably exists, and
                // reversing a preference nothing restores needs better evidence
                // than one dropped channel.
                if !self.hasSeenAgentThisSession,
                    self.configuration.agentInstallNudgeDismissed
                        || self.configuration.lastSeenGuestOSVersion != nil
                {
                    self.performConfigurationMutation {
                        $0.agentInstallNudgeDismissed = false
                        $0.lastSeenGuestOSVersion = nil
                    }
                }
            }
            self.agentPostStartTask = nil
        }
    }

    /// Cancels the agent-arrival watchdog if armed.
    ///
    /// Does not clear `agentExpectedButMissing` — callers do that explicitly.
    func cancelAgentPostStartWatchdog() {
        // Bumping disowns a task whose sleep already elapsed, which a bare
        // `cancel()` cannot reach.
        agentPostStartGeneration &+= 1
        agentPostStartTask?.cancel()
        agentPostStartTask = nil
    }

    #if DEBUG
    /// The in-flight post-start watchdog task, or `nil` when none is armed.
    ///
    /// Test-only seam: tests await its completion rather than polling
    /// `agentExpectedButMissing`.
    var agentPostStartTaskForTesting: Task<Void, Never>? { agentPostStartTask }
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
        agentExpectedButMissing = false
        hasSeenAgentThisSession = true
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

    /// Stops every vsock service and unbinds the listeners that fed them.
    ///
    /// The unbind is ordered fire-and-forget on the session's queue, which is
    /// what keeps this synchronous: the session retains each host until its
    /// port is gone, so there is nothing to await to keep a bound port's
    /// delegate alive.
    ///
    /// Only the vsock clipboard service is stopped here — the SPICE service is
    /// owned by `stopClipboardService()`.
    func stopVsockServices() {
        session?.detachRemainingListeners()

        vsockControlService?.stop()
        vsockControlService = nil
        // The stopped service cleared the gate; this also covers a service torn
        // down before it ever published.
        vsockAdmissionGate.clear()

        vsockLogService?.stop()
        vsockLogService = nil

        vsockDropService?.stop()
        vsockDropService = nil
        dropDataSink.set(nil)

        if clipboardService is VsockClipboardService {
            clipboardService?.stop()
            clipboardService = nil
        }
        clipboardDataSink.set(nil)
    }

    /// The vsock live-policy application in flight, chained so a second toggle
    /// arriving before the first finishes runs after it rather than
    /// interleaving with it.
    @ObservationIgnored private var livePolicyApplication: Task<Void, Never>?

    /// Reacts to a configuration change while the VM is running by installing
    /// or tearing down vsock listeners and pushing a fresh `PolicyUpdate` to
    /// the guest agent.
    ///
    /// Only `agentLogForwardingEnabled` and `clipboardSharingEnabled` are
    /// honored at runtime, and the clipboard branch is skipped for Linux guests:
    /// the SPICE port must be declared at config-build time, so sharing is
    /// restart-only there.
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

        guard let session, session.hasVirtioSocketDevice else { return }

        let logChanged =
            oldConfig.agentLogForwardingEnabled != newConfig.agentLogForwardingEnabled
        let clipboardChanged =
            oldConfig.clipboardSharingEnabled != newConfig.clipboardSharingEnabled
        guard logChanged || clipboardChanged else { return }

        let logEnabled = newConfig.agentLogForwardingEnabled
        let clipboardEnabled = newConfig.clipboardSharingEnabled
        let clipboardApplies = clipboardChanged && newConfig.guestOS == .macOS
        let snapshot = agentPolicySnapshot(for: newConfig)

        let sessionID = session.id

        livePolicyApplication = Task { [previous = livePolicyApplication] in
            await previous?.value
            guard self.session === session else { return }

            // A listener the guest is about to be told about goes up first: the
            // policy frame wakes the guest's parked reconnect loop at once
            // (`VsockGuestClient.resume()`), and a redial that beats the
            // listener is refused and costs the guest a full retry interval.
            if logChanged && logEnabled {
                await self.applyLiveLogPolicy(enabled: true, on: session, sessionID: sessionID)
            }
            // Re-checked between the two installs: the hop above hands main
            // back, so a teardown landing there has already queued its unbind,
            // and a second install would bind ports behind it that nothing
            // takes down.
            guard self.session === session else { return }
            if clipboardApplies && clipboardEnabled {
                await self.applyLiveClipboardPolicy(enabled: true, on: session, sessionID: sessionID)
            }

            guard self.session === session else { return }
            // The control service is nil in the window between accepting a
            // connection and the guest's Hello — the next Hello-driven send
            // catches that up.
            self.vsockControlService?.sendPolicyUpdate(snapshot)

            // A listener being withdrawn comes down after, so the frame pauses
            // the guest's loop first: tearing it down while the guest still
            // thinks the feature is on makes the guest see EOF and pound the
            // host with reconnects until the policy arrives.
            if logChanged && !logEnabled {
                await self.applyLiveLogPolicy(enabled: false, on: session, sessionID: sessionID)
            }
            if clipboardApplies && !clipboardEnabled {
                await self.applyLiveClipboardPolicy(enabled: false, on: session, sessionID: sessionID)
            }

            Self.logger.notice(
                "Applied live policy for '\(self.name, privacy: .public)' (logForwarding=\(newConfig.agentLogForwardingEnabled, privacy: .public), clipboard=\(newConfig.clipboardSharingEnabled, privacy: .public))"
            )
        }
    }

    /// Starts or stops the host-side serial relay live.
    ///
    /// Flips the socket on the session's existing relay object — the output
    /// readability handler already holds a reference to it.
    private func applyLiveSerialRelayPolicy(enabled: Bool) {
        if enabled {
            serialSocketRelay?.start()
        } else {
            serialSocketRelay?.stop()
        }
        Self.logger.notice(
            "Serial relay \(enabled ? "enabled" : "disabled", privacy: .public) live for '\(self.name, privacy: .public)'"
        )
    }

    /// Installs or withdraws the guest log listener on a running VM.
    func applyLiveLogPolicy(
        enabled: Bool, on installer: any VsockListenerInstalling, sessionID: UUID
    ) async {
        if enabled {
            // Idempotent reinstall: `attach` rebinds the port before releasing
            // the host it displaces, so no accept can land on a dead delegate.
            await installer.attach([makeLogListenerHost(sessionID: sessionID)])
        } else {
            vsockLogService?.stop()
            vsockLogService = nil
            await installer.detach(ports: [KernovaVsockPort.log])
        }
    }

    /// Installs or withdraws the clipboard channel and its per-transfer data
    /// port together.
    ///
    /// Both ports move in one hop: a data port outliving the channel port that
    /// admits transfers onto it would accept a transfer no service can serve.
    func applyLiveClipboardPolicy(
        enabled: Bool, on installer: any VsockListenerInstalling, sessionID: UUID
    ) async {
        if enabled {
            await installer.attach([
                makeClipboardListenerHost(sessionID: sessionID),
                makeClipboardDataListenerHost(),
            ])
        } else {
            // The caller gates this branch on macOS guests, so any
            // `clipboardService` here is a `VsockClipboardService`.
            clipboardService?.stop()
            clipboardService = nil
            clipboardDataSink.set(nil)
            await installer.detach(
                ports: [KernovaVsockPort.clipboard, KernovaVsockPort.clipboardData])
        }
    }
}
