import AppKit

/// Manages a single window-modal sheet lifecycle for one parent window.
///
/// One instance corresponds to one sheet slot: the caller supplies an
/// `NSViewController` for the content, and the presenter wraps it in an
/// `NSWindow`, attaches it to the parent, and fires ``onClose`` after dismissal.
///
/// Use for **custom-content** sheets; for simple title/message/button alerts,
/// prefer ``presentSheetAlert(_:in:completion:)``.
@MainActor
final class SheetPresenter: NSObject {
    private var sheetWindow: NSWindow?

    /// Fired after the sheet dismisses, by any mechanism.
    var onClose: (() -> Void)?

    /// `true` when a sheet is currently attached and visible.
    var isShown: Bool {
        sheetWindow != nil
    }

    /// Presents `content` as a window-modal sheet on `parent`.
    ///
    /// No-op when a sheet is already showing — the caller must close the previous
    /// sheet before presenting another. The sheet window's size is taken from the
    /// content controller's `fittingSize`, so the controller must constrain its
    /// layout to its preferred size in `loadView()`.
    func show(content: NSViewController, in parent: NSWindow) {
        guard sheetWindow == nil else { return }

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
            // Only act if THIS sheet is still the current one: an orphaned
            // completion firing late must not nil a newer sheet's window or fire
            // its `onClose`.
            guard let self, self.sheetWindow === sheet else { return }
            self.sheetWindow = nil
            self.onClose?()
        }
        sheetWindow = sheet
    }

    /// Dismisses the sheet if currently shown; idempotent.
    ///
    /// The ``show(content:in:)`` completion fires, which in turn invokes
    /// ``onClose``.
    func close() {
        guard let sheetWindow else { return }
        guard let parent = sheetWindow.sheetParent else {
            // The parent was torn down without dismissing the sheet through
            // `beginSheet`'s completion, so that completion will never fire —
            // reconcile directly so `isShown` doesn't stick `true` and wedge any
            // presenter that gates on it.
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
    /// dismissal completion, so ``onClose`` is not called and ``isShown`` can't
    /// linger `true` past teardown even if the parent window is destroyed before
    /// its dismissal completion is delivered.
    func reset() {
        guard let sheetWindow else { return }
        sheetWindow.sheetParent?.endSheet(sheetWindow)
        self.sheetWindow = nil
        // The handler is now orphaned: reset() does not fire it, and the next
        // show() installs a fresh one.
        onClose = nil
    }
}
