import AppKit
import SwiftUI

/// SwiftUI bridge that surfaces the host `NSWindow` to a SwiftUI parent.
///
/// Place via `.background(WindowAccessor { window in ... })`. The closure
/// fires asynchronously after the representable is inserted into the view
/// hierarchy (so `view.window` is non-nil) and again on each update — the
/// hosting window can change if the SwiftUI view moves between scenes.
///
/// Used by the sheet- and alert-presenter SwiftUI bridges to find the
/// `NSWindow` to attach the sheet to.
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            onWindow(view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            onWindow(nsView?.window)
        }
    }
}
