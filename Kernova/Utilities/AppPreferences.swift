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
        // that saved state.
        static let lastSelectedVMID = "lastSelectedVMID"
        static let vmOrder = "vmOrder"
        // Deliberately inverted relative to `keepInMenuBarOnQuit` — see that
        // property's RATIONALE.
        static let quitTerminatesApp = "quitTerminatesApp"
        static let menuBarQuitReminderDismissed = "menuBarQuitReminderDismissed"
        static let mainToolbarNewVMCollapseIndex = "KernovaMainToolbarNewVMCollapseIndex"
        // Also inverted — see `keepInMenuBarOnQuit`'s RATIONALE.
        static let allowDuplicateMachineIDBoot = "allowDuplicateMachineIDBoot"
        static let cloneKeepsMachineID = "cloneKeepsMachineID"
    }

    // MARK: - Inverted Storage

    /// Reads the inverse of the boolean stored under the given key, so an unset
    /// key yields a `true` default.
    private func invertedBool(forKey key: String) -> Bool {
        !defaults.bool(forKey: key)
    }

    /// Writes the inverse of `value` under the given key, the counterpart of
    /// ``invertedBool(forKey:)``.
    private func setInvertedBool(_ value: Bool, forKey key: String) {
        defaults.set(!value, forKey: key)
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

    /// Whether a GUI-origin quit (⌘Q, the app menu's soft-quit item, the Dock's
    /// Quit) keeps Kernova resident in the menu bar with its VMs running instead
    /// of terminating it, defaulting to `true`.
    ///
    /// RATIONALE: the value is stored *inverted* under `quitTerminatesApp` so the
    /// file's plain `bool(forKey:)` convention — an unset key reads `false` —
    /// produces this preference's `true` default without registering defaults.
    /// The key names what it literally holds. Every `true`-defaulting preference
    /// here works this way, through `invertedBool(forKey:)`.
    var keepInMenuBarOnQuit: Bool {
        get { invertedBool(forKey: Keys.quitTerminatesApp) }
        nonmutating set { setInvertedBool(newValue, forKey: Keys.quitTerminatesApp) }
    }

    /// Whether the user dismissed the "still running in the menu bar" reminder
    /// popover shown on a soft quit.
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

    /// Whether starting a VM is refused while another VM with the same machine
    /// identifier is live, defaulting to `true`.
    ///
    /// Two VMs sharing a machine identifier must never run at once — the
    /// framework documents the result as undefined behavior.
    var blockDuplicateMachineIDBoot: Bool {
        get { invertedBool(forKey: Keys.allowDuplicateMachineIDBoot) }
        nonmutating set { setInvertedBool(newValue, forKey: Keys.allowDuplicateMachineIDBoot) }
    }

    /// Whether Clone gives the copy a fresh machine identifier, defaulting to `true`.
    ///
    /// When `false`, clones keep the source VM's identifier. The Option-held
    /// Clone menu item performs the opposite of this setting.
    var cloneGeneratesNewMachineID: Bool {
        get { invertedBool(forKey: Keys.cloneKeepsMachineID) }
        nonmutating set { setInvertedBool(newValue, forKey: Keys.cloneKeepsMachineID) }
    }

    /// Title of the Option-alternate Clone menu item, which clones with the
    /// opposite machine-identity behavior to the one this preference selects.
    var cloneAlternateMenuTitle: String {
        cloneGeneratesNewMachineID ? "Clone (Keep Machine ID)" : "Clone (New Machine ID)"
    }

    /// Re-arms every host-side reminder by clearing its dismissed flag, so each
    /// nag shows again the next time its condition is met.
    ///
    /// Covers only the reminders whose dismissed state lives in *this* defaults
    /// domain — the per-VM agent-install nudges in each VM's bundle configuration
    /// are left untouched.
    func resetHostReminders() {
        menuBarQuitReminderDismissed = false
    }
}
