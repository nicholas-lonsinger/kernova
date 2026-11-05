import AppKit
import Foundation
import KernovaKit
import KernovaSynchronization

/// In-memory `ClipboardWritePasteboard` recording every promised write, with a
/// seam that fires a promise's provider the way the OS does.
///
/// A test fires a promise when it chooses rather than when a paste asks, and
/// makes a write fail on request; it stands in for the write half on either
/// end of the wire.
///
/// Thread-safe: ``invokeProvider(forType:itemIndex:)`` blocks its calling thread
/// until the lazy pull behind the promise resolves, so it runs off the test's
/// main actor while the setup and assertions run on it.
public final class FakeWritePasteboard: ClipboardWritePasteboard, Sendable {
    /// One written pasteboard item: the data written now, the types it
    /// promises and the provider serving them.
    private struct PromisedItem: Sendable {
        let data: [NSPasteboard.PasteboardType: Data]
        let types: [NSPasteboard.PasteboardType]
        var provider: (any NSPasteboardItemDataProvider & Sendable)?
        /// What a fired provider set, which the item holds as data from then on.
        var provided: [NSPasteboard.PasteboardType: Data] = [:]
    }

    private struct State: Sendable {
        var changeCount = 0
        var prepareCount = 0
        var writeAttempts = 0
        var lastPrepareOptions: NSPasteboard.ContentsOptions?
        var items: [PromisedItem] = []
        var writeFailuresRemaining = 0
        var providerInvocations = 0
        /// Providers another process's write displaced, whose finish waits for this process's next use.
        var owedFinishes: [any NSPasteboardItemDataProvider & Sendable] = []

        /// Drops what is on the pasteboard, handing back the providers that
        /// were serving it.
        mutating func takeItems() -> [any NSPasteboardItemDataProvider & Sendable] {
            defer { items.removeAll() }
            return items.compactMap(\.provider)
        }
    }

    private let state = Locked(State())

    /// Fires after every mutation — a prepare, a write (successful or not), and
    /// a clear — so a test awaits the change instead of polling.
    public let changed = AsyncGate()

    /// Creates an empty pasteboard double.
    public init() {}

    // MARK: - Recorded state

    /// Monotonic change count, bumped by every prepare and every clear exactly
    /// as `NSPasteboard`'s is — and by no write, since `writeObjects` moves it
    /// no further than the `prepareForNewContents` before it already did.
    public var changeCount: Int {
        deliverOwedFinishes()
        return state.withLock { $0.changeCount }
    }

    /// How many times `prepareForNewContents(with:)` has run.
    public var prepareCount: Int { state.withLock { $0.prepareCount } }

    /// Options of the most recent `prepareForNewContents(with:)`; `nil` before
    /// the first write.
    public var lastPrepareOptions: NSPasteboard.ContentsOptions? {
        state.withLock { $0.lastPrepareOptions }
    }

    /// How many times `writeItems(_:)` has been attempted, failures included.
    public var writeAttempts: Int { state.withLock { $0.writeAttempts } }

    /// How many promised providers have been fired, for a test proving one was
    /// *not*.
    public var providerInvocations: Int { state.withLock { $0.providerInvocations } }

    /// Every promised type across all items, concatenated in item order.
    public var promisedTypes: [NSPasteboard.PasteboardType] {
        state.withLock { $0.items.flatMap(\.types) }
    }

    /// The types each promised item offers, in item order.
    public var promisedTypesByItem: [[NSPasteboard.PasteboardType]] {
        state.withLock { $0.items.map(\.types) }
    }

    /// The data each item was written with, in item order.
    public var dataByItem: [[NSPasteboard.PasteboardType: Data]] {
        state.withLock { $0.items.map(\.data) }
    }

    /// How many promised items the last successful write registered.
    public var promisedItemCount: Int { state.withLock { $0.items.count } }

    /// Makes the next `times` `writeItems(_:)` calls fail, modelling an
    /// OS-level pasteboard write failure.
    public func failNextWrite(times: Int = 1) {
        state.withLock { $0.writeFailuresRemaining += times }
    }

    // MARK: - ClipboardWritePasteboard

    /// Clears the recorded state, noting the options this write was marked with.
    @discardableResult
    public func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        deliverOwedFinishes()
        let (count, displaced) = state.withLock { state in
            let displaced = state.takeItems()
            state.prepareCount += 1
            state.lastPrepareOptions = options
            state.changeCount += 1
            return (state.changeCount, displaced)
        }
        finish(displaced)
        changed.notify()
        return count
    }

    /// Records one promise per entry, unless a failure was armed.
    @discardableResult
    public func writeItems(_ entries: [ClipboardWriteItem]) -> Bool {
        deliverOwedFinishes()
        let (written, displaced) = state.withLock {
            state -> (Bool, [any NSPasteboardItemDataProvider & Sendable]) in
            state.writeAttempts += 1
            guard state.writeFailuresRemaining == 0 else {
                state.writeFailuresRemaining -= 1
                return (false, [])
            }
            let displaced = state.takeItems()
            state.items = entries.map { entry in
                PromisedItem(
                    data: Dictionary(entry.data.map { ($0.type, $0.bytes) }, uniquingKeysWith: { first, _ in first }),
                    types: entry.promised, provider: entry.provider)
            }
            return (true, displaced)
        }
        finish(displaced)
        changed.notify()
        return written
    }

    /// Empties the pasteboard, bumping the change count as a real one does.
    @discardableResult
    public func clearContents() -> Int {
        deliverOwedFinishes()
        let (count, displaced) = state.withLock { state in
            let displaced = state.takeItems()
            state.changeCount += 1
            return (state.changeCount, displaced)
        }
        finish(displaced)
        changed.notify()
        return count
    }

    /// Another process writes: the change count moves and what stood is gone, but the providers it displaced
    /// are told they are finished only at this process's next use of the pasteboard — any call here but this
    /// one — as AppKit does (docs/research/2026-11-04-pasteboard-replacement-finish-waits-for-next-use.md).
    public func replaceFromAnotherProcess() {
        state.withLock { state in
            state.owedFinishes += state.takeItems()
            state.changeCount += 1
        }
        changed.notify()
    }

    private func deliverOwedFinishes() {
        let owed = state.withLock { state in
            defer { state.owedFinishes = [] }
            return state.owedFinishes
        }
        finish(owed)
    }

    /// Tells each displaced provider the pasteboard is done with it, as a real
    /// one does — the call that lets an owner release it.
    ///
    /// Outside the lock: a provider's owner takes its own lock to release it.
    ///
    /// The pasteboard handed over, which its callers ignore, is a private named
    /// board, so nothing here can reach the machine's own clipboard.
    private func finish(_ providers: [any NSPasteboardItemDataProvider & Sendable]) {
        guard !providers.isEmpty else { return }
        let board = NSPasteboard(name: .init("app.kernova.fake-write"))
        for provider in providers {
            provider.pasteboardFinishedWithDataProvider?(board)
        }
    }

    /// Models AppKit once a reader has had every type item `itemIndex`'s provider promised, the write still
    /// standing: it tells the provider it is finished and lets go of it, the item keeping what was provided
    /// (docs/research/2026-11-04-pasteboard-finished-with-data-provider.md). The change count does not move.
    public func finishProvider(itemIndex: Int) {
        let provider = state.withLock { state -> (any NSPasteboardItemDataProvider & Sendable)? in
            guard state.items.indices.contains(itemIndex) else { return nil }
            defer { state.items[itemIndex].provider = nil }
            return state.items[itemIndex].provider
        }
        provider?.pasteboardFinishedWithDataProvider?(NSPasteboard(name: .init("app.kernova.fake-write")))
    }

    // MARK: - Firing a promise

    /// Fires a promised item's provider the way the OS does, synchronously.
    ///
    /// Builds a fresh `NSPasteboardItem`, runs the recorded provider's
    /// `pasteboard(_:item:provideDataForType:)`, and returns what it set — or
    /// `nil` when it declined. What it set the item holds as data from then on,
    /// while the write stands. `itemIndex` targets one item, needed when several
    /// promise the same type (`.fileURL` across a multi-file offer); `nil` takes
    /// the first offering it. **This blocks until the pull behind the promise
    /// resolves**, so call it off the test's main actor.
    public func invokeProvider(
        forType type: NSPasteboard.PasteboardType, itemIndex: Int?
    ) -> Data? {
        deliverOwedFinishes()
        let fired = state.withLock { state -> (index: Int, provider: any NSPasteboardItemDataProvider & Sendable, changeCount: Int)? in
            let index =
                itemIndex.flatMap { state.items.indices.contains($0) ? $0 : nil }
                ?? state.items.firstIndex { $0.types.contains(type) && $0.provider != nil }
            guard let index, state.items[index].types.contains(type), let provider = state.items[index].provider
            else { return nil }
            state.providerInvocations += 1
            return (index, provider, state.changeCount)
        }
        guard let fired else { return nil }
        let item = NSPasteboardItem()
        fired.provider.pasteboard(nil, item: item, provideDataForType: type)
        guard let bytes = item.data(forType: type) else { return nil }
        state.withLock { state in
            guard state.changeCount == fired.changeCount, state.items.indices.contains(fired.index) else { return }
            state.items[fired.index].provided[type] = bytes
        }
        changed.notify()
        return bytes
    }

    /// The bytes item `index` holds as `type`: written as data, or set by a fired provider.
    public func data(forType type: NSPasteboard.PasteboardType, itemAt index: Int) -> Data? {
        state.withLock { state in
            guard state.items.indices.contains(index) else { return nil }
            return state.items[index].data[type] ?? state.items[index].provided[type]
        }
    }
}
