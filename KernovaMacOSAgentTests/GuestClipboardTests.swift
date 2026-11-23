import AppKit
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaClipboardItems
import KernovaFileTree
import KernovaItemTransfer
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaKit

/// The guest's clipboard over the session peer's CLIPBOARD items: when its copies are offered to the host, what
/// becomes of the host's offers, and what the menu shows of each — over a fake pasteboard only the test polls and a
/// link recording what it is asked to send.
@Suite("GuestClipboard", .caseScoped)
@MainActor
struct GuestClipboardTests {
    private let staging = TestStagingRoot()
    private let scratch = TestScratchDirectory(prefix: "guest-clipboard")

    private struct Rig {
        let pasteboard: FakePasteboard
        let clipboard: GuestClipboard
        /// Notified at each notice the clipboard raises.
        let noticed: AsyncGate
        private let raised: Locked<Int>

        init(pasteboard: FakePasteboard, clipboard: (@escaping @Sendable () -> Void) -> GuestClipboard) {
            let noticed = AsyncGate()
            let raised = Locked(0)
            self.pasteboard = pasteboard
            self.noticed = noticed
            self.raised = raised
            self.clipboard = clipboard {
                raised.withLock { $0 += 1 }
                noticed.notify()
            }
        }

        /// How many notices the clipboard raised.
        var notices: Int { raised.withLock { $0 } }
    }

    private func rig() -> Rig {
        let pasteboard = FakePasteboard(pollsOnlyWhenTold: true)
        let root = staging.root
        return Rig(pasteboard: pasteboard) {
            GuestClipboard(pasteboard: pasteboard, stagingRoot: root, onNotice: $0)
        }
    }

    /// The host's policy, passthrough `on` or off, its paste ceiling `maxPasteBytes` (0: the default).
    private static func policy(passthrough on: Bool, maxPasteBytes: Int = 0) -> PolicySnapshot {
        PolicySnapshot([
            ClipboardPolicyValue(maxPasteBytes: UInt64(maxPasteBytes), passthrough: on).policy(enabled: true)
        ])
    }

    /// Opens the gate on `link`: on the console, passthrough on, the connection usable.
    private func openGate(_ rig: Rig, _ link: RecordingLink) {
        rig.clipboard.setOnConsole(true)
        rig.clipboard.apply(Self.policy(passthrough: true))
        rig.clipboard.setLink(link)
    }

    /// A tick of the pasteboard's watch.
    private func poll(_ rig: Rig) {
        ClipboardPasteboardWatch.pollForTesting(rig.pasteboard)
    }

    /// Copies `text` in the guest and polls the pasteboard.
    private func copy(_ text: String, _ rig: Rig) {
        #expect(rig.pasteboard.setString(text, forType: .string))
        poll(rig)
    }

    private static func token(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }
    private static let hostToken = token(9)

    private static func textItem() -> OfferedItem {
        var item = OfferedItem()
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: NSPasteboard.PasteboardType.string.rawValue)
        representation.storage = .inline
        item.representations = [representation]
        return item
    }

    /// Has the host offer one item on `link` as `token` and waits for the guest pasteboard to be written.
    private func receiveHostOffer(_ rig: Rig, _ link: RecordingLink, token: Data = hostToken) async throws {
        let before = rig.pasteboard.changeCount
        rig.clipboard.end.handle(
            .offerReceived(ItemSetHeaderValue(feature: .clipboard, token: token, concealed: false, count: 1)),
            on: link)
        try await rig.pasteboard.changed.wait { rig.pasteboard.changeCount != before }
    }

    private func guestFile() throws -> URL {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let file = scratch.url.appendingPathComponent("a.bin")
        try Data("the guest's file".utf8).write(to: file)
        return file
    }

    // MARK: - Gating

    @Test("The status reads disabled until a connection carries the clipboard, enabled while one does, disabled after")
    func statusFollowsTheConnection() {
        let rig = rig()
        #expect(rig.clipboard.activity == .disabled)
        rig.clipboard.setLink(RecordingLink())
        #expect(rig.clipboard.activity == .enabled)
        rig.clipboard.setLink(nil)
        #expect(rig.clipboard.activity == .disabled)
    }

    // MARK: - What a read of the guest's clipboard shows

    @Test(
        "A copy offered whole shows as shared; one that lost a file says how many items, and one of only lost files says nothing crossed"
    )
    func copyOutcomesAreShown() async throws {
        let rig = rig()
        let link = RecordingLink()
        openGate(rig, link)
        copy("copied in the guest", rig)
        try await link.changed.wait { link.offers.count == 1 }
        #expect(rig.clipboard.activity == .offeredToHost)
        #expect(rig.notices == 0)

        let readable = try guestFile()
        let missing = scratch.url.appendingPathComponent("missing.bin")
        #expect(rig.pasteboard.setFiles([readable, missing]))
        poll(rig)
        try await rig.noticed.wait { rig.notices == 1 }
        #expect(rig.clipboard.activity == .copyPartlyCarried(skipped: 1))
        #expect(link.offers.count == 2)

        #expect(rig.pasteboard.setFiles([missing]))
        poll(rig)
        try await rig.noticed.wait { rig.notices == 2 }
        #expect(rig.clipboard.activity == .copyCarriedNothing)
        #expect(link.offers.count == 2)
    }

    // MARK: - The host's offers

    @Test("The host's policy sets each pull's byte ceiling, and a policy arriving later changes it for later offers")
    func policySetsThePullCeiling() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        rig.clipboard.setLink(link)
        let first = ClipboardPasteLimit.choices[0]
        rig.clipboard.apply(Self.policy(passthrough: false, maxPasteBytes: first))
        try await receiveHostOffer(rig, link)
        let pasteboard = rig.pasteboard
        let type = NSPasteboard.PasteboardType.string

        // A paste holds its thread until the pull ends, so it fires off the main actor.
        _ = try await offCooperativePool { pasteboard.invokeProvider(forType: type) }
        #expect(link.ceilings == [UInt64(first)])

        // An offer's pulls land against one budget, the ceiling as its first pull read it.
        let raised = 16 * 1024 * 1024 * 1024
        rig.clipboard.apply(Self.policy(passthrough: false, maxPasteBytes: raised))
        try await receiveHostOffer(rig, link, token: Self.token(8))
        _ = try await offCooperativePool { pasteboard.invokeProvider(forType: type) }
        #expect(link.ceilings == [UInt64(first), UInt64(raised)])
    }

    // MARK: - Serving the host's pulls

    /// A promise whose call-in the test hears.
    @MainActor
    private final class HeardPromise: FilePromiseReceiving {
        let promise: FakeFilePromiseReceiver
        let calledIn = AsyncGate()

        init(_ name: String) {
            promise = FakeFilePromiseReceiver(
                files: [(name, .file(Data(name.utf8)))], fileType: "public.png", deferred: true)
        }

        var fileNames: [String] { promise.fileNames }
        var fileTypes: [String] { promise.fileTypes }
        var callIns: Int { promise.callIns }

        func receivePromisedFiles(
            atDestination destination: URL, options: [AnyHashable: Any], operationQueue: OperationQueue,
            reader: @escaping (URL, (any Error)?) -> Void
        ) {
            promise.receivePromisedFiles(
                atDestination: destination, options: options, operationQueue: operationQueue, reader: reader)
            calledIn.notify()
        }
    }

    @Test("A pull waiting on a promise's call-in ends when the pull ends, and when its offer does")
    func callInWaitEndsWithItsPullOrOffer() async throws {
        let rig = rig()
        let link = RecordingLink()
        openGate(rig, link)
        let end = rig.clipboard.end
        func id(_ stream: UInt32) -> ItemPullID {
            ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: stream))
        }
        func pull(_ stream: UInt32, of offer: ItemOffer) -> BlockingCall<Result<ItemContent, WireError>> {
            var request = PullRequest()
            request.token = offer.token
            let id = id(stream)
            return BlockingCall { [request] in end.content(id, request) }
        }
        func failure(_ result: Result<ItemContent, WireError>) -> ErrorCode? {
            if case .failure(let error) = result { error.code } else { nil }
        }
        /// Copies `promise` in the guest and returns its offer.
        func offered(_ promise: HeardPromise) async throws -> ItemOffer {
            let offered = link.offers.count
            rig.pasteboard.setFilePromise(promise)
            poll(rig)
            try await link.changed.wait { link.offers.count == offered + 1 }
            return try #require(link.offers.last)
        }

        // The source never delivers: each pull waits on the call-in until something ends it.
        let first = HeardPromise("a.png")
        let offer = try await offered(first)
        let ended = pull(2, of: offer)
        try await first.calledIn.wait { first.callIns == 1 }
        end.handle(.serveEnded(.clipboard, id(2), .closed(.connectionLost)), on: link)
        #expect(failure(try await ended.returned()) == .cancelled)

        // A pull whose end came before its content was asked for is not served at all.
        end.handle(.serveEnded(.clipboard, id(4), .closed(.connectionLost)), on: link)
        #expect(failure(try await pull(4, of: offer).returned()) == .cancelled)

        let second = HeardPromise("b.png")
        let replacing = try await offered(second)
        let withdrawn = pull(6, of: replacing)
        try await second.calledIn.wait { second.callIns == 1 }
        end.handle(
            .offerEnded(.clipboard, .local, token: replacing.token, .resetLocally(WireError(.cancelled))), on: link)
        #expect(failure(try await withdrawn.returned()) == .itemRepresentationUnavailable)
    }
}
