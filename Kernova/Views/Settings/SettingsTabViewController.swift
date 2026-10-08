import AppKit
import KernovaLogging

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

/// A Settings pane's root view: `content`, pinned to every edge.
///
/// The pane is measured through `content`, never the root: AppKit holds a
/// view controller's view to its `preferredContentSize` with a priority-501
/// `NSViewController.preferredContentSize.height` constraint, which outranks
/// the fitting compression, so the root's own `fittingSize` never drops below
/// the size last published.
@MainActor
final class SettingsPaneRootView: NSView {
    let content: NSView

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        // The size flows from the content. With autoresizing-mask constraints,
        // NSTabViewController frames the pane to the tab view's bounds, which
        // collide with the content's explicit width (the logged "Conflicting
        // constraints" warning) and stretch the content to the tab view's height.
        translatesAutoresizingMaskIntoConstraints = false
        addFullSizeSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsPaneRootView does not support NSCoder")
    }
}

extension NSViewController {
    /// Measures this Settings pane at ``SettingsPaneMetrics/width`` and
    /// publishes the result as `preferredContentSize`, which
    /// `SettingsTabViewController` resizes the window to whenever it changes.
    ///
    /// The pane's view is a ``SettingsPaneRootView``. A pane calls this on
    /// appearance and after anything that changes what it shows, such as a
    /// note appearing. A wrapping caption's height stays single-line until a
    /// layout pass resolves its wrap width, so a pane not yet in a window is
    /// laid out at the pane width, `layoutHeight` tall, before it is measured.
    func publishSettingsPaneSize(layoutHeight: CGFloat = SettingsPaneMetrics.width) {
        guard let root = view as? SettingsPaneRootView else {
            assertionFailure("A Settings pane's view is a SettingsPaneRootView")
            return
        }
        if root.window == nil {
            root.setFrameSize(NSSize(width: SettingsPaneMetrics.width, height: layoutHeight))
        }
        root.layoutSubtreeIfNeeded()
        let size = root.content.fittingSize
        guard size != preferredContentSize else { return }
        preferredContentSize = size
    }
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

    /// The tallest a pane can be while its window still fits the visible area
    /// below the window's top edge — the window grows downward from a fixed
    /// top — or the main screen's whole visible height before the window is
    /// on a screen; `nil` with no screen at all.
    ///
    /// A pane taller than this scrolls; below it, the window follows the pane.
    static func maxHeight(in window: NSWindow?) -> CGFloat? {
        let chrome = window.map { $0.frame.height - $0.contentRect(forFrameRect: $0.frame).height } ?? 0
        if let window, let screen = window.screen {
            return maxHeight(windowTop: window.frame.maxY, visibleFrame: screen.visibleFrame, chrome: chrome)
        }
        guard let screen = NSScreen.main else { return nil }
        return maxHeight(windowTop: nil, visibleFrame: screen.visibleFrame, chrome: chrome)
    }

    /// The pane height that keeps a window whose top edge sits at `windowTop`
    /// — or the top of `visibleFrame` when `nil` — inside `visibleFrame`.
    static func maxHeight(windowTop: CGFloat?, visibleFrame: NSRect, chrome: CGFloat) -> CGFloat {
        let top = min(windowTop ?? visibleFrame.maxY, visibleFrame.maxY)
        return top - visibleFrame.minY - chrome
    }
}

/// One tab of the Settings window, in toolbar order.
enum SettingsPane: String, CaseIterable {
    /// App-lifecycle toggles.
    case general
    /// Turning suppressed reminders back on.
    case reminders
    /// The maximum paste size.
    case clipboard
    /// The library's named networks.
    case networks
    /// The library's tags.
    case tags
    case advanced

    /// Whether a build with `entitlements` has this pane: the Networks pane
    /// only where the build can create a named network.
    @MainActor func isOffered(by entitlements: EntitlementService) -> Bool {
        self != .networks || !NetworksSettingsViewController.creatableKinds(entitlements).isEmpty
    }

    fileprivate var label: String {
        switch self {
        case .general: "General"
        case .reminders: "Reminders"
        case .clipboard: "Clipboard"
        case .networks: "Networks"
        case .tags: "Tags"
        case .advanced: "Advanced"
        }
    }

    fileprivate var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .reminders: "bell"
        case .clipboard: "clipboard"
        case .networks: "network"
        case .tags: "tag"
        case .advanced: "gearshape.2"
        }
    }
}

/// Where a request to show the Settings window lands.
enum SettingsDestination: Equatable {
    case pane(SettingsPane)
    /// The Networks pane, with the row of the network `id` identifies selected
    /// when the library lists it.
    case network(UUID)

    var pane: SettingsPane {
        switch self {
        case .pane(let pane): pane
        case .network: .networks
        }
    }
}

/// The toolbar-style tab container for the Settings window: one tab per
/// ``SettingsPane`` the build offers.
///
/// The Reminders, Clipboard, Networks and Tags panes need the app's
/// `VMLibraryViewModel`, so this controller is constructed with it.
@MainActor
final class SettingsTabViewController: NSTabViewController {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "SettingsTabViewController")

    private let viewModel: VMLibraryViewModel

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsTabViewController does not support NSCoder")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar
        for pane in SettingsPane.allCases where pane.isOffered(by: viewModel.entitlements) {
            let item = NSTabViewItem(viewController: makeController(pane))
            item.identifier = pane.rawValue
            item.label = pane.label
            item.image = Self.symbol(pane.symbolName)
            addTabViewItem(item)
        }
    }

    private func makeController(_ pane: SettingsPane) -> NSViewController {
        switch pane {
        case .general: GeneralSettingsViewController(viewModel: viewModel)
        case .reminders: RemindersSettingsViewController(viewModel: viewModel)
        case .clipboard: ClipboardSettingsViewController(viewModel: viewModel)
        case .networks: NetworksSettingsViewController(viewModel: viewModel)
        case .tags: TagsSettingsViewController(viewModel: viewModel)
        case .advanced: AdvancedSettingsViewController(preferences: viewModel.preferences)
        }
    }

    /// The pane on screen, `nil` before the view loads.
    var selectedPane: SettingsPane? {
        (tabView.selectedTabViewItem?.identifier as? String).flatMap(SettingsPane.init(rawValue:))
    }

    /// Selects the pane `destination` names and, for a network, its row.
    ///
    /// A pane this build does not offer leaves the selection where it is.
    func show(_ destination: SettingsDestination) {
        loadViewIfNeeded()
        let index = tabView.indexOfTabViewItem(withIdentifier: destination.pane.rawValue)
        guard index != NSNotFound else { return }
        selectedTabViewItemIndex = index
        if case .network(let id) = destination {
            (tabViewItems[index].viewController as? NetworksSettingsViewController)?.reveal(id)
        }
    }

    /// Resizes the window to fit the newly selected pane, System Settings-style.
    ///
    /// `NSTabViewController` does not do this itself: it sizes the window from
    /// the initial pane at `NSWindow(contentViewController:)` time and then
    /// keeps whatever height the window has, letting a shorter pane stretch and
    /// a taller pane clip. Each pane publishes its content height via
    /// `preferredContentSize` in `viewWillAppear()` (which runs before this
    /// delegate call), so the target size is already fresh here.
    /// A later change is picked up by ``preferredContentSizeDidChange(for:)``.
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
    }

    /// Resizes the window when the selected pane's content changes size while
    /// it is on screen — a note appearing or going away.
    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard viewController === tabView.selectedTabViewItem?.viewController else { return }
        resizeWindow(toFit: viewController, animate: true)
    }

    /// Cues the pane the window opened on, once that window is on screen.
    ///
    /// Reopening the window re-shows the pane the last session left selected
    /// without a tab switch, so this is the only hook that cues it. It has to be
    /// `viewDidAppear`, not `viewWillAppear`: the scroller flash animates a
    /// fade-in, and one started before the window is ordered on screen is
    /// already spent by the time anyone can look — leaving the pane's first
    /// visit showing a scroller that only fades out, unlike every later visit.
    override func viewDidAppear() {
        super.viewDidAppear()
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
            #log(logger, .fault, "Missing SF Symbol '\(name, privacy: .public)' for Settings tab")
            assertionFailure("Missing SF Symbol: \(name)")
            return nil
        }
        return image
    }
}
