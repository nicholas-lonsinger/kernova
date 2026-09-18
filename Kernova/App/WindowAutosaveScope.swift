import AppKit

/// Whether a window saves its frame, split position, and toolbar layout, and
/// under what name — AppKit keeps them in `UserDefaults.standard` whatever
/// store the app's preferences wrap.
struct WindowAutosaveScope: Sendable {
    /// Whether AppKit saves and restores what these names cover.
    let savesState: Bool

    /// Prefixed to the toolbar identifiers, and empty for the app. A toolbar
    /// needs an identifier whether or not it saves, and the implicit
    /// synchronization ``displayToolbar`` relies on would otherwise reach
    /// between windows built on different ``unsaved()`` scopes.
    private let toolbarPrefix: String

    /// The app's own windows.
    static let app = WindowAutosaveScope(savesState: true, toolbarPrefix: "")

    /// Windows that save nothing, so nothing of theirs is left behind.
    static func unsaved() -> WindowAutosaveScope {
        WindowAutosaveScope(savesState: false, toolbarPrefix: "unsaved-\(UUID().uuidString)-")
    }

    var mainWindowFrame: NSWindow.FrameAutosaveName { frame("KernovaMainWindow") }
    var mainToolbar: NSToolbar.Identifier { toolbarPrefix + "KernovaMainToolbar" }
    var mainSplit: NSSplitView.AutosaveName? { savesState ? "KernovaMainSplit" : nil }
    var settingsFrame: NSWindow.FrameAutosaveName { frame("KernovaSettings") }

    // RATIONALE (2026-09-18): one toolbar identifier shared by every VM's
    // display window, unlike the per-VM frame name — "Toolbars with the same
    // identifier are implicitly synchronized so that they maintain the same
    // state" (NSToolbar.h, `initWithIdentifier:`), so a customized layout applies
    // to all display windows and persists as a single configuration.
    var displayToolbar: NSToolbar.Identifier { toolbarPrefix + "KernovaVMDisplayToolbar" }

    func displayFrame(for vmID: UUID) -> NSWindow.FrameAutosaveName {
        frame("VMDisplay-\(vmID)")
    }

    func clipboardFrame(for vmID: UUID) -> NSWindow.FrameAutosaveName {
        frame("Clipboard-\(vmID.uuidString)")
    }

    /// An empty frame autosave name is AppKit's spelling for "don't save this
    /// window's frame".
    private func frame(_ name: NSWindow.FrameAutosaveName) -> NSWindow.FrameAutosaveName {
        savesState ? name : ""
    }
}
