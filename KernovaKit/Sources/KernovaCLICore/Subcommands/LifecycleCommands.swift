import ArgumentParser
import Foundation
import KernovaKit

extension KernovaCommand {
    /// How `kernova stop` reaches a powered-off guest.
    enum StopMethod: String, EnumerableFlag {
        /// Ask the guest to shut itself down.
        case graceful
        /// Resume a paused guest first, then ask it to shut down.
        case resumeFirst
        /// Terminate the guest immediately, losing unsaved state.
        case force

        /// The wire disposition this method names.
        var disposition: StopDisposition {
            switch self {
            case .graceful: .graceful
            case .resumeFirst: .resumeThenShutDown
            case .force: .force
            }
        }

        /// What each flag's help says.
        static func help(for value: StopMethod) -> ArgumentHelp? {
            switch value {
            case .graceful: "Ask the guest to shut down (the default)."
            case .resumeFirst: "Resume a paused guest, then ask it to shut down."
            case .force: "Terminate the guest immediately, losing unsaved state."
            }
        }
    }

    /// `kernova start <vm>` — bring a guest up.
    struct Start: VerbCommand {
        /// What `kernova start --help` says.
        static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start a virtual machine.",
            discussion: "Nothing is brought in front of you; `kernova open` is the verb that puts "
                + "a display there.\n\nA virtual machine that still owes its guest setup — a "
                + "macOS install, or a Linux installer image to fetch — returns once that setup "
                + "has begun, and it carries on afterwards. `kernova wait <vm> --until running` "
                + "is what a script watches it with.\n\nA virtual machine that creates a macOS account on its "
                + "first boot is started in Kernova, which asks for the account's password in a "
                + "sheet. This tool takes no password, because it runs in the App Sandbox, which "
                + "denies turning terminal echo off, and such a start exits 5.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// Cold-boot a stopped macOS guest into macOS Recovery.
        @Flag(name: .long, help: "Cold-boot a macOS guest into Recovery.")
        var recovery = false

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .start(
                try SelectorParsing.selector(from: vm, forcingID: options.id),
                recovery: recovery)
        }

        /// Starts the VM.
        func run() throws {
            try perform()
        }
    }

    /// `kernova stop <vm>` — take a guest down.
    struct Stop: VerbCommand {
        /// What `kernova stop --help` says.
        static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Stop a virtual machine.",
            discussion: "Returns as soon as the guest has been asked to shut down. --timeout "
                + "waits for it to power off instead, and exits 7 leaving the virtual machine "
                + "as it is when the guest is still up; --force is the escalation from there.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// How the stop should reach the guest.
        @Flag(exclusivity: .exclusive)
        var method: StopMethod = .graceful

        /// How long to wait for the guest to power off, or `nil` to return
        /// without waiting.
        @Option(name: .long, help: "Seconds to wait for the guest to power off before giving up.")
        var timeout: Double?

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// Refuses a deadline that names no wait.
        func validate() throws {
            try TimeoutOption.validate(timeout)
        }

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .stop(
                try SelectorParsing.selector(from: vm, forcingID: options.id),
                disposition: method.disposition, confirmed: options.yes, timeout: timeout)
        }

        /// Stops the VM.
        func run() throws {
            try perform()
        }
    }

    /// `kernova suspend <vm>` — save the session to the bundle.
    struct Suspend: VerbCommand {
        /// What `kernova suspend --help` says.
        static let configuration = CommandConfiguration(
            commandName: "suspend",
            abstract: "Save a running guest's session and stop it.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .suspend(try SelectorParsing.selector(from: vm, forcingID: options.id))
        }

        /// Suspends the VM.
        func run() throws {
            try perform()
        }
    }

    /// `kernova pause <vm>` — hold the guest in memory.
    struct Pause: VerbCommand {
        /// What `kernova pause --help` says.
        static let configuration = CommandConfiguration(
            commandName: "pause",
            abstract: "Pause a running guest, holding it in memory.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .pause(try SelectorParsing.selector(from: vm, forcingID: options.id))
        }

        /// Pauses the VM.
        func run() throws {
            try perform()
        }
    }

    /// `kernova resume <vm>` — let a paused guest run again.
    struct Resume: VerbCommand {
        /// What `kernova resume --help` says.
        static let configuration = CommandConfiguration(
            commandName: "resume",
            abstract: "Resume a paused guest.",
            discussion: "Nothing is brought in front of you; `kernova open` is the verb that puts "
                + "a display there.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .resume(try SelectorParsing.selector(from: vm, forcingID: options.id))
        }

        /// Resumes the VM.
        func run() throws {
            try perform()
        }
    }

    /// `kernova restart <vm>` — shut down and start again.
    struct Restart: VerbCommand {
        /// What `kernova restart --help` says.
        static let configuration = CommandConfiguration(
            commandName: "restart",
            abstract: "Shut a guest down and start it again.",
            discussion: "Nothing is brought in front of you, as with `start`; `kernova open` is "
                + "the verb that puts a display there. --timeout bounds the shutdown half: a "
                + "guest still up when it expires exits 7 and is not started again.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// How long to wait for the guest to power off, or `nil` to wait as
        /// long as it takes.
        @Option(name: .long, help: "Seconds to wait for the guest to shut down before giving up.")
        var timeout: Double?

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// Refuses a deadline that names no wait.
        func validate() throws {
            try TimeoutOption.validate(timeout)
        }

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .restart(
                try SelectorParsing.selector(from: vm, forcingID: options.id), timeout: timeout)
        }

        /// Restarts the VM.
        func run() throws {
            try perform()
        }
    }

    /// `kernova open <vm>` — put the guest's display in front of the user.
    struct Open: VerbCommand {
        /// What `kernova open --help` says.
        ///
        /// The one verb here that surfaces something: it is what somebody
        /// at the machine types when they want to see the guest.
        static let configuration = CommandConfiguration(
            commandName: "open",
            abstract: "Bring a running guest's display to the front.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .open(try SelectorParsing.selector(from: vm, forcingID: options.id))
        }

        /// Surfaces the VM's display.
        func run() throws {
            try perform()
        }
    }
}
