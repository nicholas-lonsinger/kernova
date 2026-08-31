import Foundation
import os

/// Everything scoped to the lifetime of one `VZVirtualMachine`, so a session's
/// state is created and released as a unit rather than as loose fields a
/// teardown has to remember one by one.
///
/// ``VMInstance`` holds exactly one optional of this type: opening it begins a
/// session, ``tearDown()`` ends it. Objects that outlive a session by intent —
/// the admission gate, the two data sinks, the transfer reporter, the host
/// clipboard publisher — belong to the instance and are handed in here, so a
/// service can publish into them without owning them.
@MainActor
@Observable
final class VMSessionContext {
    private static let logger = Logger(subsystem: "app.kernova", category: "VMSessionContext")

    /// The VM name, for log records.
    @ObservationIgnored private let label: String

    // MARK: - Instance-owned hand-offs

    /// The instance's admission gate; the live control service publishes into
    /// it and ``stopVsockServices()`` clears it.
    @ObservationIgnored private let admissionGate: VsockAdmissionGate

    /// The instance's clipboard data sink, pointed at this session's clipboard
    /// service.
    @ObservationIgnored private let clipboardDataSink: VsockDataConnectionSink

    /// The instance's drop data sink, pointed at this session's drop service.
    @ObservationIgnored private let dropDataSink: VsockDataConnectionSink

    // MARK: - Session

    /// The live VM's isolation domain — the only type that calls into the
    /// `VZVirtualMachine` and its device objects.
    var session: VMSession?

    /// Security-scoped access grants this session holds, opened before the
    /// configuration build and drained in ``tearDown()``.
    @ObservationIgnored let fileAccess = RuntimeFileAccess()

    // MARK: - Serial Console

    var serialInputPipe: Pipe?
    var serialOutputPipe: Pipe?

    @ObservationIgnored var serialLogWriter: SerialLogWriter?

    /// Host-side AF_UNIX relay exposing the serial port to an external terminal.
    ///
    /// Created once per running session and captured by the output readability
    /// handler; it only binds a socket while started.
    @ObservationIgnored var serialSocketRelay: SerialSocketRelay?

    // MARK: - Clipboard Sharing

    /// Bidirectional pipes for the SPICE clipboard console port (Linux guests only).
    var clipboardInputPipe: Pipe?
    var clipboardOutputPipe: Pipe?

    /// Active clipboard service: `SpiceClipboardService` for Linux,
    /// `VsockClipboardService` for macOS.
    ///
    /// Nil on macOS until the guest agent connects.
    var clipboardService: (any ClipboardServicing)?

    /// Automatic clipboard passthrough driver, created and torn down by
    /// `VMInstance.refreshClipboardPassthrough()`.
    @ObservationIgnored var clipboardPassthroughCoordinator: ClipboardPassthroughCoordinator?

    // MARK: - Vsock Channel (macOS guests)

    var vsockLogService: VsockGuestLogService?

    var vsockControlService: VsockControlService?

    /// Serves files dropped on this VM's display; populated once the guest
    /// agent's drop client connects.
    var vsockDropService: VsockDropService?

    /// The vsock live-policy application in flight, chained so a second toggle
    /// arriving before the first finishes runs after it rather than
    /// interleaving with it.
    ///
    /// Per context, so an edit made to one session never queues behind a
    /// previous session's chain — nor lands on a successor's listeners, which
    /// the chain's own per-step context check refuses.
    @ObservationIgnored var livePolicyApplication: Task<Void, Never>?

    // MARK: - Guest Agent

    /// `true` when this session cold-booted into macOS Recovery, which never
    /// runs the guest agent — so agent silence is evidence of nothing for the
    /// whole session, not just at the moment of boot.
    let bootedIntoRecovery: Bool

    /// `true` when this VM has reached `.running`, the host previously saw a
    /// guest agent connect (`configuration.lastSeenAgentVersion != nil`), and a
    /// grace period has elapsed without a `Hello` arriving over the control
    /// channel.
    ///
    /// Cleared by the next successful Hello.
    var agentExpectedButMissing = false

    /// `true` once a `Hello` has arrived on this VM session.
    ///
    /// Separates a mid-session agent disappearance from an agent that never
    /// appeared: only the latter is evidence about what is installed in the
    /// guest, so only the latter may rewrite persisted agent state.
    var hasSeenAgentThisSession = false

    /// Backing task for the agent-arrival watchdog, re-armed each time the
    /// control channel is lost.
    @ObservationIgnored var agentPostStartTask: Task<Void, Never>?

    /// Bumped by every arm and every cancel, so a watchdog task that finished
    /// sleeping just before a cancel-and-re-arm can tell it has been disowned.
    ///
    /// A task holds the generation it was armed with *and* the context it was
    /// armed on; only a task matching both may act. The generation alone is an
    /// ABA test across sessions — each context starts counting at zero — and
    /// identity alone is one within a session, so a stale task would otherwise
    /// fire `.expectedMissing` before its successor's grace elapsed and clear
    /// that successor's slot on the way out.
    @ObservationIgnored var agentPostStartGeneration: UInt64 = 0

    // MARK: - Network Attachment Recovery

    /// Keeps the live network attachment realizing the configured mode;
    /// created with the `VZVirtualMachine` for network-enabled VMs, activated
    /// once the session reaches `.running`, torn down with the session.
    @ObservationIgnored var networkAttachmentCoordinator: NetworkAttachmentCoordinator?

    /// `true` while a live session's network device is detached and recovery
    /// is waiting for a usable host interface.
    var networkAttachmentPending = false

    // MARK: - Runtime Removable Media

    /// USB mass storage devices currently attached on the XHCI controller.
    ///
    /// One entry per item in `configuration.removableMedia` while the VM is
    /// running.
    var liveRemovableMedia: [USBDeviceInfo] = []

    // MARK: - Initializer

    init(
        label: String,
        bootedIntoRecovery: Bool,
        admissionGate: VsockAdmissionGate,
        clipboardDataSink: VsockDataConnectionSink,
        dropDataSink: VsockDataConnectionSink
    ) {
        self.label = label
        self.bootedIntoRecovery = bootedIntoRecovery
        self.admissionGate = admissionGate
        self.clipboardDataSink = clipboardDataSink
        self.dropDataSink = dropDataSink
    }

    // MARK: - Teardown

    /// Releases everything this session holds, in the one order that is
    /// load-bearing: listeners come off the session's device before the session
    /// itself goes, and the session is released before the security scopes its
    /// file descriptors were opened under.
    func tearDown() {
        networkAttachmentCoordinator?.stop()
        networkAttachmentCoordinator = nil
        networkAttachmentPending = false
        clipboardPassthroughCoordinator?.stop()
        clipboardPassthroughCoordinator = nil
        // Dropping the handle is the whole release: `VMInstance.applyLivePolicy`
        // re-checks that this context is still the live one before each of its
        // steps, so a chain in flight settles into a no-op on its own — a
        // `cancel()` would reach none of those steps, none of which suspend on
        // anything cancellable.
        livePolicyApplication = nil
        stopVsockServices()
        stopClipboardService()
        stopSerialReading()
        cancelAgentPostStartWatchdog()
        agentExpectedButMissing = false
        hasSeenAgentThisSession = false
        serialInputPipe = nil
        serialOutputPipe = nil
        liveRemovableMedia = []
        // Releasing the session releases the actor, its delegate adapter, and
        // the `VZVirtualMachine`; the boot paths' file-lock retry covers the
        // lagging deallocation of the VM's advisory locks.
        session = nil
        fileAccess.releaseAll()
    }

    // MARK: - Serial Console I/O

    func stopSerialReading() {
        serialOutputPipe?.fileHandleForReading.readabilityHandler = nil
        serialSocketRelay?.stop()
        serialSocketRelay = nil
        serialLogWriter?.close()
        serialLogWriter = nil
    }

    // MARK: - Clipboard Service Lifecycle

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
                "Failed to close clipboard input read handle for VM '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
        do {
            try clipboardInputPipe?.fileHandleForWriting.close()
        } catch {
            Self.logger.warning(
                "Failed to close clipboard input write handle for VM '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
        do {
            try clipboardOutputPipe?.fileHandleForReading.close()
        } catch {
            Self.logger.warning(
                "Failed to close clipboard output read handle for VM '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
        do {
            try clipboardOutputPipe?.fileHandleForWriting.close()
        } catch {
            Self.logger.warning(
                "Failed to close clipboard output write handle for VM '\(self.label, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
        }
        clipboardInputPipe = nil
        clipboardOutputPipe = nil
    }

    // MARK: - Vsock Service Lifecycle

    /// Stops every vsock service and unbinds the listeners that fed them.
    ///
    /// The unbind is ordered fire-and-forget on the session's queue, which is
    /// what keeps this synchronous: the session retains each host until its
    /// port is gone, so there is nothing to await to keep a bound port's
    /// delegate alive.
    ///
    /// Only the vsock clipboard service is stopped here — the SPICE service is
    /// owned by ``stopClipboardService()``.
    func stopVsockServices() {
        session?.detachRemainingListeners()

        vsockControlService?.stop()
        vsockControlService = nil
        // The stopped service cleared the gate; this also covers a service torn
        // down before it ever published.
        admissionGate.clear()

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

    // MARK: - Agent Post-Start Watchdog

    /// Cancels the agent-arrival watchdog if armed.
    ///
    /// Does not clear ``agentExpectedButMissing`` — callers do that explicitly.
    func cancelAgentPostStartWatchdog() {
        // Bumping disowns a task whose sleep already elapsed, which a bare
        // `cancel()` cannot reach.
        agentPostStartGeneration &+= 1
        agentPostStartTask?.cancel()
        agentPostStartTask = nil
    }
}
