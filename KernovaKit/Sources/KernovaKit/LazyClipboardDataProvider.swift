import AppKit
import Foundation

/// Serves a clipboard offer's representations to a pasteboard lazily.
///
/// Used on both sides of the clipboard bridge: the guest agent registers one
/// per inbound host offer, and the host app registers one per "Copy to Mac"
/// item. One provider is written per pasteboard item via
/// `NSPasteboardItem.setDataProvider(_:forTypes:)`. When the OS (a paste, a drag
/// read, a Quick Look) asks for one of the promised types, the pasteboard server
/// invokes `pasteboard(_:item:provideDataForType:)` on the owner's main
/// thread/run loop. The callback delegates to `provide`, which produces the
/// requested representation on demand — the host serves its resident or
/// memory-mapped bytes, the guest streams them from the host (blocking the main
/// thread until the bytes, or a materialized file URL, land — woken off-main by
/// the stream receiver). `provide` returns `nil` to leave the type empty (a
/// timeout, abort, disk full, a superseded offer, or a type this item never
/// promised).
///
/// The owner keeps a strong reference to each provider until
/// `pasteboardFinishedWithDataProvider(_:)` fires — Apple requires the provider
/// stay alive while its item's data is still promised.
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
