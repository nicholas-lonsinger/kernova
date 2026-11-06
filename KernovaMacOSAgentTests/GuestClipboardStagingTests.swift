import AppKit
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaClipboardItems
import KernovaFileTree
import KernovaItemTransfer
import KernovaKit
import KernovaLogging
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Testing

/// What the guest pasteboard keeps of the host's clipboard once the file it names in staging goes, and the lines
/// the guest logs as it takes the host's clipboard back.
@Suite("GuestClipboard staging and retraction lines", .caseScoped)
@MainActor
struct GuestClipboardStagingTests {
    private static let hostToken = Data(repeating: 9, count: 16)
    private static let copyToken = Data(repeating: 6, count: 16)
    nonisolated private static let text = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)

    private static func representation(_ uti: String, _ storage: Representation.Storage, name: String = "")
        -> Representation
    {
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: uti)
        representation.storage = storage
        representation.name = Data(name.utf8)
        return representation
    }

    /// One item of text.
    private static let textItem = {
        var item = OfferedItem()
        item.representations = [representation(ClipboardContent.utf8TextUTI, .inline)]
        return item
    }()

    /// One item of a file and its name as text, as Finder copies one.
    private static let fileItem = {
        var item = OfferedItem()
        item.representations = [
            representation(ClipboardContent.utf8TextUTI, .inline), representation("public.data", .file, name: "a.bin"),
        ]
        return item
    }()

    /// Lands pull `index` of `link` with `bytes`, where its order says.
    private func land(_ bytes: Data, pull index: Int, _ clipboard: GuestClipboard, _ link: RecordingLink) throws {
        let (order, id) = link.pulls[index]
        guard case .staged(let directory, .exactly(let name)) = order.landing else {
            return clipboard.exchange.pullEnded(id, .landed(.inline(bytes)))
        }
        try bytes.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(String(decoding: name, as: UTF8.self)))
        clipboard.exchange.pullEnded(id, .landed(.named(name)))
    }

    /// Publishes the host's passthrough offer of a text item and a file item, has a paste in the guest take every
    /// type of both, and ends the connection: what was pasted stays, as data. Returns the staged file the second
    /// item's `public.file-url` names.
    private func keepPastedFile(
        _ clipboard: GuestClipboard, _ pasteboard: FakePasteboard, _ link: RecordingLink
    ) async throws -> URL {
        clipboard.setLink(link)
        clipboard.exchange.handle(
            .offerReceived(
                ItemSetHeaderValue(feature: .clipboard, token: Self.hostToken, concealed: false, count: 2)),
            on: link)
        try await pasteboard.changed.wait { pasteboard.promisedTypesByItem.count == 2 }
        let pastes: [(item: Int, type: NSPasteboard.PasteboardType, bytes: Data)] = [
            (0, Self.text, Data("first".utf8)), (1, Self.text, Data("a.bin".utf8)),
            (1, .fileURL, Data("the host's file".utf8)),
        ]
        for (index, paste) in pastes.enumerated() {
            let (item, type) = (paste.item, paste.type)
            let fired = Task.detached { pasteboard.invokeProvider(forType: type, itemIndex: item) }
            try await link.changed.wait { link.opened.count == index + 1 }
            try land(paste.bytes, pull: index, clipboard, link)
            #expect(await fired.value != nil)
        }
        clipboard.setLink(nil)
        try await pasteboard.changed.wait { pasteboard.promisedTypes.isEmpty }
        let named = try #require(pasteboard.dataByItem.last?[.fileURL])
        let file = try #require(URL(string: String(decoding: named, as: UTF8.self)))
        #expect(try Data(contentsOf: file) == Data("the host's file".utf8))
        #expect(pasteboard.dataByItem.first == [Self.text: Data("first".utf8)])
        return file
    }

    private func pastedLink() -> RecordingLink {
        RecordingLink(items: [Self.textItem, Self.fileItem], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
    }

    /// Has the host send three copies whose one pull fails, each refused unwritten: each takes a staging
    /// generation of its own, the third evicting the oldest. Returns the link they came over.
    @discardableResult
    private func failThreeCopies(_ clipboard: GuestClipboard) async throws -> RecordingLink {
        let link = RecordingLink(items: [Self.textItem], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        clipboard.setLink(link)
        for attempt in 0..<3 {
            let token = Data(repeating: UInt8(0x40 + attempt), count: 16)
            clipboard.exchange.handle(
                .offerReceived(
                    ItemSetHeaderValue(
                        feature: .clipboard, token: token, concealed: false, count: 1, copy: .snapshot)),
                on: link)
            try await link.changed.wait { link.opened.count == attempt + 1 }
            clipboard.exchange.pullEnded(link.pulls[attempt].id, .failed(WireError(.readFailed)))
            try await link.changed.wait { link.refusals.count == attempt + 1 }
        }
        return link
    }

    @Test("A pasted file the guest kept goes whole, its name too, once later copies evict its staging; the rest stays")
    func keptFileGoesWithItsStaging() async throws {
        let staging = TestStagingRoot(retirement: ClipboardStagingRetirement())
        let pasteboard = FakePasteboard()
        let clipboard = GuestClipboard(pasteboard: pasteboard, stagingRoot: staging.root)
        let file = try await keepPastedFile(clipboard, pasteboard, pastedLink())
        clipboard.setOnConsole(true)
        clipboard.apply(
            PolicySnapshot([ClipboardPolicyValue(maxPasteBytes: 0, passthrough: true).policy(enabled: true)]))

        let link = try await failThreeCopies(clipboard)
        try await pasteboard.changed.wait { pasteboard.dataByItem.count == 1 }
        #expect(pasteboard.dataByItem == [[Self.text: Data("first".utf8)]])
        try await staging.removals.wait { !FileManager.default.fileExists(atPath: file.path) }

        // The withdrawal is the agent's own write: the poll offers nothing of it.
        clipboard.checkPasteboard()
        await drainMainQueue()
        #expect(link.offers.isEmpty)
    }

    @Test("A guest pasteboard that moved on is left alone when the staging a kept file named is evicted")
    func movedOnPasteboardOutlivesTheEviction() async throws {
        let staging = TestStagingRoot(retirement: ClipboardStagingRetirement())
        let pasteboard = FakePasteboard()
        let clipboard = GuestClipboard(pasteboard: pasteboard, stagingRoot: staging.root)
        let file = try await keepPastedFile(clipboard, pasteboard, pastedLink())
        #expect(pasteboard.setString("moved on", forType: .string))
        let movedOn = pasteboard.changeCount

        try await failThreeCopies(clipboard)
        try await staging.removals.wait { !FileManager.default.fileExists(atPath: file.path) }
        #expect(pasteboard.changeCount == movedOn)
        #expect(pasteboard.items.first?.data(forType: .string) == Data("moved on".utf8))
    }

    @Test(
        "The agent ending withdraws its kept pasted file whole, its name too, and leaves the file for the next launch")
    func agentEndingWithdrawsTheKeptFile() async throws {
        let staging = TestStagingRoot(retirement: ClipboardStagingRetirement())
        let pasteboard = FakePasteboard()
        let clipboard = GuestClipboard(pasteboard: pasteboard, stagingRoot: staging.root)
        let file = try await keepPastedFile(clipboard, pasteboard, pastedLink())

        staging.root.processEnding()
        #expect(pasteboard.dataByItem == [[Self.text: Data("first".utf8)]])
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    /// Runs an agent over `pasteboard` under a root of its own beside `staging`'s, keeps a pasted file, and lets the
    /// agent go as an exit does, its root's lock with it. Returns the file the pasteboard still names.
    private func exitedAgentKeptAFile(_ staging: TestStagingRoot, _ pasteboard: FakePasteboard) async throws -> URL {
        weak var exited: ProcessStagingRoot?
        var clipboard: GuestClipboard?
        do {
            let root = staging.makeSibling()
            exited = root
            clipboard = GuestClipboard(pasteboard: pasteboard, stagingRoot: root)
        }
        let file = try await keepPastedFile(try #require(clipboard), pasteboard, pastedLink())
        clipboard = nil
        await drainMainQueue()
        #expect(exited == nil, "the exited agent's staging root is still held")
        return file
    }

    @Test("The next launch withdraws, whole, the pasted file an exited agent's pasteboard still names, then removes it")
    func nextLaunchWithdrawsAStaleFile() async throws {
        let staging = TestStagingRoot()
        let pasteboard = FakePasteboard()
        let file = try await exitedAgentKeptAFile(staging, pasteboard)

        let relaunched = staging.makeSibling(
            retirement: ClipboardStagingRetirement(ledger: ClipboardWriteLedger(), pasteboard: { pasteboard }))
        await withCheckedContinuation { done in relaunched.reclaimAbandonedRoots { done.resume() } }
        #expect(pasteboard.dataByItem == [[Self.text: Data("first".utf8)]])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("The next launch leaves a pasteboard that moved on since an agent exited alone, and removes its staging")
    func nextLaunchLeavesAMovedOnPasteboard() async throws {
        let staging = TestStagingRoot()
        let pasteboard = FakePasteboard()
        let file = try await exitedAgentKeptAFile(staging, pasteboard)
        #expect(pasteboard.setString("moved on", forType: .string))
        let movedOn = pasteboard.changeCount

        let relaunched = staging.makeSibling(
            retirement: ClipboardStagingRetirement(ledger: ClipboardWriteLedger(), pasteboard: { pasteboard }))
        await withCheckedContinuation { done in relaunched.reclaimAbandonedRoots { done.resume() } }
        #expect(pasteboard.changeCount == movedOn)
        #expect(pasteboard.items.first?.data(forType: .string) == Data("moved on".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Retraction lines

    /// The notice lines a clipboard logged.
    private final class Lines: Sendable {
        private let lines = Locked<[String]>([])

        var logger: KernovaLogger {
            KernovaLogger(subsystem: "app.kernova.macosagent", category: "GuestClipboard") {
                [lines] level, _, _, segments in
                guard level == .notice else { return }
                lines.withLock { $0.append(segments.map(\.text).joined()) }
            }
        }

        /// The retraction lines, in order.
        var retractions: [String] { lines.withLock { $0 }.filter { $0.hasPrefix("Retracted") } }
    }

    @Test("Passthrough stopping takes back the host's concealed text pasted in the guest, and the guest says so (41e)")
    func passthroughStoppingLogsTheRetraction() async throws {
        let lines = Lines()
        let pasteboard = FakePasteboard()
        let clipboard = GuestClipboard(
            pasteboard: pasteboard, stagingRoot: TestStagingRoot().root, logger: lines.logger)
        let link = RecordingLink(items: [Self.textItem], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        clipboard.setLink(link)
        clipboard.exchange.handle(
            .offerReceived(ItemSetHeaderValue(feature: .clipboard, token: Self.hostToken, concealed: true, count: 1)),
            on: link)
        try await pasteboard.changed.wait { !pasteboard.promisedTypes.isEmpty }
        let fired = Task.detached { pasteboard.invokeProvider(forType: Self.text) }
        try await link.changed.wait { link.opened.count == 1 }
        try land(Data("hunter2-mac".utf8), pull: 0, clipboard, link)
        #expect(await fired.value == Data("hunter2-mac".utf8))
        await drainMainQueue()

        clipboard.exchange.handle(
            .offerEnded(.clipboard, .remote, token: Self.hostToken, .resetByPeer(WireError(.disabledByPolicy))),
            on: link)
        #expect(pasteboard.items.isEmpty)
        #expect(
            lines.retractions == [
                "Retracted the Mac's clipboard from the guest pasteboard: the Mac stopped passthrough"
            ])
    }

    @Test("The connection leaving takes back what no paste had of the host's offer, the rest kept, and says so")
    func linkLeavingLogsThePartRetracted() async throws {
        let lines = Lines()
        let pasteboard = FakePasteboard()
        let clipboard = GuestClipboard(
            pasteboard: pasteboard, stagingRoot: TestStagingRoot().root, logger: lines.logger)
        let link = pastedLink()
        clipboard.setLink(link)
        clipboard.exchange.handle(
            .offerReceived(
                ItemSetHeaderValue(feature: .clipboard, token: Self.hostToken, concealed: false, count: 2)),
            on: link)
        try await pasteboard.changed.wait { pasteboard.promisedTypesByItem.count == 2 }
        let fired = Task.detached { pasteboard.invokeProvider(forType: Self.text, itemIndex: 0) }
        try await link.changed.wait { link.opened.count == 1 }
        try land(Data("first".utf8), pull: 0, clipboard, link)
        #expect(await fired.value != nil)
        await drainMainQueue()

        clipboard.setLink(nil)
        #expect(pasteboard.dataByItem == [[Self.text: Data("first".utf8)]])
        #expect(
            lines.retractions == [
                "Retracted part of the Mac's clipboard from the guest pasteboard, the rest kept: the Mac's connection ended"
            ])
    }

    /// Has the host send a copy of a text item and a file item, landing its text, and waits for its write.
    private func receiveCopy(_ clipboard: GuestClipboard, _ pasteboard: FakePasteboard, _ link: RecordingLink)
        async throws
    {
        clipboard.setLink(link)
        clipboard.exchange.handle(
            .offerReceived(
                ItemSetHeaderValue(
                    feature: .clipboard, token: Self.copyToken, concealed: false, count: 2, copy: .snapshot)),
            on: link)
        try await link.changed.wait { link.opened.count == 2 }
        for (index, (order, _)) in link.pulls.enumerated() {
            try land(Data((order.request.item == 0 ? "first" : "a.bin").utf8), pull: index, clipboard, link)
        }
        try await pasteboard.changed.wait { pasteboard.promisedTypes == [.fileURL] }
    }

    @Test("The host withdrawing its copy takes back the copy's unpasted file item, and the guest says why (39b)")
    func copyWithdrawnLogsTheRetraction() async throws {
        let lines = Lines()
        let pasteboard = FakePasteboard()
        let clipboard = GuestClipboard(
            pasteboard: pasteboard, stagingRoot: TestStagingRoot().root, logger: lines.logger)
        let link = pastedLink()
        try await receiveCopy(clipboard, pasteboard, link)

        clipboard.exchange.handle(
            .offerEnded(.clipboard, .remote, token: Self.copyToken, .resetByPeer(WireError(.cancelled))), on: link)
        #expect(pasteboard.dataByItem == [[Self.text: Data("first".utf8)]])
        #expect(
            lines.retractions == [
                "Retracted the Mac's copied files from the guest pasteboard, the rest of the copy kept: the Mac withdrew the copy"
            ])
    }

    @Test("The connection leaving takes back a host copy's unpasted file item, and the guest says so")
    func copyEndingWithTheLinkLogsTheRetraction() async throws {
        let lines = Lines()
        let pasteboard = FakePasteboard()
        let clipboard = GuestClipboard(
            pasteboard: pasteboard, stagingRoot: TestStagingRoot().root, logger: lines.logger)
        try await receiveCopy(clipboard, pasteboard, pastedLink())

        clipboard.setLink(nil)
        #expect(pasteboard.dataByItem == [[Self.text: Data("first".utf8)]])
        #expect(
            lines.retractions == [
                "Retracted the Mac's copied files from the guest pasteboard, the rest of the copy kept: the Mac's connection ended"
            ])
    }

    @Test("A retraction that takes nothing back logs no line")
    func nothingTakenBackLogsNothing() async throws {
        let lines = Lines()
        let pasteboard = FakePasteboard()
        let clipboard = GuestClipboard(
            pasteboard: pasteboard, stagingRoot: TestStagingRoot().root, logger: lines.logger)
        _ = try await keepPastedFile(clipboard, pasteboard, pastedLink())
        #expect(lines.retractions.isEmpty)
    }
}
