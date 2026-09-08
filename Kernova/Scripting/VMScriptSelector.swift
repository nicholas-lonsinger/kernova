import Cocoa
import KernovaKit

/// How one Apple event addresses the VMs its verb runs on.
///
/// A specifier that names a VM on its own — by name or by identifier, as an
/// element of the application — is read *unevaluated*: the name reaches the
/// core as ``VMSelector/name(_:)``, so a name several VMs answer to is refused
/// by the core with the candidates listed, rather than resolving to whichever
/// one the container handed back first. Everything else a specifier can say —
/// an index, a range, `every`, a `whose` test — only Cocoa can read, so those
/// are evaluated and each VM addressed by identifier.
enum VMScriptSelector {
    /// The VMs `parameter` addresses: one specifier, or a list of them, each
    /// read as ``selectors(addressing:)-swift.type.method`` reads one.
    ///
    /// - Throws: ``VMScriptEvaluationFailure`` as one specifier's read does, and
    ///   ``CommandError/invalidArgument(_:)`` for a list item that is not a
    ///   specifier.
    static func selectors(addressing parameter: Any) throws -> [VMSelector] {
        if let specifier = parameter as? NSScriptObjectSpecifier {
            return try selectors(addressing: specifier)
        }
        guard let list = parameter as? [Any] else {
            throw CommandError.invalidArgument("Name a virtual machine, or a list of them.")
        }
        return try list.enumerated().flatMap { index, item in
            guard let specifier = item as? NSScriptObjectSpecifier else {
                throw CommandError.invalidArgument(
                    "A list here names virtual machines only; item \(index + 1) is not one.")
            }
            return try selectors(addressing: specifier)
        }
    }

    /// The VMs `specifier` addresses, in the order it named them.
    ///
    /// Empty when the specifier evaluated to nothing — `every virtual machine`
    /// of an empty library, a `whose` test nothing satisfies — which is a verb
    /// with nothing to do rather than a refusal. Called only once the library
    /// has landed: an evaluation before that reads an empty library as if it
    /// were the whole one.
    ///
    /// - Throws: ``VMScriptEvaluationFailure`` when Cocoa could not evaluate
    ///   the specifier, or evaluated it to something that is not a VM.
    static func selectors(addressing specifier: NSScriptObjectSpecifier) throws -> [VMSelector] {
        if let named = selector(naming: specifier) {
            return [named]
        }
        guard let evaluated = specifier.objectsByEvaluatingSpecifier else {
            throw VMScriptEvaluationFailure(specifier)
        }
        return try selectors(resolvedTo: evaluated, by: specifier)
    }

    /// The VM `specifier` names by itself, `nil` when reading it takes an
    /// evaluation.
    private static func selector(naming specifier: NSScriptObjectSpecifier) -> VMSelector? {
        // Only the application's own element: a name under any other container
        // (`virtual machine "…" of window 1`) is the evaluation's to refuse.
        guard specifier.container == nil, specifier.key == AppDelegate.virtualMachinesKey
        else { return nil }
        switch specifier {
        case let named as NSNameSpecifier:
            return .name(named.name)
        case let unique as NSUniqueIDSpecifier:
            // A dictionary `id` is text, so anything else came from a script
            // naming an identifier this app never issued: let the evaluation
            // refuse it rather than inventing a selector.
            guard let text = unique.uniqueID as? String, let id = UUID(uuidString: text) else {
                return nil
            }
            return .id(id)
        default:
            return nil
        }
    }

    /// The VMs Cocoa evaluated `specifier` to, each addressed by identifier.
    private static func selectors(
        resolvedTo evaluated: Any, by specifier: NSScriptObjectSpecifier
    ) throws -> [VMSelector] {
        let objects = evaluated as? [Any] ?? [evaluated]
        return try objects.map { object in
            guard let vm = object as? VMScriptObject else {
                // The event named something the dictionary has that is not a
                // VM, which Cocoa's own dispatch answers as an object with no
                // handler for the verb.
                throw VMScriptEvaluationFailure(
                    number: Int(errAEEventNotHandled), offendingObject: specifier.descriptor)
            }
            return vm.selector
        }
    }
}

/// A specifier the verb could not run on, in the terms a script error carries.
struct VMScriptEvaluationFailure: Error {
    /// The Apple event error number.
    let number: Int
    /// The specifier at fault, for the script to name in "Can't get …".
    let offendingObject: NSAppleEventDescriptor?

    init(number: Int, offendingObject: NSAppleEventDescriptor?) {
        self.number = number
        self.offendingObject = offendingObject
    }

    /// The failure `specifier`'s last evaluation left on it, as the number
    /// Cocoa's own evaluation reports to a script: an index the container has
    /// no element at is `errAEIllegalIndex`, anything else `errAENoSuchObject`.
    init(_ specifier: NSScriptObjectSpecifier) {
        let failed = specifier.evaluationError ?? specifier
        self.init(
            number: failed.evaluationErrorNumber == NSInvalidIndexSpecifierError
                ? Int(errAEIllegalIndex) : Int(errAENoSuchObject),
            offendingObject: failed.descriptor)
    }

    /// Records the failure as what `command` answers with.
    func record(on command: NSScriptCommand) {
        command.scriptErrorNumber = number
        command.scriptErrorOffendingObjectDescriptor = offendingObject
    }
}
