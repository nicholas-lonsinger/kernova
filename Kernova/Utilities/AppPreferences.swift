import Foundation
import KernovaKit
import KernovaLogging

/// App-wide user preferences backed by `UserDefaults`.
///
/// Distinct from per-VM `VMConfiguration`: this holds settings that apply to the
/// whole app and live in the standard defaults domain.
struct AppPreferences {
    /// Shared production instance over the standard defaults domain.
    @MainActor static let shared = AppPreferences(defaults: .standard)

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "AppPreferences")

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The literal `UserDefaults` key strings.
    ///
    /// Renaming one orphans the value every existing install has already stored
    /// under the old string, so each key stays as written — including where its
    /// namespacing reads inconsistently against its neighbours.
    private enum Keys {
        static let alwaysShowAdvancedOptions = "alwaysShowAdvancedOptions"
        static let collapsedSidebarSections = "KernovaSidebarCollapsedSections"
        static let sidebarViewOptions = "KernovaSidebarViewOptions"
        static let sidebarSelection = "KernovaSidebarSelection"
        static let vmOrder = "vmOrder"
        static let quitTerminatesApp = "quitTerminatesApp"
        static let menuBarQuitReminderDismissed = "menuBarQuitReminderDismissed"
        static let agentInstallPromptDisabled = "agentInstallPromptDisabled"
        static let mainToolbarNewVMCollapseIndex = "KernovaMainToolbarNewVMCollapseIndex"
        static let allowDuplicateMachineIDBoot = "allowDuplicateMachineIDBoot"
        static let cloneKeepsMachineID = "cloneKeepsMachineID"
        static let clipboardMaxPasteBytes = "clipboardMaxPasteBytes"
    }

    // MARK: - Inverted Storage

    /// Reads the inverse of the boolean stored under the given key, so an unset
    /// key yields a `true` default.
    ///
    /// Every `true`-defaulting preference is stored through this pair, under a
    /// key naming the inverse it literally holds, so no defaults are registered.
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

    /// Identifiers of the sidebar sections the user has collapsed; every other
    /// section is expanded.
    var collapsedSidebarSections: [String] {
        get { defaults.array(forKey: Keys.collapsedSidebarSections) as? [String] ?? [] }
        nonmutating set { defaults.set(newValue, forKey: Keys.collapsedSidebarSections) }
    }

    /// How the sidebar narrows, orders and groups the library, defaulting to
    /// ``SidebarViewOptions/init()``.
    ///
    /// A filter value the library no longer lists — a deleted tag or named
    /// network — is kept as stored: the filter menu offers to clear it.
    var sidebarViewOptions: SidebarViewOptions {
        get { decoded(SidebarViewOptions.self, forKey: Keys.sidebarViewOptions) ?? SidebarViewOptions() }
        nonmutating set { setEncoded(newValue, forKey: Keys.sidebarViewOptions) }
    }

    /// The most recently selected sidebar row, or `nil` when none is.
    var sidebarSelection: SidebarRowKey? {
        get { decoded(SidebarRowKey.self, forKey: Keys.sidebarSelection) }
        nonmutating set { setEncoded(newValue, forKey: Keys.sidebarSelection) }
    }

    /// The value stored as JSON under `key`, each config field that does not
    /// decode at its fallback (``JSONDecoder/decodeRepairing(_:from:)``) — or
    /// `nil` when none is stored or it does not decode as `type` even so, a
    /// failure logged and the caller's default standing in for the value.
    private func decoded<Value: Decodable>(_ type: Value.Type, forKey key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decodeRepairing(type, from: data)
        } catch {
            #log(
                Self.logger, .error,
                "Stored \(key, privacy: .public) did not decode; using the default: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Stores `value` as JSON under `key`, or removes the key for `nil`; a
    /// value that fails to encode is logged and leaves the stored one.
    private func setEncoded<Value: Encodable>(_ value: Value?, forKey key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            #log(
                Self.logger, .error,
                "Could not store \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
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

    /// Whether the sidebar's guest-agent install nudge is turned off for every
    /// VM, defaulting to `false`.
    ///
    /// Suppresses only the gentle `.waiting` prompt, matching the scope of the
    /// per-VM `VMHostState.agentInstallNudgeDismissed` flag it overrides.
    /// Read and written through `VMLibraryViewModel.agentInstallPromptDisabled`,
    /// whose `@Observable` mirror is what wakes the panes that render it.
    var agentInstallPromptDisabled: Bool {
        get { defaults.bool(forKey: Keys.agentInstallPromptDisabled) }
        nonmutating set { defaults.set(newValue, forKey: Keys.agentInstallPromptDisabled) }
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

    /// Whether a start refused because another active VM has the same machine
    /// identifier asks the user whether to start anyway, defaulting to `false`.
    var allowsDuplicateMachineIDOverride: Bool {
        get { defaults.bool(forKey: Keys.allowDuplicateMachineIDBoot) }
        nonmutating set { defaults.set(newValue, forKey: Keys.allowDuplicateMachineIDBoot) }
    }

    /// What Clone makes of a VM that offers both outcomes, defaulting to New
    /// Machine.
    var cloneOutcome: CloneOutcome {
        get { defaults.bool(forKey: Keys.cloneKeepsMachineID) ? .exactCopy : .newMachine }
        nonmutating set { defaults.set(newValue == .exactCopy, forKey: Keys.cloneKeepsMachineID) }
    }

    /// What Clone makes of the VM `configuration` describes: ``cloneOutcome``,
    /// or Exact Copy where New Machine is absent
    /// (``VMConfiguration/offersNewMachineClone``). `nil` is no VM, which
    /// offers both.
    func cloneOutcome(for configuration: VMConfiguration?) -> CloneOutcome {
        configuration?.offersNewMachineClone == false ? .exactCopy : cloneOutcome
    }

    /// Ceiling on the total of one paste's file representations, in bytes.
    ///
    /// Always one of `ClipboardPasteLimit.choices`: an unset key and any value
    /// off the ladder both resolve to the nearest offered stop, so no
    /// enforcement point ever sees a ceiling with no derivation behind it.
    var clipboardMaxPasteBytes: Int {
        get {
            ClipboardPasteLimit.resolve(
                defaults.object(forKey: Keys.clipboardMaxPasteBytes) as? Int)
        }
        nonmutating set { defaults.set(newValue, forKey: Keys.clipboardMaxPasteBytes) }
    }

    /// The Clone menu items for the VM `configuration` describes: `primary`
    /// makes what ``cloneOutcome(for:)`` resolves to, and `alternate` the
    /// other outcome — `nil` where only one is offered.
    func cloneMenuItems(
        for configuration: VMConfiguration?
    ) -> (primary: CloneMenuItem, alternate: CloneMenuItem?) {
        let primary = cloneOutcome(for: configuration)
        let other: CloneOutcome = primary == .newMachine ? .exactCopy : .newMachine
        let offersOther = other == .exactCopy || configuration?.offersNewMachineClone != false
        return (CloneMenuItem(outcome: primary), offersOther ? CloneMenuItem(outcome: other) : nil)
    }

    /// Re-arms every host-side reminder by clearing its dismissed flag, so each
    /// nag shows again the next time its condition is met.
    ///
    /// Covers only the menu-bar quit reminder. The guest-agent install nudge —
    /// app-wide here, per-VM in each bundle configuration — is re-armed as one
    /// by `VMLibraryViewModel.resetAllAgentInstallNudges()`.
    func resetHostReminders() {
        menuBarQuitReminderDismissed = false
    }
}

/// One Clone menu item: the outcome it makes, and its title.
struct CloneMenuItem: Equatable {
    let outcome: CloneOutcome

    var title: String { "Clone as \(outcome.displayName)" }
}

extension CloneOutcome {
    /// How every app surface names the outcome.
    var displayName: String {
        switch self {
        case .newMachine: "New Machine"
        case .exactCopy: "Exact Copy"
        }
    }
}
