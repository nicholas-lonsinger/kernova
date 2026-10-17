import AppKit
import Foundation
import Testing

// MARK: - View-tree search

/// The first `T` that `matches` in the subtree rooted at `view`, depth-first.
@MainActor
func firstSubview<T: NSView>(
    _ type: T.Type, in view: NSView, where matches: (T) -> Bool = { _ in true }
) -> T? {
    if let candidate = view as? T, matches(candidate) { return candidate }
    for subview in view.subviews {
        if let match = firstSubview(type, in: subview, where: matches) { return match }
    }
    return nil
}

/// Every `T` that `matches` in the subtree rooted at `view`, depth-first.
@MainActor
func allSubviews<T: NSView>(
    _ type: T.Type, in view: NSView, where matches: (T) -> Bool = { _ in true }
) -> [T] {
    var found: [T] = []
    if let candidate = view as? T, matches(candidate) { found.append(candidate) }
    for subview in view.subviews {
        found.append(contentsOf: allSubviews(type, in: subview, where: matches))
    }
    return found
}

/// The first push button titled `title` in the subtree rooted at `view`.
///
/// Skips pop-up buttons, whose `title` is whichever item is selected.
@MainActor
func findButton(titled title: String, in view: NSView) -> NSButton? {
    firstSubview(NSButton.self, in: view) { !($0 is NSPopUpButton) && $0.title == title }
}

/// The first label reading exactly `text` in the subtree rooted at `view`.
@MainActor
func findLabel(withText text: String, in view: NSView) -> NSTextField? {
    firstSubview(NSTextField.self, in: view) { $0.stringValue == text }
}

/// The first label whose text contains `text` in the subtree rooted at `view`.
@MainActor
func findLabel(containing text: String, in view: NSView) -> NSTextField? {
    firstSubview(NSTextField.self, in: view) { $0.stringValue.contains(text) }
}

/// The first editable text field in the subtree rooted at `view`.
@MainActor
func findEditableField(in view: NSView) -> NSTextField? {
    firstSubview(NSTextField.self, in: view) { $0.isEditable }
}

/// Every text field in the subtree rooted at `view`, in depth-first order.
@MainActor
func collectLabels(in view: NSView) -> [NSTextField] {
    allSubviews(NSTextField.self, in: view)
}

/// Whether `view` and every ancestor up to `root` is unhidden — what it takes
/// for `view` to actually be on screen within `root`.
@MainActor
func isVisible(_ view: NSView, within root: NSView) -> Bool {
    var node: NSView? = view
    while let current = node {
        if current.isHidden { return false }
        if current === root { return true }
        node = current.superview
    }
    return true
}

extension NSColor {
    /// This color resolved to sRGB as drawn under the named appearance.
    func resolvedSRGB(in appearance: NSAppearance.Name) throws -> NSColor {
        var resolved: NSColor?
        try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            resolved = usingColorSpace(.sRGB)
        }
        return try #require(resolved)
    }
}

extension NSView {
    /// The accessibility elements VoiceOver reaches inside this view, in order.
    @MainActor
    var unignoredAccessibilityElements: [NSAccessibilityProtocol] {
        NSAccessibility.unignoredChildren(from: accessibilityChildren() ?? [])
            .compactMap { $0 as? NSAccessibilityProtocol }
    }
}
