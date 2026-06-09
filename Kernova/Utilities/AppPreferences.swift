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
}
