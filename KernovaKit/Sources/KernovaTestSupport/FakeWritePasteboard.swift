import AppKit
import Foundation
import KernovaKit

/// In-memory `ClipboardWritePasteboard` recording every promised write, with a
/// seam that fires a promise's provider the way the OS does.
///
/// `NSPasteboard` is a class cluster with no public initializer, so a real one's
/// write can never be made to fail and its promises can only be fired by an
/// actual paste; this stands in for both sides of the write half on either end
/// of the wire.
///
/// Thread-safe: ``invokeProvider(forType:itemIndex:)`` blocks its calling thread
/// until the lazy pull behind the promise resolves, so it runs off the test's
/// main actor while the setup and assertions run on it.
public final class FakeWritePasteboard: ClipboardWritePasteboard, @unchecked Sendable {
    /// One promised pasteboard item: the types it offers and the provider
    /// serving them.
    private struct PromisedItem {
        let types: [NSPasteboard.PasteboardType]
        let provider: NSPasteboardItemDataProvider
    }

    private let lock = NSLock()
    private var storedChangeCount = 0
    private var storedPrepareCount = 0
    private var storedWriteAttempts = 0
    private var storedLastPrepareOptions: NSPasteboard.ContentsOptions?
    private var items: [PromisedItem] = []
    private var writeFailuresRemaining = 0
    private var storedProviderInvocations = 0

    /// Fires after every mutation — a prepare, a write (successful or not), and
    /// a clear — so a test awaits the change instead of polling.
    public let changed = AsyncGate()

    /// Creates an empty pasteboard double.
    public init() {}

    // MARK: - Recorded state

    /// Monotonic change count, bumped by every prepare and every clear exactly
    /// as `NSPasteboard`'s is — and by no write, since `writeObjects` moves it
    /// no further than the `prepareForNewContents` before it already did.
    public var changeCount: Int { lock.withLock { storedChangeCount } }

    /// How many times `prepareForNewContents(with:)` has run.
    public var prepareCount: Int { lock.withLock { storedPrepareCount } }

    /// Options of the most recent `prepareForNewContents(with:)`; `nil` before
    /// the first write.
    public var lastPrepareOptions: NSPasteboard.ContentsOptions? {
        lock.withLock { storedLastPrepareOptions }
    }

    /// How many times `writeItems(_:)` has been attempted, failures included.
    public var writeAttempts: Int { lock.withLock { storedWriteAttempts } }

    /// How many promised providers have been fired, for a test proving one was
    /// *not*.
    public var providerInvocations: Int { lock.withLock { storedProviderInvocations } }

    /// Every promised type across all items, concatenated in item order.
    public var promisedTypes: [NSPasteboard.PasteboardType] {
        lock.withLock { items.flatMap(\.types) }
    }

    /// The types each promised item offers, in item order.
    public var promisedTypesByItem: [[NSPasteboard.PasteboardType]] {
        lock.withLock { items.map(\.types) }
    }

    /// How many promised items the last successful write registered.
    public var promisedItemCount: Int { lock.withLock { items.count } }

    /// Makes the next `times` `writeItems(_:)` calls fail, modelling an
    /// OS-level pasteboard write failure.
    public func failNextWrite(times: Int = 1) {
        lock.withLock { writeFailuresRemaining += times }
    }

    // MARK: - ClipboardWritePasteboard

    /// Clears the recorded state, noting the options this write was marked with.
    @discardableResult
    public func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        let (count, displaced) = lock.withLock { () -> (Int, [NSPasteboardItemDataProvider]) in
            let displaced = takeItemsLocked()
            storedPrepareCount += 1
            storedLastPrepareOptions = options
            storedChangeCount += 1
            return (storedChangeCount, displaced)
        }
        finish(displaced)
        changed.notify()
        return count
    }

    /// Records one promise per entry, unless a failure was armed.
    @discardableResult
    public func writeItems(
        _ entries: [(types: [NSPasteboard.PasteboardType], provider: NSPasteboardItemDataProvider)]
    ) -> Bool {
        let (written, displaced) = lock.withLock { () -> (Bool, [NSPasteboardItemDataProvider]) in
            storedWriteAttempts += 1
            guard writeFailuresRemaining == 0 else {
                writeFailuresRemaining -= 1
                return (false, [])
            }
            let displaced = takeItemsLocked()
            items = entries.map { PromisedItem(types: $0.types, provider: $0.provider) }
            return (true, displaced)
        }
        finish(displaced)
        changed.notify()
        return written
    }

    /// Empties the pasteboard, bumping the change count as a real one does.
    @discardableResult
    public func clearContents() -> Int {
        let (count, displaced) = lock.withLock { () -> (Int, [NSPasteboardItemDataProvider]) in
            let displaced = takeItemsLocked()
            storedChangeCount += 1
            return (storedChangeCount, displaced)
        }
        finish(displaced)
        changed.notify()
        return count
    }

    /// Drops what is on the pasteboard, handing back the providers that were
    /// serving it. Caller holds `lock`.
    private func takeItemsLocked() -> [NSPasteboardItemDataProvider] {
        let displaced = items.map(\.provider)
        items.removeAll()
        return displaced
    }

    /// Tells each displaced provider the pasteboard is done with it, as a real
    /// one does — the call that lets an owner release it.
    ///
    /// Outside `lock`: a provider's owner takes its own lock to release it.
    private func finish(_ providers: [NSPasteboardItemDataProvider]) {
        for provider in providers {
            provider.pasteboardFinishedWithDataProvider?(Self.finishArgument)
        }
    }

    /// The pasteboard `pasteboardFinishedWithDataProvider(_:)` is handed, which
    /// its callers ignore. A private named board, so nothing here can reach the
    /// machine's own clipboard; never read and never written, so passing it
    /// between threads carries no state.
    nonisolated(unsafe) private static let finishArgument = NSPasteboard(
        name: .init("app.kernova.fake-write"))

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
        let provider: NSPasteboardItemDataProvider? = lock.withLock {
            if let itemIndex {
                guard items.indices.contains(itemIndex) else { return nil }
                let item = items[itemIndex]
                return item.types.contains(type) ? item.provider : nil
            }
            return items.first { $0.types.contains(type) }?.provider
        }
        guard let provider else { return nil }
        lock.withLock { storedProviderInvocations += 1 }
        let item = NSPasteboardItem()
        provider.pasteboard(nil, item: item, provideDataForType: type)
        guard let bytes = item.data(forType: type) else { return nil }
        changed.notify()
        return bytes
    }
}
