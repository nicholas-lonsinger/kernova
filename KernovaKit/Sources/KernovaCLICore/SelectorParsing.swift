import Foundation
import KernovaCommandModel

/// How the tool turns a typed virtual-machine argument into a selector.
enum SelectorParsing {
    /// The selector `text` names.
    ///
    /// Without `--id` this is ``VMSelector/idOrName(_:)``, and the app decides:
    /// text that parses as an identifier *and* names a VM is read as one,
    /// anything else as a name. `--id` refuses text that is not an identifier
    /// rather than searching by name.
    static func selector(from text: String, forcingID: Bool) throws -> VMSelector {
        guard forcingID else { return .idOrName(text) }
        guard let id = UUID(uuidString: text) else {
            throw CLIFailure(.usage, "\u{201C}\(text)\u{201D} is not a virtual machine identifier.")
        }
        return .id(id)
    }
}
