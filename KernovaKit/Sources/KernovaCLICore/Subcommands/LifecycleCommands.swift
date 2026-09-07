import ArgumentParser
import Foundation
import KernovaKit

extension KernovaCommand {
    /// How `kernova stop` reaches a powered-off guest.
    public enum StopMethod: String, EnumerableFlag {
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
        public static func help(for value: StopMethod) -> ArgumentHelp? {
            switch value {
            case .graceful: "Ask the guest to shut down (the default)."
            case .resumeFirst: "Resume a paused guest, then ask it to shut down."
            case .force: "Terminate the guest immediately, losing unsaved state."
            }
        }
    }

    /// `kernova start <vm>` — bring a guest up.
    public struct Start: ParsableCommand {
        /// What `kernova start --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "start",
            abstract: "Start a virtual machine.",
            discussion: "The guest comes up without surfacing its display; `kernova open` is the "
                + "verb that puts a display in front of you.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.")
        public var vm: String

        /// Cold-boot a stopped macOS guest into macOS Recovery.
        @Flag(name: .long, help: "Cold-boot a macOS guest into Recovery.")
        public var recovery = false

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Starts the VM.
        public func run() throws {
            // Headless, always. A command typed in a terminal is not a request
            // for a window to jump in front of whatever is on screen.
            try CommandConnection.perform(
                .start(
                    try SelectorParsing.selector(from: vm, forcingID: options.id),
                    recovery: recovery, presentation: .headless),
                launchIfNeeded: !options.noLaunch)
        }
    }

    /// `kernova stop <vm>` — take a guest down.
    public struct Stop: ParsableCommand {
        /// What `kernova stop --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Stop a virtual machine.",
            discussion: "Returns as soon as the guest has been asked to shut down. --timeout "
                + "waits for it to power off instead, and exits 7 leaving the virtual machine "
                + "as it is when the guest is still up; --force is the escalation from there.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.")
        public var vm: String

        /// How the stop should reach the guest.
        @Flag(exclusivity: .exclusive)
        public var method: StopMethod = .graceful

        /// How long to wait for the guest to power off, or `nil` to return
        /// without waiting.
        @Option(name: .long, help: "Seconds to wait for the guest to power off before giving up.")
        public var timeout: Double?

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Refuses a deadline that names no wait.
        public func validate() throws {
            try TimeoutOption.validate(timeout)
        }

        /// Stops the VM.
        public func run() throws {
            try CommandConnection.perform(
                .stop(
                    try SelectorParsing.selector(from: vm, forcingID: options.id),
                    disposition: method.disposition, confirmed: options.yes, timeout: timeout),
                launchIfNeeded: !options.noLaunch)
        }
    }

    /// `kernova suspend <vm>` — save the session to the bundle.
    public struct Suspend: ParsableCommand {
        /// What `kernova suspend --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "suspend",
            abstract: "Save a running guest's session and stop it.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.")
        public var vm: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Suspends the VM.
        public func run() throws {
            try CommandConnection.perform(
                .suspend(try SelectorParsing.selector(from: vm, forcingID: options.id)),
                launchIfNeeded: !options.noLaunch)
        }
    }

    /// `kernova pause <vm>` — hold the guest in memory.
    public struct Pause: ParsableCommand {
        /// What `kernova pause --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "pause",
            abstract: "Pause a running guest, holding it in memory.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.")
        public var vm: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Pauses the VM.
        public func run() throws {
            try CommandConnection.perform(
                .pause(try SelectorParsing.selector(from: vm, forcingID: options.id)),
                launchIfNeeded: !options.noLaunch)
        }
    }

    /// `kernova resume <vm>` — let a paused guest run again.
    public struct Resume: ParsableCommand {
        /// What `kernova resume --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "resume",
            abstract: "Resume a paused guest.",
            discussion: "The guest resumes without surfacing its display; `kernova open` is the "
                + "verb that puts a display in front of you.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.")
        public var vm: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Resumes the VM, headless for the same reason `start` is.
        public func run() throws {
            try CommandConnection.perform(
                .resume(
                    try SelectorParsing.selector(from: vm, forcingID: options.id),
                    presentation: .headless),
                launchIfNeeded: !options.noLaunch)
        }
    }

    /// `kernova restart <vm>` — shut down and start again.
    public struct Restart: ParsableCommand {
        /// What `kernova restart --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "restart",
            abstract: "Shut a guest down and start it again.",
            discussion: "The guest comes back up without surfacing its display, as `start` does. "
                + "--timeout bounds the shutdown half: a guest still up when it expires exits 7 "
                + "and is not started again.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.")
        public var vm: String

        /// How long to wait for the guest to power off, or `nil` to wait as
        /// long as it takes.
        @Option(name: .long, help: "Seconds to wait for the guest to shut down before giving up.")
        public var timeout: Double?

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Refuses a deadline that names no wait.
        public func validate() throws {
            try TimeoutOption.validate(timeout)
        }

        /// Restarts the VM.
        public func run() throws {
            try CommandConnection.perform(
                .restart(
                    try SelectorParsing.selector(from: vm, forcingID: options.id),
                    presentation: .headless, timeout: timeout),
                launchIfNeeded: !options.noLaunch)
        }
    }

    /// `kernova open <vm>` — put the guest's display in front of the user.
    public struct Open: ParsableCommand {
        /// What `kernova open --help` says.
        ///
        /// The one verb here that deliberately surfaces something: it is what
        /// somebody at the machine types when they want to see the guest.
        public static let configuration = CommandConfiguration(
            commandName: "open",
            abstract: "Bring a running guest's display to the front.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.")
        public var vm: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Surfaces the VM's display.
        public func run() throws {
            try CommandConnection.perform(
                .open(try SelectorParsing.selector(from: vm, forcingID: options.id)),
                launchIfNeeded: !options.noLaunch)
        }
    }
}
