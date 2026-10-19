import AppKit
import Foundation
import KernovaLogging
import KernovaSynchronization

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
/// A lock rather than main-actor isolation: AppKit marks both callbacks
/// `NS_SWIFT_NONISOLATED`, and their arrival on the main run loop is only
/// observed (`NestedEventLoopWait`).
public final class LazyClipboardDataProvider: NSObject, NSPasteboardItemDataProvider, Sendable {
    private struct State: Sendable {
        /// Fires on the stack right now — a fire can nest another for a sibling
        /// flavor of the same item.
        var fireDepth = 0
        /// Whether the pasteboard finished with this provider inside a fire, so
        /// the outermost fire's return owes `onFinished`.
        var finishedWhileFiring = false
    }

    private let provide: @Sendable (NSPasteboard.PasteboardType) -> Data?
    private let onFinished: @Sendable (LazyClipboardDataProvider) -> Void
    private let state = Locked(State())

    // Same category as `LazyClipboardProviderRegistry`, so a fire and the
    // release of the provider that served it read as one sequence.
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardProvider")

    /// - Parameters:
    ///   - provide: produces the bytes for a requested type, or `nil` to leave
    ///     it empty. Invoked synchronously on the owner's main thread/run loop.
    ///   - onFinished: called when the pasteboard no longer needs this provider,
    ///     so the owner can drop its strong reference.
    public init(
        provide: @escaping @Sendable (NSPasteboard.PasteboardType) -> Data?,
        onFinished: @escaping @Sendable (LazyClipboardDataProvider) -> Void
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
        state.withLock { $0.fireDepth += 1 }
        let data = provide(type)
        Self.logger.log(
            .debug,
            "Provided \(data?.count ?? 0, privacy: .public) bytes for promised type '\(type.rawValue, privacy: .public)'"
        )
        if let data { item.setData(data, forType: type) }
        let owesFinish = state.withLock { state -> Bool in
            state.fireDepth -= 1
            guard state.fireDepth == 0, state.finishedWhileFiring else { return false }
            state.finishedWhileFiring = false
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
        let deferred = state.withLock { state -> Bool in
            guard state.fireDepth > 0 else { return false }
            state.finishedWhileFiring = true
            return true
        }
        guard !deferred else { return }
        onFinished(self)
    }
}
