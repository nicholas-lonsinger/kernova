import AppKit
import Foundation
import KernovaAgentCore
import KernovaClipboardItems
import KernovaLogging
import KernovaSynchronization
import KernovaTestSupport
import KernovaTransferProgress
import KernovaWire
import Testing

@testable import KernovaKit

/// A paste's Cancel on its readout, at each point of a multi-file paste: a Cancel the paste is still running for
/// spends the offer, so nothing more of it is pulled and its write is withdrawn; one after the paste's readout ended
/// reaches nothing, and the offer stays pullable.
@Suite("Paste Cancel", .caseScoped)
@MainActor
struct ClipboardPasteCancelTests {
    /// A connection whose pulls open and end only when the test says, recording every call the end makes of it.
    private final class HeldPullLink: ClipboardItemLink, Sendable {
        private struct State {
            var pulls: [@Sendable (Result<ItemPullID, WireError>) -> Void] = []
            var names: [Data] = []
            var cancelled: [ItemPullID] = []
            var released: [Data] = []
        }

        let items: [OfferedItem]
        let changed = AsyncGate()
        private let state = Locked(State())

        init(items: [OfferedItem]) {
            self.items = items
        }

        /// How many pulls the end asked to open.
        var pullCount: Int { state.withLock(\.pulls.count) }
        var cancelled: [ItemPullID] { state.withLock(\.cancelled) }
        var released: [Data] { state.withLock(\.released) }

        /// Opens the `index`th pull the end asked for, returning its id and the name it lands under.
        func open(_ index: Int) -> (id: ItemPullID, name: Data) {
            let (completion, name) = state.withLock { ($0.pulls[index], $0.names[index]) }
            let id = ItemPullID(
                generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 2 * UInt32(index) + 1))
            completion(.success(id))
            return (id, name)
        }

        func offerItems(_ offer: ItemOffer, _ completion: @escaping @Sendable (WireError?) -> Void) {
            completion(WireError(.cancelled, debugDetail: "this side offers nothing here"))
        }

        func withdrawOffer(_ token: Data, code: ErrorCode) {}

        func releaseOffer(_ token: Data) {
            state.withLock { $0.released.append(token) }
        }

        func refuseOffer(_ token: Data, _ error: WireError) {}

        func readItem(_ token: Data, item: UInt32, _ completion: @escaping @Sendable (OfferedItem?) -> Void) {
            completion(items.indices.contains(Int(item)) ? items[Int(item)] : nil)
        }

        func pullItem(
            _ order: ItemPullOrder, _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void
        ) {
            guard case .staged(_, .exactly(let name)) = order.landing else {
                return completion(.failure(WireError(.internal, debugDetail: "a FILE lands staged, by its name")))
            }
            state.withLock {
                $0.pulls.append(completion)
                $0.names.append(name)
            }
            changed.notify()
        }

        func cancelPull(_ id: ItemPullID) {
            state.withLock { $0.cancelled.append(id) }
        }

        func order(
            token: Data, item: UInt32, representation: UInt32, byteCeiling: UInt64, landing: ItemLanding,
            budget: ByteBudget?
        ) throws(WireError) -> ItemPullOrder {
            var request = PullRequest()
            request.token = token
            request.item = item
            request.representation = representation
            request.byteCeiling = byteCeiling
            return ItemPullOrder(request, landing: landing, budget: budget)
        }
    }

    /// Where the paste's Cancel lands.
    enum CancelPoint: CaseIterable, Sendable {
        /// The first file's pull is asked for, and the connection has not opened it yet.
        case beforeTheFirstPullOpens
        /// The first file's pull is open, part of it landed.
        case withAPullInFlight
        /// The first file landed, and the pasting app has not asked for the second yet.
        case betweenTwoFiles
        /// The paste's readout ended at its idle gap, the reporter not yet told: a Cancel clicked on the readout
        /// it still shows.
        case afterTheIdleTerminal
    }

    private static let token = Data(repeating: 9, count: 16)
    private static let logger = KernovaLogger(subsystem: "app.kernova.tests", category: "ClipboardPasteCancelTests")

    private let staging = TestStagingRoot()

    /// Three files, each of four bytes, offered by the far side.
    private static var items: [OfferedItem] {
        (0..<3).map { index in
            var file = Representation()
            file.storage = .file
            file.name = Data("file\(index).txt".utf8)
            file.sizeEstimate = 4
            var item = OfferedItem()
            item.representations = [file]
            return item
        }
    }

    /// Fires the promise of item `index`'s file the way the OS does, on a thread of its own: what the paste got.
    private static func paste(_ index: Int, from pasteboard: FakePasteboard) -> BlockingCall<Data?> {
        BlockingCall { pasteboard.invokeProvider(forType: .fileURL, itemIndex: index) }
    }

    /// Holds the main thread until `done` reads true, so main-queue work queued meanwhile waits behind it; false
    /// at the backstop. It sleeps between reads rather than waiting on what sets `done`, which runs at a lower
    /// quality of service than the main thread.
    private static func hold(until done: Locked<Bool>) -> Bool {
        let backstop = Date(timeIntervalSinceNow: testWaitBackstop)
        while !done.withLock({ $0 }) {
            guard Date() < backstop else { return false }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return true
    }

    @Test(
        "A Cancel during a paste spends its offer; one after its readout ended leaves it pullable",
        arguments: CancelPoint.allCases)
    func cancel(at point: CancelPoint) async throws {
        let pasteboard = FakePasteboard(pollsOnlyWhenTold: true)
        let reporter = ClipboardTransferReporter(clock: GatedEngineClock())
        let clock = GatedEngineClock()
        let link = HeldPullLink(items: Self.items)
        let end = ClipboardEnd<ClipboardGuest>(
            pasteboard: pasteboard, gate: .onCommand, stagingLabel: "paste-cancel", stagingRoot: staging.root,
            pasteCeiling: { ClipboardPasteLimit.defaultBytes },
            readouts: ClipboardPasteReadouts(reporter: reporter, peerName: { "Mac" }, revealDelay: 0, clock: clock),
            providerRegistry: LazyClipboardProviderRegistry(), ledger: ClipboardWriteLedger(), logger: Self.logger)
        end.setLink(link)
        end.handle(
            .offerReceived(
                ItemSetHeaderValue(
                    feature: .clipboard, token: Self.token, concealed: false, count: Self.items.count, request: Data())),
            on: link)
        try await pasteboard.changed.wait { pasteboard.promisedTypesByItem.count == Self.items.count }

        let first = Self.paste(0, from: pasteboard)
        try await link.changed.wait { link.pullCount == 1 }
        try await drainMainQueue()
        guard case .running(let readout, _) = reporter.report else {
            Issue.record("the paste shows no readout: \(reporter.report)")
            return
        }

        switch point {
        case .beforeTheFirstPullOpens:
            #expect(reporter.cancel(readout.operationID))
            let (id, _) = link.open(0)
            #expect(link.cancelled == [id])
            #expect(try await first.returned() == nil)
        case .withAPullInFlight:
            let (id, _) = link.open(0)
            end.pullAdvanced(id, ItemLandingProgress(landed: 2, declared: 4))
            #expect(reporter.cancel(readout.operationID))
            #expect(link.cancelled == [id])
            #expect(try await first.returned() == nil)
            end.pullEnded(id, .closed(.resetLocally(WireError(.cancelled))))
        case .betweenTwoFiles:
            let (id, name) = link.open(0)
            end.pullEnded(id, .landed(.named(name)))
            #expect(try await first.returned() != nil)
            #expect(reporter.cancel(readout.operationID))
        case .afterTheIdleTerminal:
            let (id, name) = link.open(0)
            end.pullEnded(id, .landed(.named(name)))
            #expect(try await first.returned() != nil)
            let gap = try #require(clock.parked.first)
            let terminalRan = Locked(false)
            Task.detached {
                await clock.completion(of: gap)
                terminalRan.withLock { $0 = true }
            }
            clock.release(gap)
            try #require(Self.hold(until: terminalRan))
            #expect(!reporter.cancel(readout.operationID))
        }
        try await drainMainQueue()

        switch point {
        case .beforeTheFirstPullOpens, .withAPullInFlight, .betweenTwoFiles:
            #expect(pasteboard.promisedTypes.isEmpty)
            #expect(link.released == [Self.token])
            #expect(try await Self.paste(1, from: pasteboard).returned() == nil)
            #expect(link.pullCount == 1)
            #expect(reporter.refusal == nil)
        case .afterTheIdleTerminal:
            try #require(!pasteboard.promisedTypes.isEmpty)
            try #require(link.released.isEmpty)
            let second = Self.paste(1, from: pasteboard)
            try await link.changed.wait { link.pullCount == 2 }
            let (id, name) = link.open(1)
            end.pullEnded(id, .landed(.named(name)))
            #expect(try await second.returned() != nil)
        }
    }
}
