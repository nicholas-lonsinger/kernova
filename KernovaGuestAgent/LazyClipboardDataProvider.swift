import AppKit
import Foundation

/// Serves a host clipboard offer's representations to the guest OS lazily.
///
/// One provider is written to the guest pasteboard per inbound offer via
/// `NSPasteboardItem.setDataProvider(_:forTypes:)`. When the OS (a paste, a drag
/// read, a Quick Look) asks for one of the promised types, the pasteboard server
/// invokes `pasteboard(_:item:provideDataForType:)` on the agent's main thread —
/// which is why the agent runs a `CFRunLoop` rather than `dispatchMain()`. The
/// callback delegates to `provide`, which streams the requested representation on
/// demand (blocking the main thread until the bytes, or a materialized file URL,
/// land — woken off-main by the stream receiver). `provide` returns `nil` to
/// leave the type empty (timeout, abort, disk full, or a superseded offer).
///
/// The agent keeps a strong reference to each provider until
/// `pasteboardFinishedWithDataProvider(_:)` fires — Apple requires the provider
/// stay alive while its item's data is still promised.
final class LazyClipboardDataProvider: NSObject, NSPasteboardItemDataProvider {
    private let provide: (NSPasteboard.PasteboardType) -> Data?
    private let onFinished: (LazyClipboardDataProvider) -> Void

    /// - Parameters:
    ///   - provide: streams the bytes for a requested type, or `nil` to leave it
    ///     empty. Invoked synchronously on the agent's main thread.
    ///   - onFinished: called when the pasteboard no longer needs this provider,
    ///     so the agent can drop its strong reference.
    init(
        provide: @escaping (NSPasteboard.PasteboardType) -> Data?,
        onFinished: @escaping (LazyClipboardDataProvider) -> Void
    ) {
        self.provide = provide
        self.onFinished = onFinished
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard let data = provide(type) else { return }
        item.setData(data, forType: type)
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        onFinished(self)
    }
}
