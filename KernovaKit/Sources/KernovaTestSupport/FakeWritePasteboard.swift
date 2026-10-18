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
    /// One promised pasteboard item: the types it offers and the provider
    /// serving them.
    private struct PromisedItem: Sendable {
        let types: [NSPasteboard.PasteboardType]
        let provider: any NSPasteboardItemDataProvider & Sendable
    }

    private struct State: Sendable {
        var changeCount = 0
        var prepareCount = 0
        var writeAttempts = 0
        var lastPrepareOptions: NSPasteboard.ContentsOptions?
        var items: [PromisedItem] = []
        var writeFailuresRemaining = 0
        var providerInvocations = 0

        /// Drops what is on the pasteboard, handing back the providers that
        /// were serving it.
        mutating func takeItems() -> [any NSPasteboardItemDataProvider & Sendable] {
            defer { items.removeAll() }
            return items.map(\.provider)
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
    public var changeCount: Int { state.withLock { $0.changeCount } }

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
    public func writeItems(
        _ entries: [(
            types: [NSPasteboard.PasteboardType], provider: any NSPasteboardItemDataProvider & Sendable
        )]
    ) -> Bool {
        let (written, displaced) = state.withLock {
            state -> (Bool, [any NSPasteboardItemDataProvider & Sendable]) in
            state.writeAttempts += 1
            guard state.writeFailuresRemaining == 0 else {
                state.writeFailuresRemaining -= 1
                return (false, [])
            }
            let displaced = state.takeItems()
            state.items = entries.map { PromisedItem(types: $0.types, provider: $0.provider) }
            return (true, displaced)
        }
        finish(displaced)
        changed.notify()
        return written
    }

    /// Empties the pasteboard, bumping the change count as a real one does.
    @discardableResult
    public func clearContents() -> Int {
        let (count, displaced) = state.withLock { state in
            let displaced = state.takeItems()
            state.changeCount += 1
            return (state.changeCount, displaced)
        }
        finish(displaced)
        changed.notify()
        return count
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

    // MARK: - Firing a promise

    /// Fires a promised item's provider the way the OS does, synchronously.
    ///
    /// Builds a fresh `NSPasteboardItem`, runs the recorded provider's
    /// `pasteboard(_:item:provideDataForType:)`, and returns what it set — or
    /// `nil` when it declined. `itemIndex` targets one item, needed when several
    /// promise the same type (`.fileURL` across a multi-file offer); `nil` takes
    /// the first offering it. **This blocks until the pull behind the promise
    /// resolves**, so call it off the test's main actor.
    public func invokeProvider(
        forType type: NSPasteboard.PasteboardType, itemIndex: Int?
    ) -> Data? {
        let provider = state.withLock { state -> (any NSPasteboardItemDataProvider & Sendable)? in
            let provider: (any NSPasteboardItemDataProvider & Sendable)?
            if let itemIndex {
                let item = state.items.indices.contains(itemIndex) ? state.items[itemIndex] : nil
                provider = item.flatMap { $0.types.contains(type) ? $0.provider : nil }
            } else {
                provider = state.items.first { $0.types.contains(type) }?.provider
            }
            if provider != nil { state.providerInvocations += 1 }
            return provider
        }
        guard let provider else { return nil }
        let item = NSPasteboardItem()
        provider.pasteboard(nil, item: item, provideDataForType: type)
        guard let bytes = item.data(forType: type) else { return nil }
        changed.notify()
        return bytes
    }
}
