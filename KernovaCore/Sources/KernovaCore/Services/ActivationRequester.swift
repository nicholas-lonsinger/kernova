/// Asks whoever sent the request being answered to bring this process forward.
///
/// Only the requester can: an app asking to activate itself with no user event
/// behind it is refused, while a requester that yields and then activates this
/// process by pid is honored. A front door installs one as ``current`` around
/// the verbs it runs — the command socket's readies the app and asks the tool
/// to activate it; a door whose requester activates by other means installs
/// one that only readies. Code a verb reaches asks at the moment it actually
/// puts something up, so a refused verb asks nothing, and under a door that
/// installed none nothing happens: a surface shown in the same main-actor job
/// as the verb's checks calls ``requestActivation()``, and a permission panel,
/// which waits on the user anyway, awaits ``awaitActivation()``.
///
/// Task-local, so it reaches a `Task {}` the verb starts but not a
/// `Task.detached`: work that needs it stays structured.
package struct ActivationRequester: Sendable {
    /// The requester of the request the current task is answering.
    @TaskLocal package static var current: ActivationRequester?

    private let request: @MainActor @Sendable () -> Void
    private let awaitedRequest: @MainActor @Sendable () async throws -> Void

    /// Wraps what makes the process presentable and asks the requester to
    /// activate it, which it does once asked.
    package init(_ request: @escaping @MainActor @Sendable () -> Void) {
        self.request = request
        self.awaitedRequest = request
    }

    /// A requester whose deliverer has to be waited on: `request` returns once
    /// the process is forward, and throws when it could not be brought there.
    ///
    /// Only a surface that waits, ``awaitActivation()``, can ask it; a surface
    /// shown in the verb's own job asks nothing.
    package init(awaiting request: @escaping @MainActor @Sendable () async throws -> Void) {
        self.request = {}
        self.awaitedRequest = request
    }

    /// Asks the current request's requester, if its door installed one, to
    /// bring the process forward, for a surface shown in this same job.
    @MainActor
    package static func requestActivation() {
        current?.request()
    }

    /// Asks the current request's requester, if its door installed one, to
    /// bring the process forward, and returns once it is; a throw means it
    /// was not brought forward, and nothing should be put up.
    @MainActor
    package static func awaitActivation() async throws {
        try await current?.awaitedRequest()
    }
}
