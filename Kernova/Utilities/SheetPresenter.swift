import AppKit

/// Manages a single window-modal sheet lifecycle for one parent window.
///
/// Parallel to ``PopoverPresenter``: one instance corresponds to one sheet
/// slot. The caller supplies an `NSViewController` for the content; the
/// presenter wraps it in an `NSWindow`, attaches that window as a sheet on
/// the parent window via `beginSheet(_:completionHandler:)`, and fires
/// ``onClose`` after dismissal.
///
/// Use for **custom-content** sheets — confirmation dialogs richer than a
/// stock `NSAlert` can express (attachment list + checkbox + conditional
/// warning, e.g. `DeleteVMSheetContentViewController`). For simple
/// title/message/button alerts, prefer ``presentSheetAlert(_:in:completion:)``.
@MainActor
final class SheetPresenter: NSObject {
    private var sheetWindow: NSWindow?

    /// Fired after the sheet dismisses, by any mechanism (programmatic
    /// ``close()``, the content controller ending the sheet itself, or a
    /// user gesture that triggers `endSheet`).
    var onClose: (() -> Void)?

    /// `true` when a sheet is currently attached and visible.
    var isShown: Bool {
        sheetWindow != nil
    }

    /// Presents `content` as a window-modal sheet on `parent`.
    ///
    /// No-op when a sheet is already showing — the caller is responsible
    /// for closing the previous sheet before presenting another. The
    /// sheet window's size is taken from the content controller's view
    /// (`fittingSize` at creation time) so the controller should constrain
    /// its layout to its preferred size in `loadView()`.
    func show(content: NSViewController, in parent: NSWindow) {
        guard sheetWindow == nil else { return }

        // Compute size from the content view's fitting size so the sheet
        // window opens at the right dimensions without callers having to
        // hardcode them. The content controller is expected to have its
        // layout fully constrained.
        content.loadViewIfNeeded()
        content.view.layoutSubtreeIfNeeded()
        let size = content.view.fittingSize

        let sheet = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        sheet.titlebarAppearsTransparent = true
        sheet.titleVisibility = .hidden
        sheet.contentViewController = content

        parent.beginSheet(sheet) { [weak self] _ in
            // Only act if THIS sheet is still the current one. If it was already
            // reconciled by `close()`'s parent-torn-down path, or replaced by a
            // newer sheet, an orphaned completion firing late must not nil the
            // newer sheet's window or fire its `onClose`.
            guard let self, self.sheetWindow === sheet else { return }
            self.sheetWindow = nil
            self.onClose?()
        }
        sheetWindow = sheet
    }

    /// Dismisses the sheet if currently shown.
    ///
    /// Idempotent. The completion handler attached to ``show(content:in:)``
    /// will fire (which in turn invokes ``onClose``).
    func close() {
        guard let sheetWindow else { return }
        guard let parent = sheetWindow.sheetParent else {
            // The parent was torn down without dismissing the sheet through
            // `beginSheet`'s completion, so that completion will never fire —
            // reconcile our state directly so `isShown` doesn't stick `true`
            // (which would wedge any presenter that gates on it). Mirror the
            // completion handler: drop the window reference, then fire `onClose`.
            self.sheetWindow = nil
            onClose?()
            return
        }
        parent.endSheet(sheetWindow)
    }

    /// Synchronously tears the sheet down for a teardown path that has already
    /// done its own state cleanup and just needs ``isShown`` to drop *now*.
    ///
    /// Unlike ``close()``, this does **not** wait for — or fire — the async
    /// dismissal completion (so ``onClose`` is not called): it drives `endSheet`
    /// for the visual dismissal when a parent is still attached, then drops the
    /// window reference immediately. The original `beginSheet` completion, if it
    /// later fires, is a no-op because its `sheetWindow === sheet` guard fails.
    /// This guarantees ``isShown`` can't linger `true` past teardown even if the
    /// parent window is destroyed before its dismissal completion is delivered.
    func reset() {
        guard let sheetWindow else { return }
        sheetWindow.sheetParent?.endSheet(sheetWindow)
        self.sheetWindow = nil
    }
}
