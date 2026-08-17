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
    private var resolved: [(type: NSPasteboard.PasteboardType, data: Data)] = []
    private var writeFailuresRemaining = 0
    private var storedProviderInvocations = 0

    /// Fires after every mutation — a prepare, a write (successful or not), and
    /// a clear — so a test awaits the change instead of polling.
    public let changed = AsyncGate()

    /// Creates an empty pasteboard double.
    public init() {}

    // MARK: - Recorded state

    /// Monotonic change count, bumped by every prepare, write and clear exactly
    /// as `NSPasteboard`'s is.
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

    /// The bytes a provider resolved for `type`, as a real `NSPasteboardItem`
    /// would retain them.
    public func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        lock.withLock { resolved.first { $0.type == type }?.data }
    }

    /// The provider of the promised item at `index`, for a test firing it after
    /// something has replaced the write it belonged to.
    public func provider(at index: Int) -> NSPasteboardItemDataProvider? {
        lock.withLock { items.indices.contains(index) ? items[index].provider : nil }
    }

    /// Makes the next `times` `writeItems(_:)` calls fail, modelling an
    /// OS-level pasteboard write failure.
    public func failNextWrite(times: Int = 1) {
        lock.withLock { writeFailuresRemaining += times }
    }

    // MARK: - ClipboardWritePasteboard

    /// Clears the recorded state, noting the options this write was marked with.
    @discardableResult
    public func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        let count = lock.withLock { () -> Int in
            items.removeAll()
            resolved.removeAll()
            storedPrepareCount += 1
            storedLastPrepareOptions = options
            storedChangeCount += 1
            return storedChangeCount
        }
        changed.notify()
        return count
    }

    /// Records one promise per entry, unless a failure was armed.
    @discardableResult
    public func writeItems(
        _ entries: [(types: [NSPasteboard.PasteboardType], provider: NSPasteboardItemDataProvider)]
    ) -> Bool {
        let written = lock.withLock { () -> Bool in
            storedWriteAttempts += 1
            guard writeFailuresRemaining == 0 else {
                writeFailuresRemaining -= 1
                return false
            }
            items = entries.map { PromisedItem(types: $0.types, provider: $0.provider) }
            resolved.removeAll()
            storedChangeCount += 1
            return true
        }
        changed.notify()
        return written
    }

    /// Empties the pasteboard, bumping the change count as a real one does.
    @discardableResult
    public func clearContents() -> Int {
        let count = lock.withLock { () -> Int in
            items.removeAll()
            resolved.removeAll()
            storedChangeCount += 1
            return storedChangeCount
        }
        changed.notify()
        return count
    }

    // MARK: - Firing a promise

    /// Fires the promise for `type` on the first item offering it.
    public func invokeProvider(forType type: NSPasteboard.PasteboardType) -> Data? {
        invokeProvider(forType: type, itemIndex: nil)
    }

    /// Fires a promised item's provider the way the OS does, synchronously.
    ///
    /// Builds a fresh `NSPasteboardItem`, runs the recorded provider's
    /// `pasteboard(_:item:provideDataForType:)`, and returns what it set — or
    /// `nil` when it declined. `itemIndex` targets one item, needed when several
    /// promise the same type (`.fileURL` across a multi-file offer); `nil` takes
    /// the first offering it. **This blocks until the pull behind the promise
    /// resolves**, so call it off the test's main actor.
    ///
    /// The bytes are cached back as a real `NSPasteboardItem` retains provided
    /// data, so a later ``data(forType:)`` reads what a paste would see without
    /// re-firing.
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
        lock.withLock {
            resolved.removeAll { $0.type == type }
            resolved.append((type: type, data: bytes))
        }
        changed.notify()
        return bytes
    }
}
