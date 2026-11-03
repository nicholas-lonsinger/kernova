import AppKit
import Foundation
import KernovaKit
import KernovaLogging
import KernovaSynchronization

/// Guest-side agent for files dragged out of the VM display onto the Mac,
/// talking to the host's `VsockDropService` on `KernovaVsockPort.drop`.
///
/// Independent of clipboard sharing. Files dragged out of the display leave
/// through ``GuestDragOut``, whose offers the endpoint serves when the host
/// pulls them. Files dropped on the display arrive over the agent hub instead
/// (`DropReceiver`).
///
/// Connection state is confined to the main actor.
final class VsockGuestDropAgent: Sendable {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "VsockGuestDropAgent")

    /// What a readout calls the machine at the far end — the guest cannot learn
    /// the host's actual computer name over the handshake.
    private static let dropSourceName = "Mac"

    private let client: VsockGuestClient
    private let reporter: ClipboardTransferReporter
    private let progressRevealDelay: TimeInterval
    private let progressIdleGap: TimeInterval
    private let staging: ClipboardFileStaging
    /// Where a drag out's called-in promises land, beside the endpoint's `staging`.
    private let stagingRoot: ProcessStagingRoot
    private let dragOutSystem: GuestDragOutSystem

    /// Opens one item's data connection to the host; tests hand over a
    /// socketpair in place of a real dial.
    private let dataDialer: @Sendable (UInt32) throws -> Int32

    /// What decides whether the reconnect loop dials and whether drags out are
    /// watched for; all default off with the client paused.
    private let enablement = Locked(Enablement())

    private struct Enablement: Sendable {
        /// What the host's `Hello` advertised: the reconnect loop only dials a
        /// host that has a drop listener, and drags are only offered to one
        /// that takes them.
        var host = HostDropCapabilities.unadvertised

        /// Whether the host's latest `PolicyUpdate` has drag and drop switched
        /// on: the host binds the drop ports only while the setting is on, so
        /// dialling before the first policy arrives buys a refused connect per
        /// retry interval.
        var enabledByPolicy = false

        var shouldDial: Bool { host.supportsDropFiles && enabledByPolicy }

        var dragOut: HostDragOutSupport { shouldDial ? host.dragOut : .none }
    }

    // MARK: - Main-actor state

    @MainActor private var liveChannel: VsockChannel?

    /// The current connection, which serves the drags out.
    @MainActor private var endpoint: ClipboardEndpoint?

    /// The current connection's drags out of the guest.
    @MainActor private var dragOut: GuestDragOut?

    #if DEBUG
    /// Test seam, readable from any thread: reads on the main actor that owns it.
    var liveChannelForTesting: VsockChannel? { MainActorBridge.sync { liveChannel } }
    #endif

    // MARK: - Init

    /// Production init — the real drop port.
    convenience init(stagingRoot: ProcessStagingRoot, reporter: ClipboardTransferReporter) {
        self.init(
            client: VsockGuestClient(port: KernovaVsockPort.drop, label: "drop"),
            reporter: reporter, stagingRoot: stagingRoot)
    }

    /// Designated init; tests inject a socketpair-backed client, a staging root
    /// of their own, a `freeSpaceProvider` to simulate a full disk, and a
    /// drag-out system of fakes in place of the guest's event stream and screen.
    init(
        client: VsockGuestClient,
        reporter: ClipboardTransferReporter,
        progressRevealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay,
        progressIdleGap: TimeInterval = ClipboardTransferOperation.defaultIdleGap,
        stagingRoot: ProcessStagingRoot,
        freeSpaceProvider: ClipboardFileStaging.FreeSpaceProvider? = nil,
        dataDialer: @escaping @Sendable (UInt32) throws -> Int32 = {
            try VsockGuestDataDialer.connect(port: $0)
        },
        dragOutSystem: GuestDragOutSystem = .live
    ) {
        self.client = client
        self.dataDialer = dataDialer
        self.reporter = reporter
        self.progressRevealDelay = progressRevealDelay
        self.progressIdleGap = progressIdleGap
        self.dragOutSystem = dragOutSystem
        self.stagingRoot = stagingRoot
        self.staging = ClipboardFileStaging(
            label: "agent-drop", root: stagingRoot, receivingOn: .drop, as: .guest,
            freeSpaceProvider: freeSpaceProvider)
        // Default-paused: nothing dials until the host's `Hello` says it has a
        // drop listener.
        client.pause()
    }

    // MARK: - Lifecycle

    func start() {
        client.start { [weak self] channel in
            await self?.serve(channel: channel)
        }
        Self.logger.log(.notice, "Vsock drop agent started")
    }

    /// Records the host's drag-and-drop setting and matches the reconnect loop
    /// to it.
    func applyPolicy(enabled: Bool) {
        updateEnablement { $0.enabledByPolicy = enabled }
    }

    /// Records what the host takes over the drop channel and matches the
    /// reconnect loop and the drag watcher to it.
    ///
    /// Called whenever the control agent learns the host's capabilities — its
    /// `Hello`, and the clearing that precedes the next one — so a host with no
    /// drop listener is never redialled every retry interval.
    func applyHostCapabilities(_ capabilities: HostDropCapabilities) {
        updateEnablement { $0.host = capabilities }
    }

    private func updateEnablement(_ change: (inout Enablement) -> Void) {
        let shouldDial = enablement.withLock { enablement in
            change(&enablement)
            return enablement.shouldDial
        }
        if shouldDial {
            client.resume()
        } else {
            client.pause()
        }
        MainActorBridge.async { [weak self] in
            self?.reconcileDragWatching()
        }
    }

    /// Runs the drag watcher exactly while a connection is up and the host
    /// and its policy both allow drags out, offering what the host takes of
    /// them, and reading the enablement as it stands now so hops landing out
    /// of order still settle on the latest.
    @MainActor
    private func reconcileDragWatching() {
        dragOut?.setOffering(enablement.withLock { $0.dragOut })
    }

    func stop() {
        client.stop()
        MainActorBridge.async { [weak self] in
            self?.teardownConnectionState()
        }
        Self.logger.log(.notice, "Vsock drop agent stopped")
    }

    /// Clears per-connection state.
    @MainActor
    private func teardownConnectionState() {
        dragOut?.stop()
        dragOut = nil
        endpoint?.stop()
        endpoint = nil
        liveChannel = nil
    }

    @MainActor
    private func teardownIfCurrent(_ channel: VsockChannel) {
        if liveChannel === channel { teardownConnectionState() }
    }

    // MARK: - Per-connection serve

    private func serve(channel: VsockChannel) async {
        let endpoint = await MainActor.run { () -> ClipboardEndpoint in
            let endpoint = ClipboardEndpoint(
                channel: channel,
                configuration: ClipboardEndpoint.Configuration(
                    role: .guest, kind: .drop, label: "drop", peerName: Self.dropSourceName,
                    // A dragged item is written where it is dropped, never on a
                    // pasteboard, so no OS paste deadline bounds it.
                    maxPasteBytes: { .max },
                    staging: self.staging,
                    progressRevealDelay: self.progressRevealDelay,
                    progressIdleGap: self.progressIdleGap,
                    dataLink: .dials(
                        port: KernovaVsockPort.dropData, connect: self.dataDialer)),
                reporter: self.reporter)
            self.liveChannel = channel
            self.endpoint = endpoint
            self.dragOut = GuestDragOut(
                peer: endpoint, system: self.dragOutSystem, stagingRoot: self.stagingRoot)
            endpoint.delegate = self
            endpoint.start()
            self.reconcileDragWatching()
            Self.logger.log(
                .notice,
                "Vsock drop connected to host (conn=\(endpoint.connectionTag, privacy: .public))")
            return endpoint
        }

        await endpoint.waitUntilEnded()
        await MainActor.run {
            self.teardownIfCurrent(channel)
        }
    }
}

// MARK: - Endpoint delegate

extension VsockGuestDropAgent: ClipboardEndpointDelegate {
    func endpoint(_ endpoint: ClipboardEndpoint, didReceiveDragTake generation: UInt64) {
        dragOut?.take(generation: generation)
    }

    func endpoint(
        _ endpoint: ClipboardEndpoint, didReceiveDragCatcher shown: Bool, generation: UInt64
    ) {
        dragOut?.setCatcherShown(shown, generation: generation)
    }

    func endpoint(_ endpoint: ClipboardEndpoint, didReceiveDragResolve generation: UInt64) {
        dragOut?.resolve(generation: generation)
    }

    func endpoint(_ endpoint: ClipboardEndpoint, didCompleteDrag generation: UInt64) {
        dragOut?.complete(generation: generation)
    }

    func endpointDidEnd(_ endpoint: ClipboardEndpoint) {
        // Nothing: this side's own reconnect loop settles the connection when
        // its `waitUntilEnded()` returns, and dials the next one.
    }
}
