import Cocoa
import CoreServices
import KernovaCommandModel
import KernovaCore

/// `attach <USB accessory or list of them> to <virtual machine>`
///
/// An accessory a guest already holds is the core's to refuse, which names
/// the VM holding it.
@objc(VMAttachScriptCommand)
final class VMAttachScriptCommand: VMScriptCommand {
    /// The Cocoa key of `attach`'s `to`, as the dictionary declares it.
    nonisolated private static let targetKey = "Target"

    override func work(on gateway: VMScriptingGateway) -> VMScriptingGateway.Work? {
        guard let accessories = gateway.usbAccessories(addressedBy: self, unnamed: "Name the USB accessory to attach.")
        else { return nil }
        guard let vm = gateway.virtualMachine(namedBy: self, argument: Self.targetKey, purpose: "to attach to")
        else { return nil }
        let registryIDs = accessories.map(\.registryID)
        return {
            try await gateway.attach(registryIDs, to: vm)
            return nil
        }
    }
}

/// `detach <USB accessory or list of them>`
///
/// It addresses accessories of a VM, each held by that VM's guest, so it
/// takes an accessory back off the guest holding it by construction.
@objc(VMDetachScriptCommand)
final class VMDetachScriptCommand: VMScriptCommand {
    override func work(on gateway: VMScriptingGateway) -> VMScriptingGateway.Work? {
        guard let accessories = gateway.usbAccessories(addressedBy: self, unnamed: "Name the USB accessory to detach.")
        else { return nil }
        var attachments: [VMUSBAttachment] = []
        for accessory in accessories {
            guard case .attached(let attachment) = accessory.place else {
                let name = "\u{201C}\(accessory.name)\u{201D}"
                refuse(CommandError.invalidArgument("\(name) is attached to no virtual machine."))
                return nil
            }
            attachments.append(attachment)
        }
        return {
            try await gateway.detach(attachments)
            return nil
        }
    }
}
