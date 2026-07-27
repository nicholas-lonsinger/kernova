import Foundation

/// App-wide user preferences backed by `UserDefaults`.
///
/// Distinct from per-VM `VMConfiguration`: this holds settings that apply to the
/// whole app and live in the standard defaults domain. A thin value type over an
/// injectable `UserDefaults`, so tests can use an ephemeral suite.
struct AppPreferences {
    /// Shared production instance over the standard defaults domain.
    @MainActor static let shared = AppPreferences(defaults: .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private enum Keys {
        static let alwaysShowAdvancedOptions = "alwaysShowAdvancedOptions"
        static let expandedSidebarSections = "KernovaSidebarExpandedSections"
        // RATIONALE: these two deliberately keep unnamespaced key strings — the
        // ones existing users' persisted selection and order are already stored
        // under. Not a namespacing inconsistency to "fix": changing them drops
        // that saved state. verified 2026-07-27
        static let lastSelectedVMID = "lastSelectedVMID"
        static let vmOrder = "vmOrder"
        static let fileProviderReminderDismissed = "fileProviderReminderDismissed"
        // Deliberately inverted relative to `keepInMenuBarOnQuit` — see that
        // property's RATIONALE.
        static let quitTerminatesApp = "quitTerminatesApp"
        static let menuBarQuitReminderDismissed = "menuBarQuitReminderDismissed"
        static let mainToolbarNewVMCollapseIndex = "KernovaMainToolbarNewVMCollapseIndex"
    }

    /// When `true`, advanced menu actions (e.g. *Start in Recovery Mode*) are
    /// always visible.
    ///
    /// When `false` (the default), they are revealed only while holding the
    /// Option (⌥) key, as Option-alternate menu items.
    var alwaysShowAdvancedOptions: Bool {
        get { defaults.bool(forKey: Keys.alwaysShowAdvancedOptions) }
        nonmutating set { defaults.set(newValue, forKey: Keys.alwaysShowAdvancedOptions) }
    }

    /// Identifiers of the sidebar sections the user has expanded, or `nil` when
    /// no preference has been saved yet.
    ///
    /// When `nil`, the sidebar defaults each section to expanded.
    var expandedSidebarSections: [String]? {
        get { defaults.array(forKey: Keys.expandedSidebarSections) as? [String] }
        nonmutating set { defaults.set(newValue, forKey: Keys.expandedSidebarSections) }
    }

    /// The most recently selected VM, or `nil` when none has been selected yet
    /// (or the value fails to parse as a UUID).
    var lastSelectedVMID: UUID? {
        get { defaults.string(forKey: Keys.lastSelectedVMID).flatMap(UUID.init(uuidString:)) }
        nonmutating set { defaults.set(newValue?.uuidString, forKey: Keys.lastSelectedVMID) }
    }

    /// The user's custom VM ordering, or `nil` when no order has been saved yet.
    ///
    /// Entries that no longer parse as a UUID are dropped on read.
    var vmOrder: [UUID]? {
        get { defaults.stringArray(forKey: Keys.vmOrder)?.compactMap { UUID(uuidString: $0) } }
        nonmutating set { defaults.set(newValue?.map(\.uuidString), forKey: Keys.vmOrder) }
    }

    /// Whether the user dismissed the current "enable File Provider"
    /// status-item reminder.
    ///
    /// Reset back to `false` once availability reaches `.ready`, so a later,
    /// genuinely new disablement nags again rather than staying silenced forever.
    var fileProviderReminderDismissed: Bool {
        get { defaults.bool(forKey: Keys.fileProviderReminderDismissed) }
        nonmutating set { defaults.set(newValue, forKey: Keys.fileProviderReminderDismissed) }
    }

    /// Whether a GUI-origin quit (⌘Q, the app menu's soft-quit item, the Dock's
    /// Quit) keeps Kernova resident in the menu bar with its VMs running instead
    /// of terminating it, defaulting to `true`.
    ///
    /// RATIONALE: the value is stored *inverted* under `quitTerminatesApp` so the
    /// file's plain `bool(forKey:)` convention — an unset key reads `false` —
    /// produces this preference's `true` default without registering defaults.
    /// The key names what it literally holds. verified 2026-07-27
    var keepInMenuBarOnQuit: Bool {
        get { !defaults.bool(forKey: Keys.quitTerminatesApp) }
        nonmutating set { defaults.set(!newValue, forKey: Keys.quitTerminatesApp) }
    }

    /// Whether the user dismissed the "still running in the menu bar" reminder
    /// popover shown on a soft quit.
    ///
    /// Never auto-reset, unlike `fileProviderReminderDismissed`: a soft quit is
    /// always user-initiated, so there is no "genuinely new" condition to re-arm
    /// the nag against.
    var menuBarQuitReminderDismissed: Bool {
        get { defaults.bool(forKey: Keys.menuBarQuitReminderDismissed) }
        nonmutating set { defaults.set(newValue, forKey: Keys.menuBarQuitReminderDismissed) }
    }

    /// The main toolbar index New VM was removed from while the sidebar is
    /// collapsed, or `nil` when it sits in the toolbar.
    ///
    /// Mirroring the removal here is what lets the next launch tell it apart from
    /// a deliberate customization removal, and put the item back in the slot it
    /// came from.
    var mainToolbarNewVMCollapseIndex: Int? {
        get { defaults.object(forKey: Keys.mainToolbarNewVMCollapseIndex) as? Int }
        nonmutating set { defaults.set(newValue, forKey: Keys.mainToolbarNewVMCollapseIndex) }
    }

    /// Re-arms every host-side reminder by clearing its dismissed flag, so each
    /// nag shows again the next time its condition is met.
    ///
    /// Covers only the reminders whose dismissed state lives in *this* defaults
    /// domain. The guest agent's own File Provider reminder is backed by a
    /// separate domain in a separate process and is left untouched, as are the
    /// per-VM agent-install nudges in each VM's bundle configuration.
    func resetHostReminders() {
        menuBarQuitReminderDismissed = false
        fileProviderReminderDismissed = false
    }
}
