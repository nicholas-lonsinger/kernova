import AppKit
import os

/// The toolbar-style tab container for the Settings window.
///
/// Holds a **General** tab (Open at Login), an **Advanced** tab, and a
/// **Reminders** tab (turning suppressed reminders back on); the toolbar style
/// is used so further panes can be added later as additional `NSTabViewItem`s.
///
/// The Reminders pane needs the app's `VMLibraryViewModel` (to list and re-arm
/// per-VM install nudges), so this controller is constructed with it.
@MainActor
final class SettingsTabViewController: NSTabViewController {
    private static let logger = Logger(subsystem: "app.kernova", category: "SettingsTabViewController")

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

        let general = NSTabViewItem(viewController: GeneralSettingsViewController())
        general.label = "General"
        general.image = Self.symbol("gearshape")
        addTabViewItem(general)

        let advanced = NSTabViewItem(viewController: AdvancedSettingsViewController())
        advanced.label = "Advanced"
        advanced.image = Self.symbol("gearshape.2")
        addTabViewItem(advanced)

        let reminders = NSTabViewItem(
            viewController: RemindersSettingsViewController(viewModel: viewModel))
        reminders.label = "Reminders"
        reminders.image = Self.symbol("bell")
        addTabViewItem(reminders)
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
