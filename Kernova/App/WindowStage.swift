import AppKit

/// Where the app's window controllers make their windows: what AppKit saves
/// for them — frame, split position and toolbar layout, in
/// `UserDefaults.standard` whatever store the app's preferences wrap — and the
/// window objects themselves.
///
/// Every window controller builds its window through its stage, so a stage that
/// makes its windows somewhere else holds every window the app makes there.
struct WindowStage: Sendable {
    /// Whether AppKit saves and restores what these names cover.
    let savesState: Bool

    let mainToolbar: NSToolbar.Identifier

    /// Shared by every VM's display window, unlike the per-VM frame name.
    /// "Toolbars with the same identifier are implicitly synchronized so that
    /// they maintain the same state" (NSToolbar.h, `initWithIdentifier:`), so a
    /// customized layout applies to all display windows as one configuration.
    let displayToolbar: NSToolbar.Identifier

    /// Makes a buffered window with `contentRect` and `styleMask`, its window
    /// device created at once.
    let makeWindow: @MainActor @Sendable (_ contentRect: NSRect, _ styleMask: NSWindow.StyleMask) -> NSWindow

    /// Makes `NSWindow(contentViewController:)`'s window for `contentViewController`.
    let makeContentWindow: @MainActor @Sendable (_ contentViewController: NSViewController) -> NSWindow

    /// The app's own windows.
    static let app = WindowStage(
        savesState: true, mainToolbar: "KernovaMainToolbar", displayToolbar: "KernovaVMDisplayToolbar",
        makeWindow: { contentRect, styleMask in
            NSWindow(contentRect: contentRect, styleMask: styleMask, backing: .buffered, defer: false)
        },
        makeContentWindow: { NSWindow(contentViewController: $0) })

    var mainWindowFrame: NSWindow.FrameAutosaveName { frame("KernovaMainWindow") }
    var mainSplit: NSSplitView.AutosaveName? { savesState ? "KernovaMainSplit" : nil }
    var settingsFrame: NSWindow.FrameAutosaveName { frame("KernovaSettings") }
    var configCheckFrame: NSWindow.FrameAutosaveName { frame("KernovaConfigCheck") }

    func displayFrame(for vmID: UUID) -> NSWindow.FrameAutosaveName { frame("VMDisplay-\(vmID)") }

    func clipboardFrame(for vmID: UUID) -> NSWindow.FrameAutosaveName {
        frame("Clipboard-\(vmID.uuidString)")
    }

    /// AppKit reads an empty name as "don't save this window's frame".
    private func frame(_ name: NSWindow.FrameAutosaveName) -> NSWindow.FrameAutosaveName {
        savesState ? name : ""
    }

    /// Makes a window hosting `contentViewController` whose content size is
    /// exactly `contentSize`.
    ///
    /// Assigning `contentViewController` resizes the window to the content view's
    /// Auto Layout fitting size, which for a flexible content view is far smaller
    /// than the intended initial size — and `minSize`, set afterwards, then clamps
    /// the window up to *that*. Re-establishing the size after the assignment is
    /// the only ordering that sticks.
    @MainActor
    func makeWindow(
        stableContentSize contentSize: NSSize,
        styleMask: NSWindow.StyleMask,
        contentViewController: NSViewController
    ) -> NSWindow {
        let window = makeWindow(NSRect(origin: .zero, size: contentSize), styleMask)
        window.contentViewController = contentViewController
        window.setContentSize(contentSize)
        return window
    }
}
