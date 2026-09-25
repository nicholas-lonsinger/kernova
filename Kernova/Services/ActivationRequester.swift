/// Asks whoever sent the request being answered to bring this process forward.
///
/// Only the requester can: an app asking to activate itself with no user event
/// behind it is refused, while a requester that yields and then activates this
/// process by pid is honored. A front door installs one as ``current`` around
/// the verbs it runs — the command socket's readies the app and asks the tool
/// to activate it; a door whose requester activates by other means installs
/// one that only readies. Code a verb reaches calls ``requestActivation()`` at
/// the moment it actually puts something up — a surface, a permission panel —
/// so a refused verb asks nothing, and under a door that installed none
/// nothing happens.
///
/// Task-local, so it reaches a `Task {}` the verb starts but not a
/// `Task.detached`: work that needs it stays structured.
struct ActivationRequester: Sendable {
    /// The requester of the request the current task is answering.
    @TaskLocal static var current: ActivationRequester?

    private let request: @MainActor @Sendable () -> Void

    /// Wraps what makes the process presentable and asks the requester to
    /// activate it.
    init(_ request: @escaping @MainActor @Sendable () -> Void) {
        self.request = request
    }

    /// Asks this requester to bring the process forward.
    @MainActor
    func requestActivation() {
        request()
    }

    /// Asks the current request's requester, if its door installed one, to
    /// bring the process forward.
    @MainActor
    static func requestActivation() {
        current?.requestActivation()
    }
}
