import Foundation

/// App-wide user preferences backed by `UserDefaults`.
///
/// Distinct from per-VM `VMConfiguration` (persisted in each bundle): this holds
/// settings that apply to the whole app and live in the standard defaults
/// domain. The store is a thin value type over an injectable `UserDefaults` so
/// tests can use an ephemeral suite; production reads `AppPreferences.shared`.
struct AppPreferences {
    /// Shared production instance over the standard defaults domain.
    ///
    /// Isolated to the main actor — its only readers/writers are menus and view
    /// controllers, which are all `@MainActor`. Tests construct their own
    /// instances over an ephemeral suite instead of touching this.
    @MainActor static let shared = AppPreferences(defaults: .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private enum Keys {
        static let alwaysShowAdvancedOptions = "alwaysShowAdvancedOptions"
        static let expandedSidebarSections = "KernovaSidebarExpandedSections"
        // RATIONALE: Unlike expandedSidebarSections, these two carry over the
        // exact key strings VMLibraryViewModel used before this property moved
        // here (#528), so existing users' persisted selection/order still load.
        // Not a namespacing inconsistency to "fix" — changing them drops saved state.
        static let lastSelectedVMID = "lastSelectedVMID"
        static let vmOrder = "vmOrder"
        static let fileProviderReminderDismissed = "fileProviderReminderDismissed"
        // Deliberately inverted relative to `keepInMenuBarOnQuit` — see that
        // property's RATIONALE.
        static let quitTerminatesApp = "quitTerminatesApp"
        static let menuBarQuitReminderDismissed = "menuBarQuitReminderDismissed"
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
    /// When `nil`, the sidebar defaults each section to expanded. Persisted by
    /// `SidebarViewController` as it expands and collapses group rows.
    var expandedSidebarSections: [String]? {
        get { defaults.array(forKey: Keys.expandedSidebarSections) as? [String] }
        nonmutating set { defaults.set(newValue, forKey: Keys.expandedSidebarSections) }
    }

    /// The most recently selected VM, or `nil` when none has been selected yet
    /// (or the value fails to parse as a UUID).
    ///
    /// Persisted by `VMLibraryViewModel` on every `selectedID` change and
    /// restored on the next launch, provided the VM still exists.
    var lastSelectedVMID: UUID? {
        get { defaults.string(forKey: Keys.lastSelectedVMID).flatMap(UUID.init(uuidString:)) }
        nonmutating set { defaults.set(newValue?.uuidString, forKey: Keys.lastSelectedVMID) }
    }

    /// The user's custom VM ordering, or `nil` when no order has been saved
    /// yet.
    ///
    /// Persisted by `VMLibraryViewModel` as the user drags to reorder VMs in
    /// the sidebar; entries that no longer correspond to a UUID are dropped on
    /// read.
    var vmOrder: [UUID]? {
        get { defaults.stringArray(forKey: Keys.vmOrder)?.compactMap { UUID(uuidString: $0) } }
        nonmutating set { defaults.set(newValue?.map(\.uuidString), forKey: Keys.vmOrder) }
    }

    /// Whether the user dismissed the current "enable File Provider"
    /// status-item reminder (#581).
    ///
    /// Set by "Stop Reminding Me" in `HostAgentStatusItemController`'s
    /// dropdown; reset back to `false` once availability reaches `.ready`, so
    /// a later, genuinely new disablement nags again rather than staying
    /// silenced forever.
    var fileProviderReminderDismissed: Bool {
        get { defaults.bool(forKey: Keys.fileProviderReminderDismissed) }
        nonmutating set { defaults.set(newValue, forKey: Keys.fileProviderReminderDismissed) }
    }

    /// Whether a GUI-origin quit (⌘Q, the app menu's soft-quit item, the Dock's
    /// Quit) keeps Kernova resident in the menu bar with its VMs running instead
    /// of terminating it, defaulting to `true` (#624).
    ///
    /// RATIONALE: the value is stored *inverted* under `quitTerminatesApp` so the
    /// file's plain `bool(forKey:)` convention — an unset key reads `false` —
    /// produces this preference's `true` default without registering defaults: an
    /// absent key means `quitTerminatesApp == false`, i.e.
    /// `keepInMenuBarOnQuit == true`. The getter negates the stored value and the
    /// setter stores the negation, so the key name always names what it literally
    /// holds ("quitting terminates the app").
    var keepInMenuBarOnQuit: Bool {
        get { !defaults.bool(forKey: Keys.quitTerminatesApp) }
        nonmutating set { defaults.set(!newValue, forKey: Keys.quitTerminatesApp) }
    }

    /// Whether the user dismissed the "still running in the menu bar" reminder
    /// popover shown on a soft quit, via its "Stop Reminding Me" button
    /// (#624).
    ///
    /// Once `true`, soft quits no longer show the reminder. Mirrors
    /// `fileProviderReminderDismissed`'s plain false-default pattern, but is never
    /// auto-reset: a soft quit is always user-initiated, so there is no
    /// "genuinely new" condition to re-arm the nag against.
    var menuBarQuitReminderDismissed: Bool {
        get { defaults.bool(forKey: Keys.menuBarQuitReminderDismissed) }
        nonmutating set { defaults.set(newValue, forKey: Keys.menuBarQuitReminderDismissed) }
    }

    /// Re-arms every host-side reminder by clearing its dismissed flag, so each
    /// nag shows again the next time its condition is met.
    ///
    /// Covers only the reminders whose dismissed state lives in *this* defaults
    /// domain — the menu-bar quit reminder and the host File Provider "enable in
    /// System Settings" reminder. The guest agent surfaces its own File Provider
    /// reminder inside the VM, backed by a separate defaults domain in a separate
    /// process (`KernovaMacOSAgent`); that dismissal is out of reach here and is
    /// left untouched (an explicitly documented gap surfaced to the user in the
    /// Reminders settings pane). Per-VM agent-install nudges live in each VM's
    /// bundle configuration, not here, and are reset by
    /// `VMLibraryViewModel.resetAllAgentInstallNudges()`.
    func resetHostReminders() {
        menuBarQuitReminderDismissed = false
        fileProviderReminderDismissed = false
    }
}
