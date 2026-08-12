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
    var virtualMachine: VZVirtualMachine?
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

    // MARK: - Vsock Channel (macOS guests)

    /// Listener for incoming guest log connections; populated for macOS guests
    /// while the VM has a live `VZVirtualMachine`.
    var vsockLogListenerHost: VsockListenerHost?

    var vsockLogService: VsockGuestLogService?

    /// Listener for incoming guest clipboard connections; populated for macOS
    /// guests with clipboard sharing enabled while the VM has a live
    /// `VZVirtualMachine`.
    var vsockClipboardListenerHost: VsockListenerHost?

    /// Listener for the always-on guest control channel; populated for macOS
    /// guests while the VM has a live `VZVirtualMachine`.
    var vsockControlListenerHost: VsockListenerHost?

    var vsockControlService: VsockControlService?

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

    private var serialLogFileHandle: FileHandle?

    /// Host-side AF_UNIX relay exposing the serial port to an external terminal.
    ///
    /// Created once per running session and captured by the output readability
    /// handler; it only binds a socket while started.
    private var serialSocketRelay: SerialSocketRelay?

    private static let logger = Logger(subsystem: "app.kernova", category: "VMInstance")

    nonisolated var id: UUID { instanceID }
    var name: String { configuration.name }

    // MARK: - Delegate

    private var delegateAdapter: VMDelegateAdapter?

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
    /// Test stand-in for `virtualMachine != nil`: constructing a real
    /// `VZVirtualMachine` requires the virtualization entitlement, which CI
    /// test hosts lack.
    var hasLiveVirtualMachineOverrideForTesting: Bool?
    #endif

    /// Whether a `VZVirtualMachine` for this VM is live in memory — the single
    /// liveness read every predicate here shares.
    var hasLiveVirtualMachine: Bool {
        #if DEBUG
        if let hasLiveVirtualMachineOverrideForTesting { return hasLiveVirtualMachineOverrideForTesting }
        #endif
        return virtualMachine != nil
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
        (status == .running || status == .paused) && virtualMachine != nil
    }

    var isInFullscreen: Bool { displayMode == .fullscreen }

    /// `true` when the display is not hosted inline — pop-out, fullscreen, or
    /// closed-while-headless (`.hidden`), all of which offer "Pop In".
    var isDisplayDetached: Bool { displayMode != .inline }

    var canShowClipboard: Bool {
        configuration.clipboardSharingEnabled && (status == .running || status == .paused) && virtualMachine != nil
    }

    // MARK: - Delegate Setup

    func setupDelegate() {
        guard let vm = virtualMachine else { return }
        let adapter = VMDelegateAdapter(instance: self)
        vm.delegate = adapter
        self.delegateAdapter = adapter
    }

    // MARK: - State Helpers

    /// Tears down the live VM session.
    ///
    /// Does **not** change `status` — callers set the appropriate status after calling this.
    func tearDownSession() {
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
        virtualMachine = nil
        delegateAdapter = nil
        runtimeFileAccess.releaseAll()
        // An open display window resets this itself when it auto-closes;
        // `.hidden` (headless) has no window to do so — reset here so it
        // can't leak into the next session.
        displayMode = .inline
    }

    func resetToStopped() {
        tearDownSession()
        status = .stopped
        // Reset so the next start lands on the display rather than inheriting
        // a stuck settings mode from the previous session.
        detailPaneMode = .display
    }

    @discardableResult
    func attachVirtualMachine(from vzConfig: VZVirtualMachineConfiguration) -> VZVirtualMachine {
        let vm = VZVirtualMachine(configuration: vzConfig)
        virtualMachine = vm
        setupDelegate()
        return vm
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
    /// Output is written to the on-disk `serial.log` and tee'd to the
    /// `SerialSocketRelay` when enabled.
    func startSerialReading() {
        guard let outputPipe = serialOutputPipe else { return }

        let logURL = serialLogURL
        if !FileManager.default.fileExists(atPath: logURL.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: logURL)
            do { _ = try handle.seekToEnd() } catch {
                Self.logger.warning(
                    "Could not seek to end of serial log: \(error.localizedDescription, privacy: .public)")
            }
            serialLogFileHandle = handle
        } catch {
            Self.logger.warning(
                "Could not open serial log for writing: \(error.localizedDescription, privacy: .public)")
        }

        // Created once per session so the readability handler can capture it as
        // a `Sendable` local — the handler must never touch `self` off-actor.
        let relay = makeSerialRelay()

        // Captured for the readability handler, which runs on a background GCD queue.
        let logFileHandle = serialLogFileHandle
        let logger = Self.logger

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // Background-safe: FileHandle is thread-safe for sequential writes.
            do {
                try logFileHandle?.write(contentsOf: data)
            } catch {
                logger.error("Failed to write to serial log: \(error.localizedDescription, privacy: .public)")
            }

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
        do {
            try serialLogFileHandle?.close()
        } catch {
            Self.logger.warning(
                "Failed to close serial log file for VM '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
        serialLogFileHandle = nil
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
            && virtualMachine != nil
        if shouldRun {
            let coordinator =
                clipboardPassthroughCoordinator
                ?? ClipboardPassthroughCoordinator(instance: self, publisher: hostClipboardPublisher)
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

    /// Installs vsock listeners on the live VM's `VZVirtioSocketDevice`.
    ///
    /// A no-op when no socket device is present. Idempotent: any previously
    /// installed listeners are torn down first. The control listener is always
    /// installed; the log and clipboard listeners are gated on
    /// `agentLogForwardingEnabled` / `clipboardSharingEnabled`.
    func startVsockServices() {
        stopVsockServices()
        guard let vm = virtualMachine else { return }
        guard let socketDevice = vm.socketDevices.first(where: { $0 is VZVirtioSocketDevice }) as? VZVirtioSocketDevice
        else {
            return
        }

        let controlHost = VsockListenerHost(port: KernovaVsockPort.control) { [weak self] channel in
            guard let self else {
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
        controlHost.attach(to: socketDevice)
        vsockControlListenerHost = controlHost

        if configuration.agentLogForwardingEnabled {
            let logHost = makeLogListenerHost()
            logHost.attach(to: socketDevice)
            vsockLogListenerHost = logHost
        }

        if configuration.clipboardSharingEnabled {
            let clipHost = makeClipboardListenerHost()
            clipHost.attach(to: socketDevice)
            vsockClipboardListenerHost = clipHost
        }

        Self.logger.info("Vsock services started for '\(self.name, privacy: .public)'")
    }

    // MARK: - Vsock Feature-Channel Admission

    /// Whether a feature vsock channel (log or clipboard) may be admitted right
    /// now: a control channel whose `Hello` handshake completed must exist —
    /// and, for the clipboard port, its `Hello` must have advertised
    /// `clipboard.stream.v1`.
    ///
    /// Evaluated at accept time so it tracks reconnects.
    func featureChannelAdmission(requiringClipboardStreaming: Bool) -> VsockAdmission {
        guard let control = vsockControlService, control.isConnected else {
            return .notReady(reason: "no control channel has completed its handshake")
        }
        guard !requiringClipboardStreaming || control.guestSupportsClipboardStreaming else {
            return .denied(
                reason:
                    "the connected guest agent does not advertise \(KernovaCapability.clipboardStreamV1)"
            )
        }
        return .admit
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
            }
        )
    }

    /// Builds the log-channel listener; each accepted channel replaces any prior
    /// log service.
    private func makeLogListenerHost() -> VsockListenerHost {
        VsockListenerHost(
            port: KernovaVsockPort.log,
            shouldAdmit: { [weak self] in
                self?.featureChannelAdmission(requiringClipboardStreaming: false)
                    ?? .notReady(reason: "the VM instance is gone")
            }
        ) { [weak self] channel in
            guard let self else {
                channel.close()
                return
            }
            self.vsockLogService?.stop()
            let service = VsockGuestLogService(channel: channel, label: self.name)
            self.vsockLogService = service
            service.start()
        }
    }

    /// Builds the clipboard-channel listener; each accepted channel replaces any
    /// prior clipboard service.
    private func makeClipboardListenerHost() -> VsockListenerHost {
        VsockListenerHost(
            port: KernovaVsockPort.clipboard,
            shouldAdmit: { [weak self] in
                self?.featureChannelAdmission(requiringClipboardStreaming: true)
                    ?? .notReady(reason: "the VM instance is gone")
            }
        ) { [weak self] channel in
            guard let self else {
                channel.close()
                return
            }
            self.clipboardService?.stop()
            // Read through `self` at each budget check, so a Settings change
            // lands on the live session without restarting the service.
            let service = VsockClipboardService(
                channel: channel, label: self.name, instanceID: self.instanceID,
                maxPasteBytes: { [weak self] in
                    self?.effectiveClipboardMaxPasteBytes ?? ClipboardPasteLimit.defaultBytes
                },
                peerStreamsDirectories: { [weak self] in
                    self?.vsockControlService?.guestSupportsDirectoryStreaming ?? false
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

    /// Tears down all vsock listeners and any active services running on them.
    ///
    /// Only the vsock clipboard service is stopped here — the SPICE service is
    /// owned by `stopClipboardService()`.
    func stopVsockServices() {
        vsockControlService?.stop()
        vsockControlService = nil
        vsockControlListenerHost = nil

        vsockLogService?.stop()
        vsockLogService = nil
        vsockLogListenerHost = nil

        if clipboardService is VsockClipboardService {
            clipboardService?.stop()
            clipboardService = nil
        }
        vsockClipboardListenerHost = nil
    }

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
        guard let vm = virtualMachine else { return }

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

        guard let socketDevice = vm.socketDevices.first(where: { $0 is VZVirtioSocketDevice }) as? VZVirtioSocketDevice
        else {
            return
        }

        let logChanged =
            oldConfig.agentLogForwardingEnabled != newConfig.agentLogForwardingEnabled
        let clipboardChanged =
            oldConfig.clipboardSharingEnabled != newConfig.clipboardSharingEnabled
        guard logChanged || clipboardChanged else { return }

        let logEnabled = newConfig.agentLogForwardingEnabled
        let clipboardEnabled = newConfig.clipboardSharingEnabled
        let clipboardApplies = clipboardChanged && newConfig.guestOS == .macOS

        // A listener the guest is about to be told about goes up first: the
        // policy frame wakes the guest's parked reconnect loop at once
        // (`VsockGuestClient.resume()`), and a redial that beats the listener is
        // refused and costs the guest a full retry interval.
        if logChanged && logEnabled {
            applyLiveLogPolicy(enabled: true, on: socketDevice)
        }
        if clipboardApplies && clipboardEnabled {
            applyLiveClipboardPolicy(enabled: true, on: socketDevice)
        }

        // The control service is nil in the window between accepting a
        // connection and the guest's Hello — the next Hello-driven send catches
        // that up.
        vsockControlService?.sendPolicyUpdate(agentPolicySnapshot(for: newConfig))

        // A listener being withdrawn comes down after, so the frame pauses the
        // guest's loop first: tearing it down while the guest still thinks the
        // feature is on makes the guest see EOF and pound the host with
        // reconnects until the policy arrives.
        if logChanged && !logEnabled {
            applyLiveLogPolicy(enabled: false, on: socketDevice)
        }
        if clipboardApplies && !clipboardEnabled {
            applyLiveClipboardPolicy(enabled: false, on: socketDevice)
        }

        Self.logger.notice(
            "Applied live policy for '\(self.name, privacy: .public)' (logForwarding=\(newConfig.agentLogForwardingEnabled, privacy: .public), clipboard=\(newConfig.clipboardSharingEnabled, privacy: .public))"
        )
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

    private func applyLiveLogPolicy(enabled: Bool, on socketDevice: VZVirtioSocketDevice) {
        if enabled {
            // Idempotent reinstall: tear down any prior listener so a stale
            // accept callback doesn't race a new one.
            vsockLogListenerHost = nil
            let logHost = makeLogListenerHost()
            logHost.attach(to: socketDevice)
            vsockLogListenerHost = logHost
        } else {
            vsockLogService?.stop()
            vsockLogService = nil
            vsockLogListenerHost = nil
        }
    }

    private func applyLiveClipboardPolicy(enabled: Bool, on socketDevice: VZVirtioSocketDevice) {
        if enabled {
            vsockClipboardListenerHost = nil
            let clipHost = makeClipboardListenerHost()
            clipHost.attach(to: socketDevice)
            vsockClipboardListenerHost = clipHost
        } else {
            // The caller gates this branch on macOS guests, so any
            // `clipboardService` here is a `VsockClipboardService`.
            clipboardService?.stop()
            clipboardService = nil
            vsockClipboardListenerHost = nil
        }
    }
}

// MARK: - VZVirtualMachineDelegate Adapter

/// Bridges `VZVirtualMachineDelegate` callbacks to update the `VMInstance` status.
@MainActor
private final class VMDelegateAdapter: NSObject, VZVirtualMachineDelegate {
    private static let logger = Logger(subsystem: "app.kernova", category: "VMDelegateAdapter")

    weak var instance: VMInstance?

    init(instance: VMInstance) {
        self.instance = instance
    }

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated {
            guard let instance else {
                Self.logger.warning("guestDidStop received but VMInstance has been deallocated")
                return
            }
            instance.resetToStopped()
            Self.logger.notice("Guest stopped for VM '\(instance.name, privacy: .public)'")
        }
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        MainActor.assumeIsolated {
            guard let instance else {
                Self.logger.warning("didStopWithError received but VMInstance has been deallocated")
                return
            }
            instance.tearDownSession()
            instance.status = .error
            instance.errorMessage = error.localizedDescription
            Self.logger.error(
                "VM '\(instance.name, privacy: .public)' stopped with error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
