import AppKit
import Foundation
import os

/// Serves a clipboard offer's representations to a pasteboard lazily.
///
/// One provider is written per pasteboard item via
/// `NSPasteboardItem.setDataProvider(_:forTypes:)`. When the OS asks for a
/// promised type, the pasteboard server invokes
/// `pasteboard(_:item:provideDataForType:)` on the owner's main thread/run loop,
/// which delegates to `provide` (`nil` leaves the type empty). The owner must
/// hold each provider until `pasteboardFinishedWithDataProvider(_:)` fires. A
/// finish landing inside a fire of this provider — `provide` can run the event
/// loop, which drains a retract of the very write being served — is held until
/// the fire returns, so the owner never lets go under the executing frame.
///
/// `@unchecked Sendable`: the registry holding a provider is shared across
/// threads, the two callbacks arrive on the pasteboard server's thread for the
/// owner, and the fire-depth bookkeeping they share is lock-guarded.
public final class LazyClipboardDataProvider: NSObject, NSPasteboardItemDataProvider,
    @unchecked Sendable
{
    private let provide: (NSPasteboard.PasteboardType) -> Data?
    private let onFinished: (LazyClipboardDataProvider) -> Void

    private let lock = NSLock()
    /// Fires on the stack right now — a fire can nest another for a sibling
    /// flavor of the same item.
    private var fireDepth = 0
    /// Whether the pasteboard finished with this provider inside a fire, so the
    /// outermost fire's return owes `onFinished`.
    private var finishedWhileFiring = false

    // Same category as `LazyClipboardProviderRegistry`, so a fire and the
    // release of the provider that served it read as one sequence.
    private static let logger = Logger(subsystem: "app.kernova", category: "ClipboardProvider")

    /// - Parameters:
    ///   - provide: produces the bytes for a requested type, or `nil` to leave
    ///     it empty. Invoked synchronously on the owner's main thread/run loop.
    ///   - onFinished: called when the pasteboard no longer needs this provider,
    ///     so the owner can drop its strong reference.
    public init(
        provide: @escaping (NSPasteboard.PasteboardType) -> Data?,
        onFinished: @escaping (LazyClipboardDataProvider) -> Void
    ) {
        self.provide = provide
        self.onFinished = onFinished
    }

    /// Serves the bytes for a promised `type` on demand by delegating to
    /// `provide`, leaving the type empty when `provide` returns `nil`.
    public func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        lock.withLock { fireDepth += 1 }
        let data = provide(type)
        Self.logger.debug(
            "Provided \(data?.count ?? 0, privacy: .public) bytes for promised type '\(type.rawValue, privacy: .public)'"
        )
        if let data { item.setData(data, forType: type) }
        let owesFinish = lock.withLock { () -> Bool in
            fireDepth -= 1
            guard fireDepth == 0, finishedWhileFiring else { return false }
            finishedWhileFiring = false
            return true
        }
        guard owesFinish else { return }
        // The pasteboard is not among this object's owners, so a finish drained
        // inside `provide` would have let the owner free the object under its
        // own executing frame; the block's capture carries it through the
        // owner's release instead.
        DispatchQueue.main.async { self.onFinished(self) }
    }

    /// Notifies the owner (via `onFinished`) that the pasteboard no longer needs
    /// this provider, so its strong reference can be dropped — after the fire in
    /// progress returns, if there is one.
    public func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        let deferred = lock.withLock { () -> Bool in
            guard fireDepth > 0 else { return false }
            finishedWhileFiring = true
            return true
        }
        guard !deferred else { return }
        onFinished(self)
    }
}
