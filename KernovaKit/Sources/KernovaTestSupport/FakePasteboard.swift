import AppKit
import Foundation
import KernovaKit

/// In-memory ``ClipboardPasteboard`` over ``FakeWritePasteboard``.
///
/// The write half — promise registration, the OS-fires-a-provider seam, the
/// write-failure seam — is the shared double both ends of the wire use. Added
/// here: the read half, and the resident setup
/// (`setItem`/`setItems`/`setString`) that models a *user* copying, which an
/// outbound poll reads. A promise
/// write leaves no resident bytes; a fired provider's bytes are what its item
/// serves from afterwards, as a real `NSPasteboardItem` retains them.
///
/// Thread-safe: ``invokeProvider(forType:itemIndex:)`` blocks its calling thread
/// until the lazy pull behind the promise resolves, so it runs off the test's
/// main actor.
public final class FakePasteboard: ClipboardPasteboard, @unchecked Sendable {
    private let writer = FakeWritePasteboard()
    private let lock = NSLock()
    /// Resident items — a user's own copy, one entry per pasteboard item.
    private var residents: [[(type: NSPasteboard.PasteboardType, data: Data)]] = []
    /// Bytes a fired provider resolved, which a promised item serves from.
    private var resolved: [NSPasteboard.PasteboardType: Data] = [:]

    /// Creates an empty pasteboard double.
    public init() {}

    /// Fires after every mutation; await it instead of polling.
    public var changed: AsyncGate { writer.changed }

    /// The write half's change count, which every write and staging call bumps.
    public var changeCount: Int { writer.changeCount }

    /// The pasteboard's items: a standing promise's, which serve only what a
    /// fired provider has already resolved, or the user's own copy.
    public var items: [any ClipboardPasteboardItemReading] {
        let promised = writer.promisedTypesByItem
        guard promised.isEmpty else {
            let bytes = lock.withLock { resolved }
            return promised.map { FakePasteboardItem(types: $0, bytes: bytes) }
        }
        return lock.withLock { residents }.map(FakePasteboardItem.init)
    }

    // MARK: - Promised writes

    /// Every promised type across all items, concatenated in item order (a
    /// multi-file offer promises one item per file).
    public var promisedTypes: [NSPasteboard.PasteboardType] { writer.promisedTypes }

    /// The types each promised item offers, in item order.
    public var promisedTypesByItem: [[NSPasteboard.PasteboardType]] { writer.promisedTypesByItem }

    /// How many times `prepareForNewContents(with:)` has run.
    public var prepareCount: Int { writer.prepareCount }

    /// How many times `writeItems(_:)` has been attempted, failures included.
    public var writeAttempts: Int { writer.writeAttempts }

    /// Number of promised pasteboard items the last write registered.
    public var promisedItemCount: Int { writer.promisedItemCount }

    /// Options passed to the most recent `prepareForNewContents(with:)`; `nil`
    /// until the first promise write.
    public var lastPrepareOptions: NSPasteboard.ContentsOptions? { writer.lastPrepareOptions }

    /// How many promised providers have been fired, for a test proving a
    /// poll fired none.
    public var providerInvocations: Int { writer.providerInvocations }

    /// Makes the next `times` `writeItems(_:)` calls fail, modelling an
    /// OS-level pasteboard write failure.
    public func failNextWrite(times: Int = 1) { writer.failNextWrite(times: times) }

    /// Fires a promised item's provider the way the OS does, synchronously.
    ///
    /// `itemIndex` targets one item, needed when several promise the same type
    /// (`.fileURL` across a multi-file offer); `nil` takes the first offering
    /// it. **This blocks until the pull behind the promise resolves**, so call
    /// it off the test's main actor.
    public func invokeProvider(
        forType type: NSPasteboard.PasteboardType, itemIndex: Int? = nil
    ) -> Data? {
        guard let bytes = writer.invokeProvider(forType: type, itemIndex: itemIndex) else {
            return nil
        }
        lock.withLock { resolved[type] = bytes }
        return bytes
    }

    /// Drops the resident copy and clears the write half.
    @discardableResult
    public func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        clearResidents()
        return writer.prepareForNewContents(with: options)
    }

    /// Registers one lazy promise per item, recording no bytes.
    @discardableResult
    public func writeItems(
        _ items: [(types: [NSPasteboard.PasteboardType], provider: NSPasteboardItemDataProvider)]
    ) -> Bool {
        let written = writer.writeItems(items)
        if written { clearResidents() }
        return written
    }

    /// Empties the pasteboard, resident copy and promise alike.
    @discardableResult
    public func clearContents() -> Int {
        clearResidents()
        return writer.clearContents()
    }

    // MARK: - Resident setup (a user copying)

    /// Places resident (type, data) pairs, modelling a user copying in the
    /// guest. Clears any promise.
    @discardableResult
    public func setItem(_ representations: [(type: NSPasteboard.PasteboardType, data: Data)]) -> Bool {
        setItems([representations])
    }

    /// Places several resident pasteboard items, modelling a multi-select copy
    /// in the guest.
    @discardableResult
    public func setItems(_ items: [[(type: NSPasteboard.PasteboardType, data: Data)]]) -> Bool {
        lock.withLock {
            residents = items
            resolved.removeAll()
        }
        // Drops any promise and bumps the change count, as a real write does.
        writer.clearContents()
        return true
    }

    /// Replaces the resident item with a single text representation —
    /// equivalent to a user copying text inside the guest.
    @discardableResult
    public func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        setItem([(type: type, data: Data(string.utf8))])
    }

    private func clearResidents() {
        lock.withLock {
            residents.removeAll()
            resolved.removeAll()
        }
    }
}
