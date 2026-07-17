import Foundation

/// Agent-wide user preferences backed by `UserDefaults`.
///
/// Mirrors the host app's `AppPreferences` shape: a thin value type over an
/// injectable `UserDefaults` so tests can use an ephemeral suite, while
/// production reads `AgentPreferences.shared`. The guest agent is a separate
/// process with its own defaults domain, so it can't share the host's
/// `AppPreferences` type even though both live in the same Xcode project —
/// each machine's File Provider toggle (and its reminder dismissal) is
/// independent (#581).
struct AgentPreferences {
    /// Shared production instance over the standard defaults domain.
    ///
    /// Isolated to the main actor — its only reader/writer is the status-item
    /// controller, which is `@MainActor`. Tests construct their own instances
    /// over an ephemeral suite instead of touching this.
    @MainActor static let shared = AgentPreferences(defaults: .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private enum Keys {
        static let fileProviderReminderDismissed = "fileProviderReminderDismissed"
    }

    /// Whether the user dismissed the current "enable File Provider"
    /// status-item reminder (#581).
    ///
    /// Set by "Stop Reminding Me" in `AgentStatusItemController`'s dropdown;
    /// reset back to `false` once availability reaches `.ready`, so a later,
    /// genuinely new disablement nags again rather than staying silenced
    /// forever.
    var fileProviderReminderDismissed: Bool {
        get { defaults.bool(forKey: Keys.fileProviderReminderDismissed) }
        nonmutating set { defaults.set(newValue, forKey: Keys.fileProviderReminderDismissed) }
    }
}
