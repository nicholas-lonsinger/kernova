import Foundation
import KernovaKit

/// How a subcommand reaches the app.
enum CommandConnection {
    /// A client connected to the command socket of the Kernova this tool is
    /// inside, starting that app when nothing is listening and
    /// `launchIfNeeded` allows it.
    ///
    /// The launch comes up hidden and takes no focus, so a verb typed in a
    /// terminal answers without anything appearing in front of it. `--no-launch`
    /// is what turns that off, leaving a stopped app as the exit-9 refusal it
    /// was.
    ///
    /// - Throws: ``CLIFailure`` with ``CLIExitCode/unavailable`` when this copy
    ///   of the tool is not inside an app, or resolves no app-group container —
    ///   an ad-hoc signature has none — so it can reach no app at all; when the
    ///   launch itself is refused; or when the app does not answer in time.
    static func open(launchIfNeeded: Bool) throws -> VMCommandClient {
        let app = try enclosingApp()
        let socketPath = try socketPath(of: app)
        do {
            return try VMCommandClient(socketPath: socketPath)
        } catch let failure as CLIFailure {
            guard launchIfNeeded else { throw failure }
            return try launchAndConnect(app, at: socketPath)
        }
    }

    /// A client connected to the Kernova this tool is inside when it is already
    /// running, or `nil` when it is not — for the one verb that has nothing to
    /// ask of an app that is not there.
    ///
    /// A copy of the tool that can reach no app still throws, whether or not
    /// one is running, which is a different answer from "there is nothing to
    /// talk to".
    static func openIfRunning() throws -> VMCommandClient? {
        let socketPath = try socketPath(of: try enclosingApp())
        return try? VMCommandClient(socketPath: socketPath)
    }

    /// The app this copy of the tool is inside, which is the one copy of
    /// Kernova it starts and reaches.
    ///
    /// - Throws: ``CLIFailure`` with ``CLIExitCode/unavailable`` for a copy of
    ///   the tool that is not inside an app.
    static func enclosingApp() throws -> URL {
        guard let app = EnclosingAppBundle.current else {
            throw CLIFailure(
                .unavailable,
                "This copy of kernova is not inside a Kernova.app, so it cannot reach the app. "
                    + "Install the tool from Kernova's Settings \u{2192} Advanced.")
        }
        return app
    }

    /// Runs one verb that answers with nothing, reporting whatever refusal it
    /// carries.
    static func perform(
        _ verb: VMCommandRequest.Verb, launchIfNeeded: Bool
    ) throws {
        let client = try open(launchIfNeeded: launchIfNeeded)
        defer { client.close() }
        _ = try client.send(verb).payload()
    }

    /// Where the socket of the app at `app` lives, refusing a build that
    /// resolves no app-group container.
    private static func socketPath(of app: URL) throws -> String {
        guard let socketPath = KernovaAppGroup.socketPath(forAppBundle: app) else {
            throw CLIFailure(
                .unavailable,
                "This copy of kernova is not signed to share Kernova's app group, so it cannot "
                    + "reach the app. Install the tool from Kernova's Settings \u{2192} Advanced.")
        }
        return socketPath
    }

    /// Starts the app at `app` and retries the connect to its socket on
    /// ``ConnectBackoff``'s schedule.
    ///
    /// The first successful connect is the readiness signal; a launch Launch
    /// Services refused ends the wait early rather than spending the whole
    /// deadline on an app that is not coming.
    ///
    /// One deadline covers both halves — waiting out a registration Launch
    /// Services has not released, then waiting for the app to answer — so the
    /// number the refusal below names is the one a caller actually waits.
    private static func launchAndConnect(_ app: URL, at socketPath: String) throws -> VMCommandClient {
        let deadline = Date(timeIntervalSinceNow: ConnectBackoff.defaultDeadline)
        AppLaunch.launch(app, by: deadline)
        for delay in ConnectBackoff.delays() {
            guard Date() < deadline else { break }
            Thread.sleep(forTimeInterval: delay)
            if let failure = AppLaunch.reportedFailure { throw failure }
            if let client = try? VMCommandClient(socketPath: socketPath) { return client }
        }
        throw CLIFailure(
            .unavailable,
            "Kernova was started but did not answer within "
                + "\(Int(ConnectBackoff.defaultDeadline)) seconds.")
    }
}

/// Where the tool writes.
enum Console {
    /// Writes `text` and a newline to standard output; an empty string writes
    /// nothing, so a listing with no rows produces no blank line.
    static func out(_ text: String) {
        guard !text.isEmpty else { return }
        FileHandle.standardOutput.write(Data((text + "\n").utf8))
    }
}

extension VMCommandResponse.Result {
    /// The refusal for an answer whose shape no verb should ever produce.
    ///
    /// Reached only if the app answered a different verb than the one asked,
    /// which means the two are not the peers their protocol version claims.
    var unexpectedAnswer: CLIFailure {
        CLIFailure(.unavailable, "Kernova answered with something this tool did not ask for.")
    }
}
