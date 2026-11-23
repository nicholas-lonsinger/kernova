import AppKit
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaClipboardItems
import KernovaKit
import KernovaTestSupport
import KernovaWire
import Testing

/// One side's clipboard end: what the host takes of the guest's offers under its gate, the host's request for the
/// guest's clipboard, and the passthrough poll and publish behaviors, each over a fake pasteboard and an in-memory
/// connection the test steps.
@Suite("ClipboardEnd", .caseScoped)
@MainActor
struct ClipboardEndTests {
    private let staging = TestStagingRoot()
    private let scratch = TestScratchDirectory(prefix: "clipboard-end")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    private func readOutcomes(_ pair: ClipboardEndPair, _ side: ClipboardWire.Side) -> [ClipboardReadOutcome] {
        (pair.events[side] ?? []).compactMap { if case .readEnded(_, let outcome) = $0 { outcome } else { nil } }
    }

    // MARK: - File grants

    /// A host end whose copy of `copied` the guest's end holds open, and that offer.
    private func openCopy(_ copied: URL, gate: ClipboardOfferGate) async throws -> (ClipboardEndPair, ItemOffer) {
        try Data("copied".utf8).write(to: copied)
        let pair = ClipboardEndPair(staging: staging.root, gate: gate)
        pair.hostPasteboard.setFiles([copied])
        if gate == .everyCopy { pair.poll() } else { pair.host.offerOnCommand() }
        try await pair.settle()
        return (pair, try #require(pair.wire?.opened(.host).last))
    }

    /// A pull of `offer`'s first item's first representation, as stream `stream` carries it.
    private static func pull(of offer: ItemOffer, stream: UInt32 = 1) -> (ItemPullID, PullRequest) {
        var request = PullRequest()
        request.token = offer.token
        return (ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: stream)), request)
    }

    /// The path `content` serves its tree from, its links resolved.
    private static func treePath(_ content: Result<ItemContent, WireError>) -> String? {
        guard case .success(.tree(let path)) = content else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// How a pull's serve comes to its end.
    enum ServeEnding: CaseIterable, Sendable {
        /// Its end alone.
        case served
        /// Its offer ending first.
        case offerEndedFirst
        /// The connection leaving first.
        case linkDownFirst
    }

    @Test("A pull of a copied file holds its grant exactly until its serve ends", arguments: ServeEnding.allCases)
    func pullHoldsItsGrantUntilItsServeEnds(ending: ServeEnding) async throws {
        let copied = scratch.url.appendingPathComponent("copied.txt")
        let (pair, offer) = try await openCopy(copied, gate: .everyCopy)
        let sandbox = pair.hostPasteboard.sandbox
        let link = try #require(pair.wire).hostLink
        let (id, request) = Self.pull(of: offer)
        let host = pair.host

        let served = try await offCooperativePool { host.content(id, request) }
        #expect(Self.treePath(served) == copied.resolvingSymlinksInPath().path)
        #expect(sandbox.grants(of: copied) == 1)
        switch ending {
        case .served:
            break
        case .offerEndedFirst:
            host.handle(
                .offerEnded(.clipboard, .local, token: offer.token, .resetLocally(WireError(.cancelled))), on: link)
        case .linkDownFirst:
            pair.linkDown()
        }
        #expect(sandbox.grants(of: copied) == 1)

        host.handle(.serveEnded(.clipboard, id, .landed), on: link)

        #expect(sandbox.grants(of: copied) == 0)
        #expect(sandbox.unheldGiveBacks.isEmpty)
    }

    @Test("A pull that ends before its content is asked for takes no grant")
    func pullEndedFirstTakesNoGrant() async throws {
        let copied = scratch.url.appendingPathComponent("copied.txt")
        let (pair, offer) = try await openCopy(copied, gate: .everyCopy)
        let (id, request) = Self.pull(of: offer)
        let host = pair.host
        host.handle(.serveEnded(.clipboard, id, .closed(.connectionLost)), on: try #require(pair.wire).hostLink)

        let served = try await offCooperativePool { host.content(id, request) }

        guard case .failure(let error) = served else {
            Issue.record("served \(served)")
            return
        }
        #expect(error.code == .cancelled)
        #expect(pair.hostPasteboard.sandbox.grants(of: copied) == 0)
    }

    // MARK: - The poll

    @Test("A copied zero-byte file is offered like any other, with nothing left out")
    func zeroByteFileIsOffered() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .everyCopy)
        let empty = scratch.url.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        pair.hostPasteboard.setFiles([empty])
        pair.poll()
        try await pair.settle()

        let offer = try #require(pair.wire?.opened(.host).last)
        let files = offer.items.flatMap(\.representations).filter { $0.storage != .inline }
        #expect(files.map { String(decoding: $0.name, as: UTF8.self) } == ["empty.txt"])
        #expect(files.first?.sizeEstimate == 0)
        #expect(readOutcomes(pair, .host) == [.offered(skipped: 0)])
    }
}
