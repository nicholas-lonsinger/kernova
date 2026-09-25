/// Asks whoever sent the request being answered to bring this process forward.
///
/// Only the requester can: an app asking to activate itself with no user event
/// behind it is refused, while a requester that yields and then activates this
/// process by pid is honored. A front door whose requester can do that installs
/// one as ``current`` around the verb it runs; code the verb reaches that needs
/// the app in front — a permission panel — calls ``requestActivation()``, and
/// under a door that installed none it gets no activation.
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
