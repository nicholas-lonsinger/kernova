import ArgumentParser
import Foundation
import KernovaKit

extension KernovaCommand {
    /// `kernova usb` — the host USB accessories a running guest can hold.
    public struct USB: ParsableCommand {
        /// What `kernova usb --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "usb",
            abstract: "Work with the USB accessories a virtual machine's guest holds.",
            discussion: "An accessory is offered to Kernova by you, in macOS's Virtual Machine "
                + "Accessories menu extra, and only what you offered can be passed through. "
                + "Neither identifier `list`, `attach` and `detach` use survives a replug or a "
                + "restart, so each comes from a listing rather than from anything you stored; "
                + "the key `rules` prints does survive, which is what makes an accessory that is "
                + "not plugged in something you can still name.",
            subcommands: [List.self, Attach.self, Detach.self, Rules.self, Forget.self])

        /// Creates the parent command; a bare `kernova usb` prints this help.
        public init() {}
    }
}

extension KernovaCommand.USB {
    /// `kernova usb list [<vm>]` — a guest's accessories, or the free ones.
    public struct List: VerbCommand {
        /// What `kernova usb list --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List USB accessories.",
            discussion: "Named a virtual machine, this lists what its guest is holding, each "
                + "with the device identifier `usb detach` takes back. Named none, it lists the "
                + "accessories no guest holds, each with the accessory identifier `usb attach` "
                + "takes back.")

        /// Which virtual machine, by name or identifier; omitted for the
        /// accessories no guest holds.
        @Argument(
            help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String?

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// The request this command line stands for.
        public func verb() throws -> VMCommandRequest.Verb {
            guard let vm else { return .availableUSBAccessories }
            return .usbAccessories(try SelectorParsing.selector(from: vm, forcingID: options.id))
        }

        /// Reads the accessories and writes them.
        public func run() throws {
            let answered = try answer()
            guard case .usbAccessories(let accessories) = answered else {
                throw answered.unexpectedAnswer
            }
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(accessories)
                    : TableRenderer.render(accessories, quiet: options.quiet))
        }
    }

    /// `kernova usb attach <vm> <accessory>` — hand an accessory to a guest.
    public struct Attach: VerbCommand {
        /// What `kernova usb attach --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "attach",
            abstract: "Pass a USB accessory through to a running guest.",
            discussion: "The guest has to be running: a passthrough accessory is held by the "
                + "virtual machine in memory, and nothing about it is written to the bundle.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// The accessory to hand over, as `usb list` prints it.
        @Argument(
            help: "The accessory identifier, as `usb list` prints it.",
            completion: CompletionSource.availableUSBAccessory)
        public var accessory: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// The request this command line stands for.
        ///
        /// - Throws: ``CLIFailure`` with ``CLIExitCode/usage`` when `accessory`
        ///   is not an identifier a listing printed.
        public func verb() throws -> VMCommandRequest.Verb {
            guard let registryID = UInt64(accessory) else {
                throw CLIFailure(
                    .usage, "\u{201C}\(accessory)\u{201D} is not an accessory identifier.")
            }
            return .editUSBAccessory(
                try SelectorParsing.selector(from: vm, forcingID: options.id),
                .attach(accessory: registryID))
        }

        /// Hands the accessory over.
        public func run() throws {
            try perform()
        }
    }

    /// `kernova usb detach <vm> <device>` — take an accessory back.
    public struct Detach: VerbCommand, VMScopedCommandLine {
        /// What `kernova usb detach --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "detach",
            abstract: "Take a USB accessory back off a running guest.",
            discussion: "The accessory returns to the list `usb list` prints with no virtual "
                + "machine named, ready to hand to another guest.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// The attachment to take back, as `usb list <vm>` prints it.
        @Argument(
            help: "The device identifier, as `usb list <vm>` prints it.",
            completion: CompletionSource.usbAccessory)
        public var device: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// The request this command line stands for.
        ///
        /// - Throws: ``CLIFailure`` with ``CLIExitCode/usage`` when `device` is
        ///   not an identifier a listing printed.
        public func verb() throws -> VMCommandRequest.Verb {
            guard let deviceID = UUID(uuidString: device) else {
                throw CLIFailure(
                    .usage, "\u{201C}\(device)\u{201D} is not a device identifier.")
            }
            return .editUSBAccessory(
                try SelectorParsing.selector(from: vm, forcingID: options.id),
                .detach(device: deviceID))
        }

        /// Takes the accessory back.
        public func run() throws {
            try perform()
        }
    }

    /// `kernova usb rules [<vm>]` — what each guest takes back on its own.
    public struct Rules: VerbCommand {
        /// What `kernova usb rules --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "rules",
            abstract: "List the USB accessories virtual machines take back automatically.",
            discussion: "Passing an accessory through to a guest is what creates one of these, "
                + "and taking it back by hand is what ends it. Each row names the key `usb "
                + "forget` takes back — the accessory itself is usually not plugged in, which "
                + "is why it is named by a key rather than by an identifier from a listing.")

        /// Which virtual machine, by name or identifier; omitted for every one.
        @Argument(
            help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String?

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// The request this command line stands for.
        public func verb() throws -> VMCommandRequest.Verb {
            .usbPairings(try vm.map { try SelectorParsing.selector(from: $0, forcingID: options.id) })
        }

        /// Reads the rules and writes them.
        public func run() throws {
            let answered = try answer()
            guard case .usbPairings(let pairings) = answered else {
                throw answered.unexpectedAnswer
            }
            Console.out(
                options.format == .json
                    ? try JSONRenderer.render(pairings)
                    : TableRenderer.render(pairings, quiet: options.quiet))
        }
    }

    /// `kernova usb forget <vm> <key>` — stop a guest taking one back.
    public struct Forget: VerbCommand, VMScopedCommandLine {
        /// What `kernova usb forget --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "forget",
            abstract: "Stop a virtual machine taking a USB accessory back automatically.",
            discussion: "The accessory stays with this Mac next time it is plugged in. Passing "
                + "it through again remembers it again.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.", completion: CompletionSource.vm)
        public var vm: String

        /// The accessory to forget, as `usb rules` prints it.
        @Argument(
            help: "The accessory key, as `usb rules` prints it.",
            completion: CompletionSource.usbPairingKey)
        public var key: String

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// The request this command line stands for.
        public func verb() throws -> VMCommandRequest.Verb {
            .forgetUSBPairing(
                try SelectorParsing.selector(from: vm, forcingID: options.id), key: key)
        }

        /// Forgets the accessory.
        public func run() throws {
            try perform()
        }
    }
}
