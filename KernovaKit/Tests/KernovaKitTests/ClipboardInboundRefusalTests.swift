import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

@Suite("ClipboardInboundOffers refusals", .caseScoped)
@MainActor
struct ClipboardInboundRefusalTests {
    /// The refusal hop runs after the fire that raised it has returned, so a
    /// refusal for one offer can land once a newer offer is live. Recording it
    /// must not relabel the newer offer as refused.
    @Test("a refusal recorded for a superseded offer is dropped, not written over the newer one")
    func staleRefusalDoesNotOverwriteANewerOffer() async throws {
        let (near, far) = try makeRawSocketPair()
        let channel = VsockChannel(fileDescriptor: near)
        defer {
            channel.close()
            ClipboardDataConnection.end(fd: far)
        }
        let staging = ClipboardFileStaging(label: "refusals", root: TestStagingRoot().root)
        defer { staging.sweep() }
        let inbound = ClipboardInboundOffers(
            session: ClipboardControlSession(
                channel: channel, role: .host, kind: .clipboard, label: "refusals",
                staging: staging, dataSocketTimeout: testWaitBackstop),
            reporter: ClipboardTransferReporter(dwell: 0, schedule: { _, _ in }),
            staging: staging, peerName: "guest", maxPasteBytes: { ClipboardPasteLimit.defaultBytes })
        let recorded = Box<[ClipboardEndpoint.Activity]>([])
        let changed = AsyncGate()
        inbound.onActivity = { activity in
            recorded.value.append(activity)
            changed.notify()
        }

        inbound.handleOffer(makeTextOfferFrame(generation: 36, text: "old").clipboardOffer)
        inbound.handleOffer(makeTextOfferFrame(generation: 37, text: "new").clipboardOffer)

        // Both hops run in order on the main queue, so the live offer's refusal
        // landing proves the stale one has already been handled.
        inbound.recordRefusal(.pasteTooLarge, generation: 36)
        inbound.recordRefusal(.pasteTimeout, generation: 37)
        try await changed.wait { !recorded.value.isEmpty }

        #expect(recorded.value == [.pasteRefused(.pasteTimeout, limitBytes: nil)])
    }
}
