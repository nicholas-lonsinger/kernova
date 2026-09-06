import Foundation
import KernovaKit

/// How a subcommand reaches the app.
public enum CommandConnection {
    /// A client connected to the running app's command socket.
    ///
    /// Kernova has to be running already; `kernova` does not start it. A
    /// sandboxed process's `NSWorkspace.openApplication` reaches the app with
    /// none of `arguments`, `environment` or `appleEvent` — measured
    /// 2026-09-05, with an unsandboxed caller's `arguments` arriving as the
    /// control — so a launch the tool performed would be indistinguishable from
    /// a double-click. It would put the library window on screen and hold the
    /// process resident, which is the wrong answer for a shell with nobody
    /// watching.
    ///
    /// - Throws: ``CLIFailure`` with ``CLIExitCode/unavailable`` when this
    ///   build resolves no app-group container — an ad-hoc signature has none,
    ///   so the tool can reach no app at all — or when Kernova is not running.
    public static func open(_ options: GlobalOptions) throws -> VMCommandClient {
        guard let socketPath = KernovaAppGroup.socketPath() else {
            throw CLIFailure(
                .unavailable,
                "This copy of kernova is not signed to share Kernova's app group, so it cannot "
                    + "reach the app. Install the tool from Kernova's Settings \u{2192} Advanced.")
        }
        return try VMCommandClient(socketPath: socketPath)
    }
}

/// Where the tool writes.
public enum Console {
    /// Writes `text` and a newline to standard output; an empty string writes
    /// nothing, so a listing with no rows produces no blank line.
    public static func out(_ text: String) {
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
