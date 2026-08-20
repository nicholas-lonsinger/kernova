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
        init(guestOS: VMGuestOS = .macOS, lastSeenAgentVersion: String? = "1.0.0") {
            var config = VMConfiguration(
                name: "Drop VM", guestOS: guestOS,
                bootMode: guestOS == .macOS ? .macOS : .efi)
            config.lastSeenAgentVersion = lastSeenAgentVersion
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
}
