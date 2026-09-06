import ArgumentParser
import Foundation
import KernovaKit

extension KernovaCommand {
    /// `kernova quit` — take Kernova down, saving whatever is running.
    public struct Quit: ParsableCommand {
        /// What `kernova quit --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "quit",
            abstract: "Quit Kernova, saving any running virtual machines.")

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Quits the app, or reports success when there is none to quit.
        ///
        /// The one verb that never starts Kernova: quitting an app that is not
        /// running has already happened.
        public func run() throws {
            guard let client = try CommandConnection.openIfRunning() else { return }
            defer { client.close() }
            try client.post(.quit)
            try Self.outcome(for: try client.nextFrame())
        }

        /// Reads the answer a quit gets, treating end-of-stream as success.
        ///
        /// The app encodes its `ok` before termination begins, but a client can
        /// still find the connection closed first — the process it just asked
        /// to leave is leaving. Only an answer that carries a refusal is one.
        static func outcome(for answer: VMCommandResponse?) throws {
            guard let answer else { return }
            _ = try answer.payload()
        }
    }
}
