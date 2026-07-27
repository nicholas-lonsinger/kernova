import Foundation

/// Agent-wide user preferences backed by an injectable `UserDefaults`.
struct AgentPreferences {
    /// Shared production instance; tests construct their own over an ephemeral
    /// suite instead of touching this.
    @MainActor static let shared = AgentPreferences(defaults: .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private enum Keys {
        static let fileProviderReminderDismissed = "fileProviderReminderDismissed"
    }

    /// Whether the user dismissed the current "enable File Provider" reminder.
    ///
    /// Reset to `false` once availability reaches `.ready`, so a later, genuinely
    /// new disablement nags again rather than staying silenced forever.
    var fileProviderReminderDismissed: Bool {
        get { defaults.bool(forKey: Keys.fileProviderReminderDismissed) }
        nonmutating set { defaults.set(newValue, forKey: Keys.fileProviderReminderDismissed) }
    }
}
