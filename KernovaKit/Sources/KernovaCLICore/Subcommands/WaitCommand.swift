import ArgumentParser
import Foundation
import KernovaCommandModel

extension WaitCondition: ExpressibleByArgument {}

extension KernovaCommand {
    /// `kernova wait <vm> --until <condition>` — block until a VM gets there.
    struct Wait: VerbCommand {
        /// What `kernova wait --help` says.
        static let configuration = CommandConfiguration(
            commandName: "wait",
            abstract: "Block until a virtual machine reaches a state.",
            discussion: "Race-free against a virtual machine already in the state: the app reads the "
                + "state in the step that starts watching it, so nothing can land in between and be "
                + "missed."
                + "\n\nA virtual machine that fails while the wait runs ends it at exit 1, "
                + "carrying what Kernova reported. One already in the error status when the "
                + "wait starts does not: it can be started from there, so the wait goes on."
                + "\n\n--until address waits for Kernova to see the guest use an address on its "
                + "network, and exits 5 when Kernova can see none for it, as for one that is "
                + "bridged or not running. `kernova ip --wait` prints the address it waited for.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// The state to wait for.
        @Option(name: .long, help: "The state to wait for: running, stopped, agent, or address.")
        var until: WaitCondition

        /// How long to wait before giving up.
        @Option(name: .long, help: "Seconds to wait before giving up.")
        var timeout: Double = TimeoutOption.waitDefault

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// Refuses a deadline that names no wait.
        func validate() throws {
            try TimeoutOption.validate(timeout)
        }

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .wait(
                try SelectorParsing.selector(from: vm, forcingID: options.id), until: until,
                timeout: timeout)
        }

        /// Waits, or refuses with what stood in the way.
        func run() throws {
            try answer { answered in
                guard case .info = answered else { throw answered.unexpectedAnswer }
            }
        }
    }
}
