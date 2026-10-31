import ArgumentParser
import Foundation
import KernovaCommandModel

extension KernovaCommand {
    /// How `kernova stop` reaches a powered-off guest.
    enum StopMethod: String, EnumerableFlag {
        /// Ask the guest to shut itself down.
        case graceful
        /// Terminate the guest immediately, losing unsaved state.
        case force

        /// The wire disposition this method names.
        var disposition: StopDisposition {
            switch self {
            case .graceful: .graceful
            case .force: .force
            }
        }

        /// What each flag's help says.
        static func help(for value: StopMethod) -> ArgumentHelp? {
            switch value {
            case .graceful: "Ask the guest to shut down (the default)."
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
                + "denies turning terminal echo off, and such a start exits 5.\n\nA virtual "
                + "machine with the same machine ID as one that is active is refused. With Offer "
                + "to start duplicate machine IDs anyway on in Kernova\u{2019}s Settings, --yes "
                + "starts it anyway.\n\nA virtual machine whose MAC address another active one "
                + "uses on the same network is refused, printing the commands that change its "
                + "network first where it can take them.\n\nWith --smart-group or --folder, starts each "
                + "virtual machine in the group that can be started or resumed, one after another, "
                + "and prints a line for each. One whose start would ask something — a "
                + "confirmation or its account's password — or would begin its guest setup is skipped, and a group start exits 10 when it leaves any it "
                + "could act on undone.")

        /// Which virtual machine, by name or identifier; `nil` for a group.
        @Argument(
            help: "The virtual machine's name or identifier, unless a group is named instead.",
            completion: CompletionSource.vm)
        var vm: String?

        /// The group whose virtual machines the verb acts on instead.
        @OptionGroup var groups: GroupTargetOptions

        /// Cold-boot a stopped macOS guest into macOS Recovery.
        @Flag(name: .long, help: "Cold-boot a macOS guest into Recovery.")
        var recovery = false

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// Refuses a line naming both a virtual machine and a group, or
        /// neither, and a group start given a flag for one virtual machine.
        func validate() throws {
            try groups.validateTarget(
                vm: vm,
                singleVMFlags: [
                    recovery ? "--recovery" : nil,
                    options.yes ? "--yes" : nil,
                ].compactMap(\.self))
        }

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            if let group = groups.target { return .groupAction(.start, group: group) }
            return .start(
                try SelectorParsing.selector(from: vm ?? "", forcingID: options.id),
                recovery: recovery, consent: options.consent)
        }

        /// Starts the VM, or every one in the group.
        func run() throws {
            if groups.target != nil { try performGroupAction() } else { try perform() }
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
                + "as it is when the guest is still up; --force is the escalation from there. "
                + "A paused guest can\u{2019}t receive the request, so its stop is refused, "
                + "naming `kernova resume` as the step to take first."
                + "\n\nWith --smart-group or --folder, asks each running guest in the group to shut "
                + "down, one after another, and prints a line for each. A paused or suspended "
                + "virtual machine is skipped, since a paused one takes a resume first and a "
                + "suspended one\u{2019}s stop discards its saved state, and a group stop exits 10 "
                + "when it leaves any it could act on undone.")

        /// Which virtual machine, by name or identifier; `nil` for a group.
        @Argument(
            help: "The virtual machine's name or identifier, unless a group is named instead.",
            completion: CompletionSource.vm)
        var vm: String?

        /// The group whose virtual machines the verb acts on instead.
        @OptionGroup var groups: GroupTargetOptions

        /// How the stop should reach the guest.
        @Flag(exclusivity: .exclusive)
        var method: StopMethod = .graceful

        /// How long to wait for the guest to power off, or `nil` to return
        /// without waiting.
        @Option(name: .long, help: "Seconds to wait for the guest to power off before giving up.")
        var timeout: Double?

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// Refuses a deadline that names no wait, a line naming both a
        /// virtual machine and a group or neither, and a group stop given a
        /// flag for one virtual machine.
        func validate() throws {
            try TimeoutOption.validate(timeout)
            try groups.validateTarget(
                vm: vm,
                singleVMFlags: [
                    method == .force ? "--force" : nil,
                    timeout != nil ? "--timeout" : nil, options.yes ? "--yes" : nil,
                ].compactMap(\.self))
        }

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            if let group = groups.target { return .groupAction(.stop, group: group) }
            return .stop(
                try SelectorParsing.selector(from: vm ?? "", forcingID: options.id),
                disposition: method.disposition, consent: options.consent, timeout: timeout)
        }

        /// Stops the VM, or every running one in the group.
        func run() throws {
            if groups.target != nil { try performGroupAction() } else { try perform() }
        }
    }

    /// `kernova suspend <vm>` — save the session to the bundle.
    struct Suspend: VerbCommand {
        /// What `kernova suspend --help` says.
        static let configuration = CommandConfiguration(
            commandName: "suspend",
            abstract: "Save a running guest's session and stop it.",
            discussion: "With --smart-group or --folder, suspends each running or paused guest in the "
                + "group, one after another, and prints a line for each; a group suspend exits 10 "
                + "when it leaves any it could act on undone.")

        /// Which virtual machine, by name or identifier; `nil` for a group.
        @Argument(
            help: "The virtual machine's name or identifier, unless a group is named instead.",
            completion: CompletionSource.vm)
        var vm: String?

        /// The group whose virtual machines the verb acts on instead.
        @OptionGroup var groups: GroupTargetOptions

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// Refuses a line naming both a virtual machine and a group, or
        /// neither.
        func validate() throws {
            try groups.validateTarget(vm: vm, singleVMFlags: options.yes ? ["--yes"] : [])
        }

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            if let group = groups.target { return .groupAction(.suspend, group: group) }
            return .suspend(
                try SelectorParsing.selector(from: vm ?? "", forcingID: options.id),
                consent: options.consent)
        }

        /// Suspends the VM, or every running one in the group.
        func run() throws {
            if groups.target != nil { try performGroupAction() } else { try perform() }
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

    /// `kernova resume <vm>` — let a paused or suspended guest run again.
    struct Resume: VerbCommand {
        /// What `kernova resume --help` says.
        static let configuration = CommandConfiguration(
            commandName: "resume",
            abstract: "Resume a paused guest, or read a suspended session back.",
            discussion: "Nothing is brought in front of you; `kernova open` is the verb that puts "
                + "a display there.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        var vm: String

        /// The options every subcommand carries.
        @OptionGroup var options: GlobalOptions

        /// The request this command line stands for.
        func verb() throws -> VMCommandRequest.Verb {
            .resume(
                try SelectorParsing.selector(from: vm, forcingID: options.id),
                consent: options.consent)
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
                + "guest still up when it expires exits 7 and is not started again. A virtual "
                + "machine with the same machine ID as one that is active is refused before the "
                + "guest goes down, unless --yes starts it anyway where Kernova's Settings allow. "
                + "One whose MAC address another active one uses on the same network is refused "
                + "there too, printing the command that moves it to a network of its own where it "
                + "can take it.")

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
                try SelectorParsing.selector(from: vm, forcingID: options.id), timeout: timeout,
                consent: options.consent)
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
