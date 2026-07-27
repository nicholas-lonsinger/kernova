import AppKit
import Foundation

/// Serves a clipboard offer's representations to a pasteboard lazily.
///
/// One provider is written per pasteboard item via
/// `NSPasteboardItem.setDataProvider(_:forTypes:)`. When the OS asks for a
/// promised type, the pasteboard server invokes
/// `pasteboard(_:item:provideDataForType:)` on the owner's main thread/run loop,
/// which delegates to `provide` (`nil` leaves the type empty). The owner must
/// hold each provider until `pasteboardFinishedWithDataProvider(_:)` fires.
public final class LazyClipboardDataProvider: NSObject, NSPasteboardItemDataProvider {
    private let provide: (NSPasteboard.PasteboardType) -> Data?
    private let onFinished: (LazyClipboardDataProvider) -> Void

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
        guard let data = provide(type) else { return }
        item.setData(data, forType: type)
    }

    /// Notifies the owner (via `onFinished`) that the pasteboard no longer needs
    /// this provider, so its strong reference can be dropped.
    public func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        onFinished(self)
    }
}
