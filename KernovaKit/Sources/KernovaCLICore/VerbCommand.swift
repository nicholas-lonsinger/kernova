import ArgumentParser
import Foundation
import KernovaKit

/// A subcommand whose whole request is decided from the command line alone.
///
/// Separating the request from the sending is what lets a mistyped line refuse
/// before Kernova is started to hear it, and what lets a test assert the bytes
/// a command line turns into rather than only what it printed. A verb the tool
/// can only build after a round trip — a snapshot named rather than
/// identified, a copy waited out — is not one of these.
protocol VerbCommand: GlobalOptionsCommand {
    /// The request this command line stands for.
    ///
    /// - Throws: ``CLIFailure`` with ``CLIExitCode/usage`` for an argument the
    ///   tool itself can see is not one the verb takes.
    func verb() throws -> VMCommandRequest.Verb
}

extension VerbCommand {
    /// Sends the request and reports whatever refusal it carries, for a verb
    /// that answers with nothing.
    func perform() throws {
        try CommandConnection.perform(try verb(), launchIfNeeded: !options.noLaunch)
    }

    /// Sends the request and hands back the payload it was answered with.
    func answer() throws -> VMCommandResponse.Result {
        let request = try verb()
        let client = try CommandConnection.open(launchIfNeeded: !options.noLaunch)
        defer { client.close() }
        return try client.send(request).payload()
    }
}
