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
                + "Neither identifier below survives a replug or a restart, so each comes from a "
                + "listing rather than from anything you stored.",
            subcommands: [List.self, Attach.self, Detach.self])

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
}
