import AppKit
import SwiftUI

/// SwiftUI bridge that surfaces the host `NSWindow` to a SwiftUI parent.
///
/// Place via `.background(WindowAccessor { window in ... })`. The closure
/// fires asynchronously after the representable is inserted into the view
/// hierarchy (so `view.window` is non-nil) and again on each update — the
/// hosting window can change if the SwiftUI view moves between scenes.
///
/// **Nil-suppression after capture.** Once the closure has reported a
/// non-nil window, transient `nil` resolutions (which happen when the
/// hosted view briefly detaches during a parent re-render) are filtered
/// out. Without this, a captured `@State window: NSWindow?` in the caller
/// can flip back to `nil` mid-flight, causing the next `isPresented` flip
/// to silently drop the sheet via the `guard let window else { ... }`
/// branch in the SwiftUI bridge modifiers.
///
/// Used by the sheet- and alert-presenter SwiftUI bridges to find the
/// `NSWindow` to attach the sheet to.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak view] in
            coordinator.report(view?.window, to: onWindow)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { [weak nsView] in
            coordinator.report(nsView?.window, to: onWindow)
        }
    }

    /// Per-representable state holding the last-reported window.
    ///
    /// Lets us suppress redundant reports (the resolved window is the
    /// same) and transient nil reports after a non-nil capture.
    @MainActor
    final class Coordinator {
        private var lastReported: NSWindow?

        /// Forwards `newWindow` to `onWindow` unless one of two filters fires.
        ///
        /// Filters: (1) the new value matches the last-reported one
        /// (redundant), or (2) the new value is `nil` and the
        /// last-reported one was non-nil (transient detachment during a
        /// parent re-render).
        func report(_ newWindow: NSWindow?, to onWindow: (NSWindow?) -> Void) {
            if newWindow === lastReported { return }
            if newWindow == nil && lastReported != nil { return }
            lastReported = newWindow
            onWindow(newWindow)
        }
    }
}
