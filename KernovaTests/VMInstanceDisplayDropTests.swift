import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The three-state gate on dragging files onto a VM display: a VM that has never
/// run the agent is not a drag destination at all, one whose agent is away takes
/// part and refuses, and a reachable one accepts.
@Suite("VMInstance display drop availability", .admissionGated)
@MainActor
struct VMInstanceDisplayDropTests {
    /// A VM instance plus the socket pairs its control and drop services run on.
    private final class Harness {
        let instance: VMInstance
        private var channels: [VsockChannel] = []

        @MainActor
        init(
            guestOS: VMGuestOS = .macOS, lastSeenAgentVersion: String? = "1.0.0",
            clipboardSharingEnabled: Bool = true
        ) {
            var config = VMConfiguration(
                name: "Drop VM", guestOS: guestOS,
                bootMode: guestOS == .macOS ? .macOS : .efi)
            config.lastSeenAgentVersion = lastSeenAgentVersion
            config.clipboardSharingEnabled = clipboardSharingEnabled
            let bundleURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(config.id.uuidString, isDirectory: true)
            instance = VMInstance(configuration: config, bundleURL: bundleURL)
        }

        /// Installs a started control service and hands back the guest end, so a
        /// test can drive the `Hello` that carries the capability.
        @MainActor
        func attachControl() throws -> VsockChannel {
            let (guest, host) = try makePair()
            let control = VsockControlService(channel: host, label: "drop-test")
            instance.vsockControlService = control
            control.start()
            return guest
        }

        /// Installs a started drop service.
        @MainActor
        func attachDrop() throws {
            let (_, host) = try makePair()
            let service = VsockDropService(
                channel: host, label: "Drop VM", reporter: instance.clipboardTransfers)
            instance.vsockDropService = service
            service.start()
        }

        @MainActor
        private func makePair() throws -> (guest: VsockChannel, host: VsockChannel) {
            let (guestFd, hostFd) = try makeRawSocketPair()
            let guest = VsockChannel(fileDescriptor: guestFd)
            let host = VsockChannel(fileDescriptor: hostFd)
            guest.start()
            host.start()
            channels.append(contentsOf: [guest, host])
            return (guest, host)
        }

        @MainActor
        func tearDown() {
            instance.vsockDropService?.stop()
            instance.vsockControlService?.stop()
            for channel in channels { channel.close() }
        }
    }

    private func makeHello(capabilities: [String]) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = capabilities
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.agentVersion = "1.0.0"
            }
        }
        return frame
    }

    @Test("a VM that has never seen an agent is not a drag destination")
    func neverConnectedIsNotADestination() {
        let harness = Harness(lastSeenAgentVersion: nil)
        defer { harness.tearDown() }

        #expect(harness.instance.displayDropAvailability == .none)
    }

    @Test("a Linux guest is never a drag destination — the agent is macOS-only")
    func linuxIsNotADestination() {
        // A Linux guest never records an agent version, so this is belt and
        // braces; the guest-OS check is what makes it explicit.
        let harness = Harness(guestOS: .linux, lastSeenAgentVersion: "1.0.0")
        defer { harness.tearDown() }

        #expect(harness.instance.displayDropAvailability == .none)
    }

    @Test("a VM whose agent has connected before, but isn't now, refuses the drag")
    func previouslyConnectedRefuses() {
        let harness = Harness()
        defer { harness.tearDown() }

        // Registered as a destination (not `.none`), so the drag participates and
        // springs back rather than passing through to whatever is behind.
        #expect(harness.instance.displayDropAvailability == .disconnected)
    }

    @Test("a live drop channel without the capability still refuses")
    func requiresTheCapability() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let guest = try harness.attachControl()
        try harness.attachDrop()

        try guest.send(
            makeHello(capabilities: [
                KernovaCapability.controlV1, KernovaCapability.clipboardTransferV3,
            ]))
        try await waitForChange { harness.instance.vsockControlService?.isConnected == true }

        #expect(harness.instance.displayDropAvailability == .disconnected)
    }

    @Test("a live drop channel from a capable agent accepts the drag")
    func liveAndCapableAccepts() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let guest = try harness.attachControl()
        try harness.attachDrop()

        try guest.send(makeHello(capabilities: KernovaCapability.controlChannelDefaults))
        try await waitForChange { harness.instance.displayDropAvailability == .available }
    }

    @Test("a stopped drop service downgrades an available VM back to a refusal")
    func stoppingTheServiceRefusesAgain() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let guest = try harness.attachControl()
        try harness.attachDrop()
        try guest.send(makeHello(capabilities: KernovaCapability.controlChannelDefaults))
        try await waitForChange { harness.instance.displayDropAvailability == .available }

        harness.instance.vsockDropService?.stop()

        #expect(harness.instance.displayDropAvailability == .disconnected)
        // And a drop attempted in that state is refused rather than swallowed.
        #expect(!harness.instance.sendDroppedFilesToGuest([URL(fileURLWithPath: "/tmp/a.txt")]))
    }

    // MARK: - Reporting a drop the clipboard toggle has no say over

    @Test("a drop reports itself on a VM whose Clipboard Sharing is switched off")
    func dropReportsWithClipboardSharingOff() throws {
        let harness = Harness(clipboardSharingEnabled: false)
        defer { harness.tearDown() }
        let instance = harness.instance
        // The toggle closes the Clipboard window and disables the toolbar item
        // that carries the ring, which is why the menu-bar status item — driven
        // by this report alone — is where the drop has to show.
        #expect(!instance.canShowClipboard)

        let operation = ClipboardTransferOperation(
            gesture: .drop, direction: .outbound, peerName: instance.name, revealDelay: 0,
            now: { 0 }, schedule: { _, _ in }, onCancelRequested: {},
            reporter: instance.clipboardTransfers)
        let readout = ClipboardProgressSnapshot(
            direction: .outbound, peerName: instance.name, currentItemName: "a.txt",
            filesCompleted: 0, fileCount: 1, bytesTransferred: 10, totalBytes: 100,
            bytesPerSecond: 10, secondsRemaining: 9, gesture: .drop, elapsedSeconds: 5,
            isCancellable: true, operationID: operation.id)
        instance.clipboardTransfers.publish(from: operation, .running(readout, since: Date()))

        guard case .running(let shown, _) = instance.clipboardTransferReport else {
            Issue.record("the drop left the status item's readout empty")
            return
        }
        #expect(shown.gesture == .drop)
        #expect(shown.isCancellable)
        // And that readout opens the dropdown on its own, so the drop is seen
        // without the user going looking for it.
        var opener = ClipboardProgressMenuAutoOpener()
        #expect(opener.readoutChanged(shown, menuIsOpen: false, canOpen: true) == .open)
        // The Cancel it carries reaches the drop through the same report.
        #expect(instance.clipboardTransfers.cancel(shown.operationID))
        withExtendedLifetime(operation) {}
    }
}
