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
}
