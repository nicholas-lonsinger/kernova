import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Unit tests for how the host's drag-out channel settles when its channel ends.
@Suite("VsockDropService", .caseScoped)
@MainActor
struct VsockDropServiceTests {
    // MARK: - Harness

    /// A socketpair, the service under test on one end, and the guest's end of
    /// its channel on the other.
    @MainActor
    private final class Harness {
        let service: VsockDropService
        let guest: VsockChannel
        let host: VsockChannel
        private let reports = ClipboardTransferReports()
        private let stagingRoot = TestStagingRoot()

        init() throws {
            let (hostFd, guestFd) = try makeRawSocketPair()
            host = VsockChannel(fileDescriptor: hostFd)
            guest = VsockChannel(fileDescriptor: guestFd)
            host.start()
            guest.start()
            service = VsockDropService(
                channel: host, label: "Drop VM", reporter: reports.reporter,
                stagingRoot: stagingRoot.root, stagingKey: "drop-vm", progressIdleGap: 0)
            service.start()
        }

        func tearDown() {
            service.stop()
            guest.close()
        }
    }

    @Test("the channel ending settles the service, so the display stops taking drags over")
    func channelEndSettlesTheService() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        // The guest's drop client closes this channel on every control
        // reconnect. Nothing calls `stop()` for that, so the service has to
        // settle itself.
        harness.guest.close()

        try await waitForChange { !harness.service.isConnected }
    }

    @Test("a control-plane payload on the drop channel closes it and settles the service")
    func wrongPortPayloadSettlesTheService() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }

        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello()
        try harness.guest.send(frame)

        // The endpoint closes the channel itself, so nothing else will tell the
        // service — and a service left connected keeps offering the display a
        // drag it can no longer take.
        try await waitForChange { !harness.service.isConnected }
    }
}
