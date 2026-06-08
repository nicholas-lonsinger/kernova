import AppKit
import os

/// The toolbar-style tab container for the Settings window.
///
/// Today it holds a single **Advanced** tab; the toolbar style is used so
/// further panes can be added later as additional `NSTabViewItem`s.
@MainActor
final class SettingsTabViewController: NSTabViewController {
    private static let logger = Logger(subsystem: "com.kernova.app", category: "SettingsTabViewController")

    override func viewDidLoad() {
        super.viewDidLoad()
        tabStyle = .toolbar

        let advanced = NSTabViewItem(viewController: AdvancedSettingsViewController())
        advanced.label = "Advanced"
        advanced.image = Self.symbol("gearshape.2")
        addTabViewItem(advanced)
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
