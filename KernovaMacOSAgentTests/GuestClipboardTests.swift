import AppKit
import Foundation
import KernovaAgentCore
import KernovaClipboardItems
import KernovaKit
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Testing

/// The guest's clipboard over the session peer's CLIPBOARD items: when its copies are offered to the host, and
/// what becomes of the host's offers — over a fake pasteboard and a link recording what it is asked to send.
@Suite("GuestClipboard", .caseScoped)
@MainActor
struct GuestClipboardTests {
    private let staging = TestStagingRoot()

    /// The calls a connection is asked to make, each completed at once: offers open, and each item read is
    /// `items`' entry.
    private final class RecordingLink: ClipboardItemLink {
        private struct Calls {
            var offers: [ItemOffer] = []
            var withdrawals: [Data] = []
            var releases: [Data] = []
            var ceilings: [UInt64] = []
        }

        private let calls = Locked(Calls())
        private let items: [OfferedItem]
        let changed = AsyncGate()

        init(items: [OfferedItem] = []) {
            self.items = items
        }

        var offers: [ItemOffer] { calls.withLock(\.offers) }
        var withdrawals: [Data] { calls.withLock(\.withdrawals) }
        var releases: [Data] { calls.withLock(\.releases) }
        /// The `byte_ceiling` of each pull ordered, in order.
        var ceilings: [UInt64] { calls.withLock(\.ceilings) }

        func offerItems(_ offer: ItemOffer, _ completion: @escaping @Sendable (WireError?) -> Void) {
            calls.withLock { $0.offers.append(offer) }
            changed.notify()
            completion(nil)
        }

        func withdrawOffer(_ token: Data) {
            calls.withLock { $0.withdrawals.append(token) }
            changed.notify()
        }

        func releaseOffer(_ token: Data) {
            calls.withLock { $0.releases.append(token) }
            changed.notify()
        }

        func readItem(_ token: Data, item: UInt32, _ completion: @escaping @Sendable (OfferedItem?) -> Void) {
            completion(items.indices.contains(Int(item)) ? items[Int(item)] : nil)
        }

        func pullItem(
            _ order: ItemPullOrder, _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void
        ) {
            completion(.failure(WireError(.cancelled)))
        }

        func cancelPull(_ id: ItemPullID) {}

        func order(
            token: Data, item: UInt32, representation: UInt32, byteCeiling: UInt64, landing: ItemLanding
        ) throws(WireError) -> ItemPullOrder {
            calls.withLock { $0.ceilings.append(byteCeiling) }
            throw WireError(.writeFailed)
        }
    }

    private struct Rig {
        let pasteboard: FakePasteboard
        let clipboard: GuestClipboard
    }

    private func rig() -> Rig {
        let pasteboard = FakePasteboard()
        return Rig(
            pasteboard: pasteboard,
            clipboard: GuestClipboard(pasteboard: pasteboard, stagingRoot: staging.root))
    }

    /// The types each of `link`'s offers carries, in order.
    private func offeredUTIs(_ link: RecordingLink) -> [[String?]] {
        link.offers.map { $0.items.flatMap { $0.representations.map(\.type.appleUTI) } }
    }

    // MARK: - Gating

    @Test("A copy is offered only once the session is on the console and its connection can use CLIPBOARD")
    func offeredOnlyOnConsoleAndUsable() async throws {
        let rig = rig()
        let link = RecordingLink()
        #expect(rig.pasteboard.setString("first", forType: .string))

        rig.clipboard.setLink(link)
        rig.clipboard.checkPasteboard()
        #expect(!rig.clipboard.isOffering)

        rig.clipboard.setOnConsole(true)
        try await link.changed.wait { link.offers.count == 1 }
        #expect(offeredUTIs(link) == [[ClipboardContent.utf8TextUTI]])
    }

    @Test("Usability returning re-offers the clipboard as it stands")
    func usabilityReturningReoffers() async throws {
        let rig = rig()
        let link = RecordingLink()
        rig.clipboard.setOnConsole(true)
        #expect(rig.pasteboard.setString("first", forType: .string))
        rig.clipboard.setLink(link)
        try await link.changed.wait { link.offers.count == 1 }

        rig.clipboard.setLink(nil)
        #expect(!rig.clipboard.isOffering)
        rig.clipboard.setLink(link)

        try await link.changed.wait { link.offers.count == 2 }
        #expect(link.offers[0].token != link.offers[1].token)
        #expect(link.offers[0].items == link.offers[1].items)
    }

    @Test("Off the console a copy is not offered; the console returning offers the copy that stands")
    func offConsoleCopyWaitsForTheConsole() async throws {
        let rig = rig()
        let link = RecordingLink()
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)
        #expect(rig.pasteboard.setString("on", forType: .string))
        rig.clipboard.checkPasteboard()
        try await link.changed.wait { link.offers.count == 1 }

        rig.clipboard.setOnConsole(false)
        #expect(rig.pasteboard.setItem([(.string, Data("off".utf8)), (.html, Data("<b>off</b>".utf8))]))
        rig.clipboard.checkPasteboard()
        #expect(link.offers.count == 1)

        rig.clipboard.setOnConsole(true)
        try await link.changed.wait { link.offers.count == 2 }
        #expect(offeredUTIs(link).last == [ClipboardContent.utf8TextUTI, NSPasteboard.PasteboardType.html.rawValue])
    }

    // MARK: - The host's offers

    @Test("The host's offer is published promised, and released once a copy in the guest replaces it")
    func hostOfferPublishedThenReleased() async throws {
        let rig = rig()
        var text = OfferedItem()
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: ClipboardContent.utf8TextUTI)
        representation.storage = .inline
        text.representations = [representation]
        let link = RecordingLink(items: [text])
        rig.clipboard.setLink(link)
        let token = Data(repeating: 9, count: 16)

        rig.clipboard.exchange.handle(
            .offerReceived(ItemSetHeaderValue(feature: .clipboard, token: token, concealed: false, count: 1)),
            on: link)
        try await rig.pasteboard.changed.wait { !rig.pasteboard.promisedTypes.isEmpty }
        #expect(rig.pasteboard.promisedTypes == [NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)])
        // The poll does not read the agent's own promise as a copy.
        rig.clipboard.checkPasteboard()
        #expect(link.releases.isEmpty)

        #expect(rig.pasteboard.setString("copied in the guest", forType: .string))
        rig.clipboard.checkPasteboard()
        try await link.changed.wait { link.releases == [token] }
        #expect(link.offers.isEmpty)
    }

    @Test("The host's policy sets each pull's byte ceiling, and a policy arriving later changes it")
    func policySetsThePullCeiling() async throws {
        let rig = rig()
        var text = OfferedItem()
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: ClipboardContent.utf8TextUTI)
        representation.storage = .inline
        text.representations = [representation]
        let link = RecordingLink(items: [text])
        rig.clipboard.setLink(link)
        func policy(_ bytes: Int) -> PolicySnapshot {
            PolicySnapshot([ClipboardPolicyValue(maxPasteBytes: UInt64(bytes)).policy(enabled: true)])
        }
        let first = ClipboardPasteLimit.choices[0]
        rig.clipboard.apply(policy(first))
        rig.clipboard.exchange.handle(
            .offerReceived(
                ItemSetHeaderValue(
                    feature: .clipboard, token: Data(repeating: 9, count: 16), concealed: false, count: 1)),
            on: link)
        try await rig.pasteboard.changed.wait { !rig.pasteboard.promisedTypes.isEmpty }
        let pasteboard = rig.pasteboard
        let type = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)

        // A paste holds its thread until the pull ends, so it fires off the main actor.
        _ = await Task.detached { pasteboard.invokeProvider(forType: type) }.value
        #expect(link.ceilings == [UInt64(first)])

        let raised = 16 * 1024 * 1024 * 1024
        rig.clipboard.apply(policy(raised))
        _ = await Task.detached { pasteboard.invokeProvider(forType: type) }.value
        #expect(link.ceilings == [UInt64(first), UInt64(raised)])
        #expect(rig.clipboard.exchange.pasteCeilingBytes == raised)
    }

    // MARK: - One current clipboard

    private static let hostToken = Data(repeating: 9, count: 16)

    private static func textItem() -> OfferedItem {
        var item = OfferedItem()
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: ClipboardContent.utf8TextUTI)
        representation.storage = .inline
        item.representations = [representation]
        return item
    }

    /// Has the host offer one text item on `link` and waits for the guest pasteboard to promise it.
    private func receiveHostOffer(_ rig: Rig, _ link: RecordingLink, token: Data = hostToken) async throws {
        rig.clipboard.exchange.handle(
            .offerReceived(ItemSetHeaderValue(feature: .clipboard, token: token, concealed: false, count: 1)),
            on: link)
        try await rig.pasteboard.changed.wait { rig.clipboard.exchange.remote?.token == token }
    }

    @Test("A guest offer names the last host offer the guest received on its connection")
    func offerNamesTheLastHostOffer() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)
        try await receiveHostOffer(rig, link)

        #expect(rig.pasteboard.setString("copied in the guest", forType: .string))
        rig.clipboard.checkPasteboard()
        try await link.changed.wait { link.offers.count == 1 }
        #expect(link.offers[0].after == Self.hostToken)

        // A new connection has received nothing yet.
        rig.clipboard.setLink(nil)
        rig.clipboard.setLink(link)
        try await link.changed.wait { link.offers.count == 2 }
        #expect(link.offers[1].after.isEmpty)
    }

    @Test("Publishing the host's offer withdraws the guest's own: one current clipboard")
    func publishingWithdrawsTheGuestsOffer() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        rig.clipboard.setOnConsole(true)
        #expect(rig.pasteboard.setString("copied in the guest", forType: .string))
        rig.clipboard.setLink(link)
        try await link.changed.wait { link.offers.count == 1 }

        try await receiveHostOffer(rig, link)
        try await link.changed.wait { link.withdrawals == [link.offers[0].token] }
        #expect(rig.clipboard.exchange.localSource == nil)
    }

    @Test(
        "A host offer the host ends is retracted, with or without a successor; one its connection drops keeps serving",
        arguments: [
            (StreamClosure.resetByPeer(WireError(.cancelled)), true),
            (StreamClosure.resetByPeer(WireError(.itemOfferReplaced)), true),
            (StreamClosure.connectionLost, false),
        ])
    func hostEndRetracts(closure: StreamClosure, retracted: Bool) async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        rig.clipboard.setLink(link)
        try await receiveHostOffer(rig, link)
        #expect(!rig.pasteboard.promisedTypes.isEmpty)

        rig.clipboard.exchange.handle(.offerEnded(.clipboard, .remote, token: Self.hostToken, closure), on: link)
        #expect(rig.pasteboard.promisedTypes.isEmpty == retracted)
        // The retraction's clear is the agent's own write: the poll reads no copy from it.
        rig.clipboard.setOnConsole(true)
        rig.clipboard.checkPasteboard()
        await drainMainQueue()
        #expect(link.offers.isEmpty)
    }

    @Test("A copy that offers nothing withdraws the guest's offer")
    func emptyCopyWithdraws() async throws {
        let rig = rig()
        let link = RecordingLink()
        rig.clipboard.setOnConsole(true)
        #expect(rig.pasteboard.setString("copied in the guest", forType: .string))
        rig.clipboard.setLink(link)
        try await link.changed.wait { link.offers.count == 1 }

        // A password manager clears the clipboard.
        _ = rig.pasteboard.clearContents()
        rig.clipboard.checkPasteboard()
        try await link.changed.wait { link.withdrawals == [link.offers[0].token] }
        #expect(link.offers.count == 1)
    }

    @Test("The connection returning re-offers a copy of the guest's own, never the host's write it holds")
    func returnReoffersOnlyLocalCopies() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)
        try await receiveHostOffer(rig, link)

        rig.clipboard.setLink(nil)
        rig.clipboard.setLink(link)
        rig.clipboard.setOnConsole(false)
        rig.clipboard.setOnConsole(true)
        await drainMainQueue()
        #expect(link.offers.isEmpty)
    }
}
