import Cocoa
import KernovaCommandModel
import KernovaCore

/// How one Apple event addresses the VMs or snapshots its verb runs on.
///
/// A specifier that names a VM on its own — by name or by identifier, as an
/// element of the application — is read *unevaluated*: the name reaches the
/// core as ``VMSelector/name(_:)``, so a name several VMs answer to is refused
/// by the core with the candidates listed, rather than resolving to whichever
/// one the container handed back first. Everything else a specifier can say —
/// an index, a range, `every`, a `whose` test — only Cocoa can read, so those
/// are evaluated and each VM addressed by identifier.
///
/// What an event addresses is its direct parameter: one specifier, or a list
/// of them. A Standard Suite `delete` or `duplicate` evaluates its one
/// specifier's container apart from it (`NSDeleteCommand.keySpecifier`) and
/// passes it as `containers`, which that specifier is evaluated against.
enum VMScriptSelector {
    /// The VMs `parameter` addresses, in the order it named them.
    ///
    /// - Throws: ``VMScriptEvaluationFailure`` when Cocoa could not evaluate a
    ///   specifier, or evaluated it to something that is not a VM, and
    ///   ``CommandError/invalidArgument(_:)`` for a list item that is not a
    ///   reference to a VM.
    static func selectors(addressing parameter: Any, in containers: Any? = nil) throws -> [VMSelector] {
        try virtualMachines(addressing: parameter, in: containers).selectors
    }

    /// The VMs `parameter` addresses, as ``selectors(addressing:in:)`` reads
    /// them, and whether it addresses them as a list — a list of references,
    /// or one reference Cocoa evaluated to a list, such as `every virtual
    /// machine whose …` — which is what a verb answering one result for each
    /// answers as a list.
    ///
    /// Empty when a specifier evaluated to nothing — `every virtual machine`
    /// of an empty library, a `whose` test nothing satisfies — which is a verb
    /// with nothing to do rather than a refusal. Called only once the library
    /// has landed: an evaluation before that reads an empty library as if it
    /// were the whole one.
    ///
    /// - Throws: As ``selectors(addressing:in:)`` does.
    static func virtualMachines(
        addressing parameter: Any, in containers: Any? = nil
    ) throws -> (selectors: [VMSelector], isList: Bool) {
        guard let specifier = parameter as? NSScriptObjectSpecifier else {
            let listed = try specifiers(
                in: parameter, naming: "virtual machine", key: VMScriptingRoot.virtualMachinesKey)
            return (try listed.flatMap { try virtualMachines(addressing: $0, in: nil).selectors }, true)
        }
        if containers == nil, let named = selector(naming: specifier) {
            return ([named], false)
        }
        let evaluated = try objects(evaluating: specifier, in: containers, as: VMScriptObject.self)
        return (evaluated.elements.map(\.selector), evaluated.isList)
    }

    /// The snapshots `parameter` addresses — one specifier, or a list of them
    /// — each evaluated, in the order it named them.
    ///
    /// Evaluated whole, VM included: a snapshot's VM container reached by name
    /// resolves through the core as a VM a verb names does
    /// (`valueInVirtualMachinesWithName:`).
    ///
    /// - Throws: As ``selectors(addressing:in:)`` does.
    static func snapshots(addressing parameter: Any, in containers: Any? = nil) throws -> [VMSnapshotAddress] {
        guard let specifier = parameter as? NSScriptObjectSpecifier else {
            let listed = try specifiers(in: parameter, naming: "snapshot", key: VMScriptObject.snapshotsKey)
            return try listed.flatMap { try snapshots(addressing: $0, in: nil) }
        }
        return try objects(evaluating: specifier, in: containers, as: VMSnapshotScriptObject.self).elements
            .map(\.address)
    }

    /// The element key `parameter` addresses: its specifier's, or for a list,
    /// its first item's — `nil` for a parameter that holds no specifier
    /// first.
    static func key(addressedBy parameter: Any) -> String? {
        let first = parameter as? NSScriptObjectSpecifier ?? (parameter as? [Any])?.first as? NSScriptObjectSpecifier
        return first?.key
    }

    /// `parameter` as the specifiers it holds: one, or a list of references to
    /// the element a `noun` is under `key`.
    ///
    /// A list is refused whole for one item that is something else, so a verb
    /// runs on all of it or none.
    ///
    /// - Throws: ``CommandError/invalidArgument(_:)`` for anything else, or a
    ///   list item that is not such a reference.
    private static func specifiers(
        in parameter: Any, naming noun: String, key: String
    ) throws -> [NSScriptObjectSpecifier] {
        if let specifier = parameter as? NSScriptObjectSpecifier { return [specifier] }
        guard let list = parameter as? [Any] else {
            throw CommandError.invalidArgument("Name a \(noun), or a list of them.")
        }
        return try list.enumerated().map { index, item in
            guard let specifier = item as? NSScriptObjectSpecifier, specifier.key == key else {
                throw CommandError.invalidArgument("A list here names \(noun)s only; item \(index + 1) is not one.")
            }
            return specifier
        }
    }

    /// The VM `specifier` names by itself, `nil` when reading it takes an
    /// evaluation.
    private static func selector(naming specifier: NSScriptObjectSpecifier) -> VMSelector? {
        // Only the application's own element: a name under any other container
        // (`virtual machine "…" of window 1`) is the evaluation's to refuse.
        guard specifier.container == nil, specifier.key == VMScriptingRoot.virtualMachinesKey
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

    /// What `specifier` evaluates to — against `containers`, or else its own
    /// container chain — each of it an `Element`, in order, and whether Cocoa
    /// answered a list.
    ///
    /// A list Cocoa answers for each of several containers — `every snapshot
    /// of every virtual machine` — is read through.
    ///
    /// - Throws: ``VMScriptEvaluationFailure`` when Cocoa could not evaluate
    ///   the specifier, or evaluated it to something that is not an `Element`.
    private static func objects<Element>(
        evaluating specifier: NSScriptObjectSpecifier, in containers: Any?, as _: Element.Type
    ) throws -> (elements: [Element], isList: Bool) {
        let evaluated = containers.map { specifier.objectsByEvaluating(withContainers: $0) }
        guard let evaluated = evaluated ?? specifier.objectsByEvaluatingSpecifier else {
            throw VMScriptEvaluationFailure(specifier)
        }
        func items(_ value: Any) -> [Any] { (value as? [Any])?.flatMap(items) ?? [value] }
        let elements = try items(evaluated).map { object in
            guard let element = object as? Element else {
                // The event named something else the dictionary has, which
                // Cocoa's own dispatch answers as an object with no handler
                // for the verb.
                throw VMScriptEvaluationFailure(number: Int(errAEEventNotHandled))
            }
            return element
        }
        return (elements, evaluated is [Any])
    }

    /// The specifier at fault in what an event addressed — one specifier, or a
    /// list of them — which is what a script names in "Can't get …": the link
    /// in the container chain whose own evaluation failed, and for a list the
    /// item that carries one.
    static func specifierAtFault(in parameter: Any) -> NSScriptObjectSpecifier? {
        if let specifier = parameter as? NSScriptObjectSpecifier {
            return specifier.evaluationError ?? specifier
        }
        guard let list = parameter as? [Any] else { return nil }
        let failed = list.lazy
            .compactMap { $0 as? NSScriptObjectSpecifier }
            .first { $0.evaluationErrorNumber != 0 }
        return failed?.evaluationError ?? failed
    }
}

/// Why a verb could not run on what the event addressed, in the terms a script
/// error carries.
///
/// It carries the number alone: an `Error` is `Sendable` and an Apple event
/// descriptor is not, so the object at fault is named at the point that records
/// the failure, which holds the specifier the descriptor comes from.
struct VMScriptEvaluationFailure: Error {
    /// The Apple event error number.
    let number: Int

    init(number: Int) {
        self.number = number
    }

    /// The failure `specifier`'s last evaluation left on it, as the number
    /// Cocoa's own evaluation reports to a script: an index the container has
    /// no element at is `errAEIllegalIndex`, anything else `errAENoSuchObject`.
    init(_ specifier: NSScriptObjectSpecifier) {
        let failed = specifier.evaluationError ?? specifier
        self.init(
            number: failed.evaluationErrorNumber == NSInvalidIndexSpecifierError
                ? Int(errAEIllegalIndex) : Int(errAENoSuchObject))
    }

    /// Records the failure as what `command` answers with, naming the specifier
    /// at fault in `addressed` — one specifier, or a list of them — as the
    /// object the script could not get.
    func record(on command: NSScriptCommand, addressing addressed: Any?) {
        command.scriptErrorNumber = number
        command.scriptErrorOffendingObjectDescriptor = addressed.flatMap {
            VMScriptSelector.specifierAtFault(in: $0)?.descriptor
        }
    }
}
