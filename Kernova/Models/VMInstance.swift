import Foundation
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
}

/// Which inline detail pane the user has chosen to view for a running VM.
/// Ignored when the VM is stopped (settings are always shown then).
enum DetailPaneMode: Sendable {
    case display
    case settings
}

/// Runtime wrapper around a VM configuration, its backing virtual machine, and current status.
@MainActor
@Observable
final class VMInstance: Identifiable {

    // MARK: - Properties

    let instanceID: UUID
    var configuration: VMConfiguration
    var status: VMStatus
    var virtualMachine: VZVirtualMachine?
    let bundleURL: URL

    /// Structured installation state tracking download and install phases.
    var installState: MacOSInstallState?

    /// Handle to the in-flight macOS installation task, enabling cooperative cancellation.
    var installTask: Task<Void, Never>?

    // MARK: - Preparing State (Clone/Import)

    /// Describes the kind of long-running preparation operation in progress
    /// and provides all associated user-facing strings (display labels, cancel labels, alert titles).
    enum PreparingOperation: Sendable {
        case cloning
        case importing

        var displayLabel: String {
            switch self {
            case .cloning: "Cloning\u{2026}"
            case .importing: "Importing\u{2026}"
            }
        }

        var cancelLabel: String {
            switch self {
            case .cloning: "Cancel Clone"
            case .importing: "Cancel Import"
            }
        }

        var cancelAlertTitle: String {
            switch self {
            case .cloning: "Cancel Clone?"
            case .importing: "Cancel Import?"
            }
        }
    }

    /// Tracks an in-flight clone or import operation. Non-nil when this instance is a
    /// "phantom row" awaiting a file copy to finish (see `VMLibraryViewModel`).
    struct PreparingState {
        let operation: PreparingOperation
        var task: Task<Void, Never>
    }

    /// Non-nil when this instance is a phantom row awaiting a clone or import to finish.
    var preparingState: PreparingState?

    /// Convenience: `true` when a preparing operation is in progress.
    var isPreparing: Bool { preparingState != nil }

    /// Error message if the VM entered an error state.
    var errorMessage: String?

    /// Where the VM display is currently hosted (inline, pop-out window, or fullscreen).
    var displayMode: VMDisplayMode = .inline

    /// Which inline detail pane is shown for this VM while it has an active display.
    /// When the VM is stopped, the settings pane is always shown regardless of this value.
    var detailPaneMode: DetailPaneMode = .display

    // MARK: - Clipboard Sharing

    /// Bidirectional pipes for the SPICE clipboard console port (Linux guests).
    /// Unused for macOS guests, which sync clipboard over vsock instead.
    var clipboardInputPipe: Pipe?
    var clipboardOutputPipe: Pipe?

    /// Active clipboard service for this VM. The concrete type depends on the
    /// guest OS: `SpiceClipboardService` for Linux, `VsockClipboardService`
    /// for macOS. Held as the existential so consumers don't need to branch.
    /// May be nil on macOS until the guest agent connects.
    var clipboardService: (any ClipboardServicing)?

    // MARK: - Vsock Channel (macOS guests)

    /// Listener for incoming guest log connections; populated for macOS guests
    /// while the VM has a live `VZVirtualMachine`.
    var vsockLogListenerHost: VsockListenerHost?

    /// Service handling an active guest log connection. Populated when a
    /// guest agent has connected and forwarded its first frame; cleared on
    /// disconnect or VM teardown.
    var vsockLogService: VsockGuestLogService?

    /// Listener for incoming guest clipboard connections; populated for macOS
    /// guests with clipboard sharing enabled while the VM has a live
    /// `VZVirtualMachine`.
    var vsockClipboardListenerHost: VsockListenerHost?

    /// Listener for the always-on guest control channel; populated for macOS
    /// guests while the VM has a live `VZVirtualMachine`. Carries the agent
    /// version handshake and a bidirectional heartbeat independent of any
    /// optional feature toggle.
    var vsockControlListenerHost: VsockListenerHost?

    /// Service handling an active guest control connection. Populated when
    /// the guest agent's control channel connects; cleared on disconnect or
    /// VM teardown.
    var vsockControlService: VsockControlService?

    /// `true` when this VM has reached `.running`, the host previously saw a
    /// guest agent connect (`configuration.lastSeenAgentVersion != nil`), and
    /// the post-start grace period has elapsed without a fresh `Hello`
    /// arriving over the control channel. Drives the sidebar's louder
    /// "didn't reconnect" badge — distinct from the gentler `.waiting` state
    /// shown on VMs that have never had an agent. Reset on `tearDownSession`
    /// and on the next successful Hello.
    var agentExpectedButMissing: Bool = false

    /// Backing task for the post-start agent-arrival watchdog. One-shot per
    /// VM session. Set in `startAgentPostStartWatchdog`; cancelled in
    /// `tearDownSession` and on the first Hello of the session.
    private var agentPostStartTask: Task<Void, Never>?

    /// Notified whenever a host-side mutation to `configuration` should be
    /// persisted (e.g. the guest reported a new agent version via Hello).
    /// Wired by `VMLibraryViewModel` to `saveConfiguration(for:)` so the
    /// JSON on disk stays in sync. Direct file writes from inside the
    /// instance would bypass the storage abstraction the rest of the app
    /// uses, so this closure routes the call through it.
    @ObservationIgnored var onConfigurationDidChange: (@MainActor (VMInstance) -> Void)?

    /// The current install/version/liveness state of the guest agent for this
    /// VM. The single read site for the UI; dispatches to whichever transport
    /// owns agent status for this guest OS:
    /// - macOS guests source it from the always-on `VsockControlService`, so
    ///   the value is meaningful regardless of whether clipboard sharing is
    ///   enabled. When the post-start watchdog has flipped
    ///   `agentExpectedButMissing`, this property synthesizes
    ///   `.expectedMissing` from the persisted `lastSeenAgentVersion` —
    ///   `VsockControlService` itself does not (and cannot) produce that
    ///   case because it has no access to persisted host state.
    /// - Linux guests source it from `SpiceClipboardService` — `spice-vdagent`
    ///   is user-installed, so there is no host-side install/update flow to
    ///   drive and the only states reachable are `.waiting` / `.current`.
    /// Returns `.waiting` when no service has been started yet.
    var agentStatus: AgentStatus {
        switch configuration.guestOS {
        case .macOS:
            // The watchdog only fires after .running with a non-nil
            // `lastSeenAgentVersion`, but defend against unexpected ordering
            // by falling back to `.waiting` if the persisted value is missing.
            if agentExpectedButMissing,
               let expected = configuration.lastSeenAgentVersion {
                return .expectedMissing(expected: expected)
            }
            return vsockControlService?.agentStatus ?? .waiting
        case .linux:
            return (clipboardService as? SpiceClipboardService)?.agentStatus ?? .waiting
        }
    }

    // MARK: - Serial Console

    /// Observable text buffer driven by serial port output. Capped at 1 MB in memory;
    /// full history is preserved on disk in `serial.log`.
    var serialOutputText: String = ""

    /// Bidirectional pipes for serial port communication.
    var serialInputPipe: Pipe?
    var serialOutputPipe: Pipe?

    /// File handle for writing serial output to the on-disk log.
    private var serialLogFileHandle: FileHandle?

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMInstance")

    /// Maximum in-memory serial buffer size (1 MB).
    private static let maxSerialBufferSize = 1_000_000

    nonisolated var id: UUID { instanceID }
    var name: String { configuration.name }

    // MARK: - Delegate

    private var delegateAdapter: VMDelegateAdapter?

    // MARK: - Bundle Layout

    let bundleLayout: VMBundleLayout

    /// Cached on-disk usage for the VM's disk image, populated asynchronously
    /// by `refreshDiskUsage()` to avoid blocking the main thread.
    var cachedDiskUsageBytes: UInt64?

    /// Reads the physical disk usage off the main thread and caches the result.
    func refreshDiskUsage() async {
        let layout = bundleLayout
        let usage = await Task.detached { layout.diskUsageBytes }.value
        cachedDiskUsageBytes = usage
        Self.logger.debug("Refreshed disk usage for '\(self.name, privacy: .public)': \(usage.map { "\($0) bytes" } ?? "nil", privacy: .public)")
    }

    // MARK: - Initializer

    init(configuration: VMConfiguration, bundleURL: URL, status: VMStatus = .stopped) {
        self.instanceID = configuration.id
        self.configuration = configuration
        self.bundleURL = bundleURL
        self.bundleLayout = VMBundleLayout(bundleURL: bundleURL)
        self.status = status
    }

    // MARK: - VM Bundle Paths (forwarded from VMBundleLayout)

    var diskImageURL: URL { bundleLayout.diskImageURL }
    var auxiliaryStorageURL: URL { bundleLayout.auxiliaryStorageURL }
    var hardwareModelURL: URL { bundleLayout.hardwareModelURL }
    var machineIdentifierURL: URL { bundleLayout.machineIdentifierURL }
    var saveFileURL: URL { bundleLayout.saveFileURL }
    var hasSaveFile: Bool { bundleLayout.hasSaveFile }
    var serialLogURL: URL { bundleLayout.serialLogURL }
    var diskUsageBytes: UInt64? { bundleLayout.diskUsageBytes }

    // MARK: - Runtime USB Devices

    /// USB mass storage devices currently attached via the XHCI controller.
    /// Populated at runtime only; cleared on VM stop/teardown.
    var attachedUSBDevices: [USBDeviceInfo] = []

    /// `true` when the VM has a live `VZVirtualMachine` in a running or paused state, enabling USB hot-plug via the XHCI controller.
    var canAttachUSBDevices: Bool {
        (status == .running || status == .paused) && virtualMachine != nil
    }

    /// `true` when the VM is paused-to-disk but has no live `VZVirtualMachine` in memory.
    var isColdPaused: Bool {
        status == .paused && virtualMachine == nil
    }

    /// `true` when this VM should keep the app alive: preparing, in an active lifecycle
    /// state, or live-paused in memory (as opposed to cold-paused to disk).
    var isKeepingAppAlive: Bool {
        isPreparing || status.isActive || (status == .paused && virtualMachine != nil)
    }

    /// `true` when the VM is eligible for graceful stop (running or live-paused, not cold-paused).
    var canStop: Bool {
        status.canStop && !isColdPaused
    }

    /// `true` when the VM is eligible to save state (active + live VM, not cold-paused).
    var canSave: Bool {
        status.canSave && !isColdPaused
    }

    /// `true` when the VM is eligible to pop out or enter fullscreen (active status + live VM).
    var canUseExternalDisplay: Bool {
        (status == .running || status == .paused) && virtualMachine != nil
    }

    /// `true` when this VM's display is shown in a dedicated fullscreen window.
    var isInFullscreen: Bool { displayMode == .fullscreen }

    /// `true` when the display is in any separate window (pop-out or fullscreen).
    var isInSeparateWindow: Bool { displayMode != .inline }

    /// `true` when the VM is eligible to show a serial console window (active status + live VM).
    var canShowSerialConsole: Bool {
        (status == .running || status == .paused) && virtualMachine != nil
    }

    /// `true` when the VM has clipboard sharing enabled and is eligible to show the clipboard window.
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

    /// Tears down the live VM session: stops clipboard and serial I/O, releases
    /// pipes, clears attached USB devices, and nils the delegate adapter and
    /// `VZVirtualMachine` reference. Does **not** change `status` — callers set
    /// the appropriate status after calling this.
    func tearDownSession() {
        stopVsockServices()
        stopClipboardService()
        stopSerialReading()
        cancelAgentPostStartWatchdog()
        agentExpectedButMissing = false
        serialInputPipe = nil
        serialOutputPipe = nil
        attachedUSBDevices = []
        virtualMachine = nil
        delegateAdapter = nil
    }

    /// Releases the VZVirtualMachine reference and marks the VM as stopped.
    func resetToStopped() {
        tearDownSession()
        status = .stopped
        // The detail-pane toggle only makes sense while a display is live; reset
        // so the next start lands on the display rather than inheriting a stuck
        // settings-mode from the previous session.
        detailPaneMode = .display
    }

    /// Creates a VZVirtualMachine, assigns it, and wires up the delegate. Returns the VM.
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
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            // File already absent — expected in some flows
        } catch {
            Self.logger.warning("Failed to remove save file for '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Serial Console I/O

    /// Begins reading from the serial output pipe. Output is appended to
    /// `serialOutputText` (for the UI) and written to the on-disk log file.
    func startSerialReading() {
        guard let outputPipe = serialOutputPipe else { return }

        // Clear text buffer for a fresh session
        serialOutputText = ""

        // Open (or create) the log file for appending
        let logURL = serialLogURL
        if !FileManager.default.fileExists(atPath: logURL.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: logURL.path(percentEncoded: false), contents: nil)
        }
        do {
            let handle = try FileHandle(forWritingTo: logURL)
            do { _ = try handle.seekToEnd() } catch {
                Self.logger.warning("Could not seek to end of serial log: \(error.localizedDescription, privacy: .public)")
            }
            serialLogFileHandle = handle
        } catch {
            Self.logger.warning("Could not open serial log for writing: \(error.localizedDescription, privacy: .public)")
        }

        // Capture for the readability handler closure (runs on a background GCD queue)
        let logFileHandle = serialLogFileHandle
        let logger = Self.logger

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            // Write to disk log (background-safe — FileHandle is thread-safe for sequential writes)
            do {
                try logFileHandle?.write(contentsOf: data)
            } catch {
                logger.error("Failed to write to serial log: \(error.localizedDescription, privacy: .public)")
            }

            // Update UI buffer on the main actor
            if let text = String(data: data, encoding: .utf8) {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.serialOutputText.append(text)

                    // Cap in-memory buffer at 1 MB
                    if self.serialOutputText.utf8.count > Self.maxSerialBufferSize {
                        let overflow = self.serialOutputText.utf8.count - Self.maxSerialBufferSize
                        let idx = self.serialOutputText.utf8.index(
                            self.serialOutputText.startIndex,
                            offsetBy: overflow
                        )
                        self.serialOutputText = String(self.serialOutputText[idx...])
                    }
                }
            }
        }

        Self.logger.info("Serial reading started for '\(self.name, privacy: .public)'")
    }

    /// Sends a string to the guest via the serial input pipe.
    func sendSerialInput(_ string: String) {
        guard let data = string.data(using: .utf8),
              let inputPipe = serialInputPipe else { return }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            Self.logger.error("Failed to send serial input to VM '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stops reading from the serial output pipe and closes the log file handle.
    func stopSerialReading() {
        serialOutputPipe?.fileHandleForReading.readabilityHandler = nil
        do {
            try serialLogFileHandle?.close()
        } catch {
            Self.logger.warning("Failed to close serial log file for VM '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
        serialLogFileHandle = nil
    }

    // MARK: - Clipboard Service Lifecycle

    /// Starts clipboard sharing if enabled in this VM's configuration. The
    /// transport depends on the guest OS:
    /// - Linux: SPICE agent over the console-port pipes set up at config build.
    /// - macOS: vsock — the actual `VsockClipboardService` is constructed when
    ///   the guest agent connects via the listener installed in
    ///   `startVsockServices()`. Nothing to do here besides log.
    func startClipboardService() {
        guard configuration.clipboardSharingEnabled else { return }
        switch configuration.guestOS {
        case .linux:
            startSpiceClipboardService()
        case .macOS:
            Self.logger.info("Clipboard sharing armed (vsock) for '\(self.name, privacy: .public)' — awaiting guest agent")
        }
    }

    private func startSpiceClipboardService() {
        guard let inputPipe = clipboardInputPipe,
              let outputPipe = clipboardOutputPipe else {
            Self.logger.error("SPICE clipboard pipes not configured for '\(self.name, privacy: .public)'")
            return
        }
        let service = SpiceClipboardService(inputPipe: inputPipe, outputPipe: outputPipe)
        service.start()
        clipboardService = service
        Self.logger.info("SPICE clipboard service started for '\(self.name, privacy: .public)'")
    }

    /// Stops and releases the clipboard service and (for SPICE) closes pipe
    /// file handles. Safe to call when no service is active.
    func stopClipboardService() {
        clipboardService?.stop()
        clipboardService = nil
        closeSpiceClipboardPipes()
    }

    private func closeSpiceClipboardPipes() {
        do {
            try clipboardInputPipe?.fileHandleForReading.close()
        } catch {
            Self.logger.warning("Failed to close clipboard input read handle for VM '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
        do {
            try clipboardInputPipe?.fileHandleForWriting.close()
        } catch {
            Self.logger.warning("Failed to close clipboard input write handle for VM '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
        do {
            try clipboardOutputPipe?.fileHandleForReading.close()
        } catch {
            Self.logger.warning("Failed to close clipboard output read handle for VM '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
        do {
            try clipboardOutputPipe?.fileHandleForWriting.close()
        } catch {
            Self.logger.warning("Failed to close clipboard output write handle for VM '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
        clipboardInputPipe = nil
        clipboardOutputPipe = nil
    }

    // MARK: - Vsock Service Lifecycle

    /// Installs vsock listeners on the live VM's `VZVirtioSocketDevice`. Safe
    /// to call when no socket device is present (Linux guests, or macOS guests
    /// whose configuration omitted it) — the call becomes a no-op.
    /// Idempotent: any previously installed listeners are torn down first.
    ///
    /// The control listener is always installed when a socket device exists —
    /// it carries the policy update + heartbeat. The log and clipboard
    /// listeners are gated on their respective configuration toggles
    /// (`agentLogForwardingEnabled`, `clipboardSharingEnabled`).
    func startVsockServices() {
        stopVsockServices()
        guard let vm = virtualMachine else { return }
        guard let socketDevice = vm.socketDevices.first(where: { $0 is VZVirtioSocketDevice }) as? VZVirtioSocketDevice else {
            return
        }

        let controlHost = VsockListenerHost(port: KernovaVsockPort.control) { [weak self] channel in
            guard let self else {
                channel.close()
                return
            }
            // Replace any prior service from a previous reconnect.
            self.vsockControlService?.stop()
            let service = VsockControlService(
                channel: channel,
                label: self.name,
                policyProvider: { [weak self] in
                    guard let self else {
                        return AgentPolicySnapshot(
                            logForwardingEnabled: false,
                            clipboardSharingEnabled: false
                        )
                    }
                    return AgentPolicySnapshot(
                        logForwardingEnabled: self.configuration.agentLogForwardingEnabled,
                        clipboardSharingEnabled: self.configuration.clipboardSharingEnabled
                    )
                },
                onAgentVersionObserved: { [weak self] reportedVersion in
                    guard let self else { return }
                    // The first Hello of any session — even from a stale or
                    // reconnect cycle — proves the agent is alive, so cancel
                    // the post-start watchdog and clear the expected-missing
                    // flag regardless of whether the persisted version moved.
                    self.cancelAgentPostStartWatchdog()
                    self.agentExpectedButMissing = false
                    // Only persist when the version actually changed. Reconnects
                    // and heartbeats alone don't need a `config.json` rewrite —
                    // and avoiding the no-op write keeps `VMDirectoryWatcher`
                    // from re-firing reconcile on every Hello.
                    guard self.configuration.lastSeenAgentVersion != reportedVersion else {
                        return
                    }
                    self.configuration.lastSeenAgentVersion = reportedVersion
                    self.onConfigurationDidChange?(self)
                }
            )
            self.vsockControlService = service
            service.start()
        }
        controlHost.attach(to: socketDevice)
        vsockControlListenerHost = controlHost

        if configuration.agentLogForwardingEnabled {
            let logHost = VsockListenerHost(port: KernovaVsockPort.log) { [weak self] channel in
                guard let self else {
                    channel.close()
                    return
                }
                self.vsockLogService?.stop()
                let service = VsockGuestLogService(channel: channel, label: self.name)
                self.vsockLogService = service
                service.start()
            }
            logHost.attach(to: socketDevice)
            vsockLogListenerHost = logHost
        }

        if configuration.clipboardSharingEnabled {
            let clipHost = VsockListenerHost(port: KernovaVsockPort.clipboard) { [weak self] channel in
                guard let self else {
                    channel.close()
                    return
                }
                self.clipboardService?.stop()
                let service = VsockClipboardService(channel: channel, label: self.name)
                self.clipboardService = service
                service.start()
            }
            clipHost.attach(to: socketDevice)
            vsockClipboardListenerHost = clipHost
        }

        Self.logger.info("Vsock services started for '\(self.name, privacy: .public)'")
    }

    // MARK: - Agent Post-Start Watchdog

    /// Default grace period before the post-start watchdog fires. Forgiving
    /// enough to cover slow first boots and post-OS-update boots inside the
    /// guest. Tests override this with a millisecond-scale duration.
    static let defaultAgentPostStartGrace: Duration = .seconds(120)

    /// Starts a one-shot timer that flips `agentExpectedButMissing = true` if
    /// the guest agent doesn't say Hello within `grace`. No-op unless every
    /// precondition holds:
    ///
    /// - macOS guest (Linux uses `spice-vdagent`, which the host doesn't track).
    /// - `lastSeenAgentVersion` is non-nil — i.e. we've seen the agent before
    ///   on this VM, so its absence after start is a regression worth surfacing.
    /// - The VM is not currently in macOS install (no agent yet by design).
    /// - No watchdog is already armed (idempotent).
    ///
    /// Cancellation is automatic: any inbound Hello calls
    /// `cancelAgentPostStartWatchdog`; `tearDownSession` does the same on stop.
    func startAgentPostStartWatchdog(grace: Duration = VMInstance.defaultAgentPostStartGrace) {
        guard configuration.guestOS == .macOS else { return }
        guard configuration.lastSeenAgentVersion != nil else { return }
        guard installState == nil else { return }
        guard agentPostStartTask == nil else { return }

        Self.logger.debug(
            "Agent post-start watchdog armed for '\(self.name, privacy: .public)' (grace=\(grace, privacy: .public))"
        )
        agentPostStartTask = Task { [weak self] in
            do {
                try await Task.sleep(for: grace)
            } catch {
                return
            }
            guard let self else { return }
            // If the agent connected at any point during the grace window,
            // `vsockControlService?.agentVersion` is non-nil and the cancel
            // path has already cleared `agentPostStartTask` — this guard is
            // belt-and-braces.
            guard self.agentPostStartTask != nil else { return }
            if self.vsockControlService?.agentVersion == nil {
                Self.logger.notice(
                    "Guest agent expected (last seen \(self.configuration.lastSeenAgentVersion ?? "?", privacy: .public)) but never reconnected for '\(self.name, privacy: .public)' — surfacing reinstall affordance"
                )
                self.agentExpectedButMissing = true
            }
            self.agentPostStartTask = nil
        }
    }

    /// Cancels the post-start watchdog if armed. Used both when an agent
    /// Hello arrives during the grace window and from `tearDownSession`.
    /// Does not clear `agentExpectedButMissing` — callers do that explicitly
    /// where appropriate.
    func cancelAgentPostStartWatchdog() {
        agentPostStartTask?.cancel()
        agentPostStartTask = nil
    }

    /// Tears down all vsock listeners and any active services running on them.
    /// The clipboard service is only stopped here when it's the vsock variant —
    /// the SPICE service is owned by `stopClipboardService()` and would already
    /// be nil at this point under normal teardown order.
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
    /// the guest agent. No-op when the VM isn't running, when no socket
    /// device is attached, or when neither hot-toggleable field changed.
    ///
    /// Only `agentLogForwardingEnabled` and `clipboardSharingEnabled` are
    /// honored at runtime. Clipboard sharing on Linux is restart-only
    /// because the SPICE port must be declared at config-build time —
    /// `applyLivePolicy` skips the clipboard branch entirely for Linux
    /// guests; the UI surfaces a "takes effect on next start" hint instead.
    func applyLivePolicy(oldConfig: VMConfiguration, newConfig: VMConfiguration) {
        guard status == .running || status == .paused else { return }
        guard let vm = virtualMachine else { return }
        guard let socketDevice = vm.socketDevices.first(where: { $0 is VZVirtioSocketDevice }) as? VZVirtioSocketDevice else {
            return
        }

        let logChanged =
            oldConfig.agentLogForwardingEnabled != newConfig.agentLogForwardingEnabled
        let clipboardChanged =
            oldConfig.clipboardSharingEnabled != newConfig.clipboardSharingEnabled
        guard logChanged || clipboardChanged else { return }

        // Push the policy snapshot to the guest BEFORE manipulating host
        // listeners. On a disable transition, this lets the guest pause its
        // reconnect loop first; if we tore down the listener first, the guest
        // would see EOF on its existing channel and pound the host with
        // reconnects (up to one per `retryInterval`) until the policy frame
        // arrives. On enable, the guest's `resume()` waits up to
        // `retryInterval` before its next connect, so the host has time to
        // install the listener after the policy send returns. The control
        // service may be nil during the brief window between accepting the
        // listener connection and receiving the guest's Hello — `?` keeps
        // that state safe; the next Hello-driven send will catch it up.
        vsockControlService?.sendPolicyUpdate(
            AgentPolicySnapshot(
                logForwardingEnabled: newConfig.agentLogForwardingEnabled,
                clipboardSharingEnabled: newConfig.clipboardSharingEnabled
            )
        )

        if logChanged {
            applyLiveLogPolicy(enabled: newConfig.agentLogForwardingEnabled, on: socketDevice)
        }

        let isMacOSGuest = newConfig.guestOS == .macOS
        if clipboardChanged && isMacOSGuest {
            applyLiveClipboardPolicy(
                enabled: newConfig.clipboardSharingEnabled,
                on: socketDevice
            )
        }

        Self.logger.notice(
            "Applied live policy for '\(self.name, privacy: .public)' (logForwarding=\(newConfig.agentLogForwardingEnabled, privacy: .public), clipboard=\(newConfig.clipboardSharingEnabled, privacy: .public))"
        )
    }

    private func applyLiveLogPolicy(enabled: Bool, on socketDevice: VZVirtioSocketDevice) {
        if enabled {
            // Idempotent reinstall: tear down any prior listener so a stale
            // accept callback doesn't race a new one.
            vsockLogListenerHost = nil
            let logHost = VsockListenerHost(port: KernovaVsockPort.log) { [weak self] channel in
                guard let self else {
                    channel.close()
                    return
                }
                self.vsockLogService?.stop()
                let service = VsockGuestLogService(channel: channel, label: self.name)
                self.vsockLogService = service
                service.start()
            }
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
            let clipHost = VsockListenerHost(port: KernovaVsockPort.clipboard) { [weak self] channel in
                guard let self else {
                    channel.close()
                    return
                }
                self.clipboardService?.stop()
                let service = VsockClipboardService(channel: channel, label: self.name)
                self.clipboardService = service
                service.start()
            }
            clipHost.attach(to: socketDevice)
            vsockClipboardListenerHost = clipHost
        } else {
            // Caller (`applyLivePolicy`) gates this branch on `isMacOSGuest`,
            // so any `clipboardService` here is a `VsockClipboardService` —
            // SPICE-backed services live exclusively on Linux guests.
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
    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMDelegateAdapter")

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
            Self.logger.error("VM '\(instance.name, privacy: .public)' stopped with error: \(error.localizedDescription, privacy: .public)")
        }
    }
}
