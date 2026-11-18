import AppKit
import Foundation
import KernovaAgentCore
import KernovaClipboardItems
import KernovaFileTree
import KernovaItemTransfer
import KernovaLogging
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaKit

/// What the guest pasteboard keeps of the host's clipboard once the file it names in staging goes, and the line
/// the guest logs as it takes the host's clipboard back.
@Suite("GuestClipboard staging and retraction lines", .caseScoped)
@MainActor
struct GuestClipboardStagingTests {
    private static let hostToken = Data(repeating: 9, count: 16)
    nonisolated private static let text = NSPasteboard.PasteboardType.string

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
        item.representations = [representation(NSPasteboard.PasteboardType.string.rawValue, .inline)]
        return item
    }()

    /// One item of a file and its name as text, as Finder copies one.
    private static let fileItem = {
        var item = OfferedItem()
        item.representations = [
            representation(NSPasteboard.PasteboardType.string.rawValue, .inline),
            representation("public.data", .file, name: "a.bin"),
        ]
        return item
    }()

    /// Lands pull `index` of `link` with `bytes`, where its order says.
    private func land(_ bytes: Data, pull index: Int, _ clipboard: GuestClipboard, _ link: RecordingLink) throws {
        let (order, id) = link.pulls[index]
        guard case .staged(let directory, .exactly(let name)) = order.landing else {
            return clipboard.end.pullEnded(id, .landed(.inline(bytes)))
        }
        try bytes.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(String(decoding: name, as: UTF8.self)))
        clipboard.end.pullEnded(id, .landed(.named(name)))
    }

    /// Publishes the host's passthrough offer of a text item and a file item, has a paste in the guest take every
    /// type of both, and ends the connection: what was pasted stays, as data. Returns the staged file the second
    /// item's `public.file-url` names.
    private func keepPastedFile(
        _ clipboard: GuestClipboard, _ pasteboard: FakePasteboard, _ link: RecordingLink
    ) async throws -> URL {
        clipboard.setLink(link)
        clipboard.end.handle(
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
            let fired = BlockingCall { pasteboard.invokeProvider(forType: type, itemIndex: item) }
            try await link.changed.wait { link.opened.count == index + 1 }
            try land(paste.bytes, pull: index, clipboard, link)
            #expect(try await fired.returned() != nil)
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

    @Test(
        "The agent ending withdraws its kept pasted file whole, its name too, and leaves the file for the next launch")
    func agentEndingWithdrawsTheKeptFile() async throws {
        let staging = TestStagingRoot(retirement: ClipboardStagingRetirement())
        let pasteboard = FakePasteboard(pollsOnlyWhenTold: true)
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
        try await drainMainQueue()
        #expect(exited == nil, "the exited agent's staging root is still held")
        return file
    }

    @Test("The next launch withdraws, whole, the pasted file an exited agent's pasteboard still names, then removes it")
    func nextLaunchWithdrawsAStaleFile() async throws {
        let staging = TestStagingRoot()
        let pasteboard = FakePasteboard(pollsOnlyWhenTold: true)
        let file = try await exitedAgentKeptAFile(staging, pasteboard)

        let relaunched = staging.makeSibling(
            retirement: ClipboardStagingRetirement(ledger: ClipboardWriteLedger(), pasteboard: { pasteboard }))
        try await Backstop("reclaimAbandonedRoots(then:)").park { done in relaunched.reclaimAbandonedRoots { done(()) }
        }
        #expect(pasteboard.dataByItem == [[Self.text: Data("first".utf8)]])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("The next launch leaves a pasteboard that moved on since an agent exited alone, and removes its staging")
    func nextLaunchLeavesAMovedOnPasteboard() async throws {
        let staging = TestStagingRoot()
        let pasteboard = FakePasteboard(pollsOnlyWhenTold: true)
        let file = try await exitedAgentKeptAFile(staging, pasteboard)
        #expect(pasteboard.setString("moved on", forType: .string))
        let movedOn = pasteboard.changeCount

        let relaunched = staging.makeSibling(
            retirement: ClipboardStagingRetirement(ledger: ClipboardWriteLedger(), pasteboard: { pasteboard }))
        try await Backstop("reclaimAbandonedRoots(then:)").park { done in relaunched.reclaimAbandonedRoots { done(()) }
        }
        #expect(pasteboard.changeCount == movedOn)
        #expect(pasteboard.items.first?.data(forType: .string) == Data("moved on".utf8))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Retraction lines

    /// The notice lines a clipboard logged.
    private final class Lines: Sendable {
        private let lines = Locked<[String]>([])

        var logger: KernovaLogger {
            KernovaLogger(
                subsystem: "app.kernova.macosagent", category: "GuestClipboard",
                sink: .init {
                    [lines] level, _, _, segments in
                    guard level == .notice else { return }
                    lines.withLock { $0.append(segments.map(\.text).joined()) }
                })
        }

        /// The retraction lines, in order.
        var retractions: [String] { lines.withLock { $0 }.filter { $0.hasPrefix("Retracted") } }
    }

    @Test("Passthrough stopping takes back the host's concealed text pasted in the guest, and the guest says so (41e)")
    func passthroughStoppingLogsTheRetraction() async throws {
        let lines = Lines()
        let pasteboard = FakePasteboard(pollsOnlyWhenTold: true)
        let clipboard = GuestClipboard(
            pasteboard: pasteboard, stagingRoot: TestStagingRoot().root, logger: lines.logger)
        let link = RecordingLink(items: [Self.textItem], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        clipboard.setLink(link)
        clipboard.end.handle(
            .offerReceived(ItemSetHeaderValue(feature: .clipboard, token: Self.hostToken, concealed: true, count: 1)),
            on: link)
        try await pasteboard.changed.wait { !pasteboard.promisedTypes.isEmpty }
        let fired = BlockingCall { pasteboard.invokeProvider(forType: Self.text) }
        try await link.changed.wait { link.opened.count == 1 }
        try land(Data("hunter2-mac".utf8), pull: 0, clipboard, link)
        #expect(try await fired.returned() == Data("hunter2-mac".utf8))
        try await drainMainQueue()
        let shown = clipboard.activity

        clipboard.end.handle(
            .offerEnded(.clipboard, .remote, token: Self.hostToken, .resetByPeer(WireError(.disabledByPolicy))),
            on: link)
        #expect(pasteboard.items.isEmpty)
        #expect(
            lines.retractions == [
                "Retracted the Mac's clipboard from the guest pasteboard: the clipboard setting changed"
            ])
        // Silent to the user.
        #expect(clipboard.activity == shown)
    }
}
