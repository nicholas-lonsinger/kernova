import ArgumentParser
import Foundation
import KernovaAppRegistry
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
            try Self.awaitDeregistration()
        }

        /// Blocks until Launch Services has released the app this tool is
        /// embedded in.
        ///
        /// Another verb of this tool would wait here on its own way in, so this
        /// is not what makes `kernova quit && kernova start x` safe. What it
        /// buys is the promise the verb's *return* carries: a script is free to
        /// reach for `open -a Kernova`, or anything else that asks Launch
        /// Services to open the app, on the line after this one.
        ///
        /// A copy of the tool outside an app bundle names no app, so it has
        /// nothing to wait on.
        ///
        /// - Throws: ``CLIFailure`` with ``CLIExitCode/timedOut`` when the
        ///   registration outlives the wait — the quit itself succeeded, and
        ///   the code says the promise did not.
        static func awaitDeregistration() throws {
            guard let bundle = AppLaunch.enclosingBundle else { return }
            let deadline = Date(timeIntervalSinceNow: AppRegistryWait.defaultDeadline)
            guard
                AppRegistryWait.awaitDeregistration(
                    ofBundleAt: bundle, scope: .all, by: deadline)
            else {
                throw CLIFailure(
                    .timedOut,
                    "Kernova has quit, but macOS still had it registered "
                        + "\(Int(AppRegistryWait.defaultDeadline)) seconds later. Starting it "
                        + "again now may fail.")
            }
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
        /// when the process exits — nothing in the app closes the command
        /// socket earlier, so the hang-up means the process is gone.
        ///
        /// Anything the app says in the meantime is read and dropped: the quit
        /// has been accepted, and the only thing left to wait for is the socket
        /// going away.
        ///
        /// The process being gone is not yet the app being relaunchable:
        /// Launch Services holds its registration for tens of milliseconds
        /// longer, and that registry is what `NSWorkspace.openApplication`
        /// consults, so ``AppRegistryWait`` covers the rest.
        static func awaitExit(of client: VMCommandClient) throws {
            while try client.nextFrame() != nil {}
        }
    }
}
