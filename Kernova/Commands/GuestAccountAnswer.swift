/// What a start does about the account its VM owes the guest.
///
/// Rides the verb the way `confirmed` does, and for the same reason: the core
/// has no surface to ask on, so the answer arrives as a parameter of the call
/// it authorises and belongs to that call alone. In-process only — it answers
/// a ``GuestAccountPrompt``, which is the DTO that crosses a wire — so it
/// never needs to.
enum GuestAccountAnswer: Sendable, Hashable, CustomStringConvertible {
    /// Create the account, with this password.
    case password(String)
    /// Boot without creating it, leaving macOS to ask for an account in Setup
    /// Assistant. The boot this answers for is the one macOS would have created
    /// the account on, so coming up is what ends it — a start that never got
    /// there leaves the account for the next one to ask about.
    case skip

    /// Redacts the password, so interpolating an answer into a log line or a
    /// debugger dump cannot spill it.
    var description: String {
        switch self {
        case .password: "password(<redacted>)"
        case .skip: "skip"
        }
    }
}
