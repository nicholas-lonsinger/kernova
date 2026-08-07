import AppKit
import os

/// A Settings pane that can outgrow the window and shows a scroller flash to
/// say there is more below.
///
/// The flash latches after firing once, so a pane that lives as long as the
/// Settings window would cue only its first visit. The tab container re-arms
/// every pane it selects, which is what makes the cue greet each arrival.
@MainActor
protocol SettingsPaneScrollCueing: AnyObject {
    /// Re-arms the pane's "more below" flash for a fresh appearance.
    func rearmScrollMoreCue()
}

/// Layout tokens shared by every pane of the Settings window.
///
/// Surface-specific, so they live here (next to the tab container that owns the
/// surface) rather than in the context-neutral `GroupedFormStyle`.
enum SettingsPaneMetrics {
    /// Fixed content width of every Settings pane.
    ///
    /// Each pane's root view pins to this explicitly instead of inheriting the
    /// tab view's bounds — see `SettingsTabViewController`'s sizing contract.
    static let width: CGFloat = 520
}

/// The toolbar-style tab container for the Settings window.
///
/// Holds a **General** tab (Open at Login), a **Reminders** tab (turning
/// suppressed reminders back on), a **Clipboard** tab (the maximum paste size),
/// and an **Advanced** tab; the toolbar style is used so further panes can be
/// added later as additional `NSTabViewItem`s.
///
/// The Reminders and Clipboard panes need the app's `VMLibraryViewModel` — to
/// list and re-arm per-VM install nudges, and to push a changed paste ceiling to
/// running guests — so this controller is constructed with it.
@MainActor
final class SettingsTabViewController: NSTabViewController {
    private static let logger = Logger(subsystem: "app.kernova", category: "SettingsTabViewController")

    private let viewModel: VMLibraryViewModel
    private let preferences: AppPreferences

    init(viewModel: VMLibraryViewModel, preferences: AppPreferences = .shared) {
        self.viewModel = viewModel
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsTabViewController does not support NSCoder")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar

        let general = NSTabViewItem(
            viewController: GeneralSettingsViewController(preferences: preferences))
        general.label = "General"
        general.image = Self.symbol("gearshape")
        addTabViewItem(general)

        let reminders = NSTabViewItem(
            viewController: RemindersSettingsViewController(
                preferences: preferences, viewModel: viewModel))
        reminders.label = "Reminders"
        reminders.image = Self.symbol("bell")
        addTabViewItem(reminders)

        let clipboard = NSTabViewItem(
            viewController: ClipboardSettingsViewController(
                preferences: preferences, viewModel: viewModel))
        clipboard.label = "Clipboard"
        clipboard.image = Self.symbol("clipboard")
        addTabViewItem(clipboard)

        let advanced = NSTabViewItem(
            viewController: AdvancedSettingsViewController(preferences: preferences))
        advanced.label = "Advanced"
        advanced.image = Self.symbol("gearshape.2")
        addTabViewItem(advanced)
    }

    /// Resizes the window to fit the newly selected pane, System Settings-style.
    ///
    /// `NSTabViewController` does not do this itself: it sizes the window from
    /// the initial pane at `NSWindow(contentViewController:)` time and then
    /// keeps whatever height the window has, letting a shorter pane stretch and
    /// a taller pane clip. Each pane publishes its content height via
    /// `preferredContentSize` in `viewWillAppear()` (which runs before this
    /// delegate call), so the target size is already fresh here.
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        resizeWindow(toFit: tabViewItem?.viewController, animate: true)
        // After the resize, never before: the cue is a statement about the pane
        // overflowing the window it just got, and re-arming against the outgoing
        // tab's height would answer for the wrong geometry.
        rearmScrollMoreCue(on: tabViewItem?.viewController)
    }

    /// Sizes the window to the pane that is about to become visible.
    ///
    /// `tabView(_:didSelect:)` only fires on a tab *switch*, and not for the
    /// initial selection (during `viewDidLoad` there is no window yet). Without
    /// this hook the first pane shown is sized by whatever frame the window
    /// already has — including the stale height `setFrameAutosaveName` restores
    /// from a previous session's taller tab — and the pane's four-edge pin
    /// stretches its cards over the excess. No animation: the window has not
    /// been shown yet, so there is nothing to animate from.
    override func viewWillAppear() {
        super.viewWillAppear()
        resizeWindow(toFit: tabView.selectedTabViewItem?.viewController, animate: false)
        // Reopening the window re-shows the pane the last session left selected
        // without a tab switch, so this is the only hook that cues it.
        rearmScrollMoreCue(on: tabView.selectedTabViewItem?.viewController)
    }

    /// Re-arms `pane`'s "more below" flash, for panes that publish one.
    private func rearmScrollMoreCue(on pane: NSViewController?) {
        (pane as? any SettingsPaneScrollCueing)?.rearmScrollMoreCue()
    }

    /// Resizes the window so its content area matches the content size of `pane`.
    ///
    /// The top-left corner is kept anchored, matching the system apps' behavior.
    ///
    /// No-ops until the window and a measurable pane exist.
    private func resizeWindow(toFit pane: NSViewController?, animate: Bool) {
        guard let window = view.window, let pane else { return }
        var contentSize = pane.preferredContentSize
        if contentSize == .zero {
            contentSize = pane.view.fittingSize
        }
        guard contentSize != .zero else { return }
        let contentRect = NSRect(origin: .zero, size: contentSize)
        let targetSize = window.frameRect(forContentRect: contentRect).size
        var frame = window.frame
        frame.origin.y += frame.height - targetSize.height
        frame.size = targetSize
        window.setFrame(frame, display: true, animate: animate)
    }

    /// Loads an SF Symbol for a tab item, logging and asserting on a typo while
    /// degrading to no image in Release (per the project's defensive-unwrap rule).
    private static func symbol(_ name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            logger.fault("Missing SF Symbol '\(name, privacy: .public)' for Settings tab")
            assertionFailure("Missing SF Symbol: \(name)")
            return nil
        }
        return image
    }
}
