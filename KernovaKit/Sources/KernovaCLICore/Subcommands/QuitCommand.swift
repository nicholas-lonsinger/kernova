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

        /// Quits the app and returns once it has gone, or reports success when
        /// there is none to quit.
        ///
        /// The one verb that never starts Kernova: quitting an app that is not
        /// running has already happened.
        public func run() throws {
            guard let client = try CommandConnection.openIfRunning() else { return }
            defer { client.close() }
            try client.post(.quit)
            let answer = try client.nextFrame()
            try Self.outcome(for: answer)
            // `ok` only means the quit was accepted — the save pass still has to
            // run. Exiting here would let `kernova quit && kernova start x`
            // reach the dying instance, or spend the whole connect deadline
            // against one on its way out.
            if answer != nil { try Self.awaitExit(of: client) }
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

        /// Blocks until the app closes the connection, which the kernel does
        /// when the process exits.
        ///
        /// Anything the app says in the meantime is read and dropped: the quit
        /// has been accepted, and the only thing left to wait for is the socket
        /// going away.
        static func awaitExit(of client: VMCommandClient) throws {
            while try client.nextFrame() != nil {}
        }
    }
}
