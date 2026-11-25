import Cocoa
import KernovaCommandModel
import KernovaCore

/// One of the dictionary's elements, as a verb's refusal names it: the key a
/// reference to one is under, and its class's name and plural.
struct VMScriptElement {
    let key: String
    let singular: String
    let plural: String

    static let virtualMachine = Self(
        key: VMScriptingRoot.virtualMachinesKey, singular: "virtual machine", plural: "virtual machines")
    static let snapshot = Self(key: VMScriptObject.snapshotsKey, singular: "snapshot", plural: "snapshots")
    static let setting = Self(key: VMScriptObject.settingsKey, singular: "setting", plural: "settings")
    static let sharedDirectory = Self(
        key: VMScriptObject.sharedDirectoriesKey, singular: "shared directory", plural: "shared directories")
    static let usbAccessory = Self(
        key: VMScriptObject.usbAccessoriesKey, singular: "USB accessory", plural: "USB accessories")
    static let rememberedUSBAccessory = Self(
        key: VMScriptObject.rememberedUSBAccessoriesKey, singular: "remembered USB accessory",
        plural: "remembered USB accessories")
}

/// How one Apple event addresses the VMs, the smart group or folder, the
/// snapshots, the settings, the shared directories or the USB accessories its
/// verb runs on.
///
/// A specifier that names a VM on its own — by name or by identifier, as an
/// element of the application — is read *unevaluated*: the name reaches the
/// core as ``VMSelector/name(_:)``. Everything else a specifier can say — an
/// index, a range, `every`, a `whose` test — only Cocoa can read, so those are
/// evaluated, a name in them resolving as that name alone does
/// (``VMScriptContainer``), and each VM addressed by identifier.
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
            let listed = try specifiers(in: parameter, naming: .virtualMachine)
            return (try listed.flatMap { try virtualMachines(addressing: $0, in: nil).selectors }, true)
        }
        if containers == nil, let named = selector(naming: specifier) {
            return ([named], false)
        }
        let evaluated = try objects(evaluating: specifier, in: containers, as: VMScriptObject.self)
        return (evaluated.elements.map(\.selector), evaluated.isList)
    }

    /// What a lifecycle command's direct parameter addresses: virtual
    /// machines, or one smart group or folder.
    enum LifecycleSubject {
        /// The VMs, and whether they are addressed as a list, as
        /// ``virtualMachines(addressing:in:)`` reads them.
        case virtualMachines([VMSelector], isList: Bool)
        /// The group, which the command's group action takes as a whole.
        case group(VMGroupReference)
    }

    /// What `parameter` addresses for a lifecycle command: one reference
    /// Cocoa evaluates to a single smart group or folder is that group, and
    /// anything else is the VMs ``virtualMachines(addressing:in:)`` reads.
    ///
    /// A group is never one of several: a list of references holds VMs only,
    /// as ``specifiers(in:naming:)`` refuses anything else.
    ///
    /// - Throws: As ``selectors(addressing:in:)`` does, and
    ///   ``CommandError/invalidArgument(_:)`` for a reference evaluating to
    ///   several groups.
    static func lifecycleSubject(addressing parameter: Any) throws -> LifecycleSubject {
        guard let specifier = parameter as? NSScriptObjectSpecifier, selector(naming: specifier) == nil else {
            let addressed = try virtualMachines(addressing: parameter)
            return .virtualMachines(addressed.selectors, isList: addressed.isList)
        }
        let evaluated = try evaluate(specifier, in: nil)
        let groups = evaluated.items.compactMap { $0 as? VMGroupScriptObject }
        guard !groups.isEmpty else {
            return .virtualMachines(
                try elements(of: evaluated.items, as: VMScriptObject.self).map(\.selector), isList: evaluated.isList)
        }
        guard evaluated.items.count == 1, let group = groups.first else {
            throw CommandError.invalidArgument(
                "Name one smart group or folder at a time; this names \(evaluated.items.count).")
        }
        return .group(group.reference)
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
        try objects(addressing: parameter, in: containers, .snapshot, as: VMSnapshotScriptObject.self).elements
            .map(\.address)
    }

    /// The settings `parameter` addresses — one specifier, or a list of them
    /// — each evaluated, in the order it named them, and whether it addresses
    /// them as a list, as ``virtualMachines(addressing:in:)`` answers it.
    ///
    /// Evaluated whole, as ``snapshots(addressing:in:)`` reads a snapshot.
    ///
    /// - Throws: As ``selectors(addressing:in:)`` does.
    static func settings(addressing parameter: Any) throws -> (settings: [VMSettingAddress], isList: Bool) {
        let evaluated = try objects(addressing: parameter, in: nil, .setting, as: VMSettingScriptObject.self)
        return (evaluated.elements.map(\.address), evaluated.isList)
    }

    /// The shared directories `parameter` addresses, evaluated as
    /// ``snapshots(addressing:in:)`` reads a snapshot.
    ///
    /// - Throws: As ``selectors(addressing:in:)`` does.
    static func sharedDirectories(
        addressing parameter: Any, in containers: Any? = nil
    ) throws -> [VMSharedDirectoryAddress] {
        try objects(addressing: parameter, in: containers, .sharedDirectory, as: VMSharedDirectoryScriptObject.self)
            .elements.map(\.address)
    }

    /// The USB accessories `parameter` addresses, each where it is — the
    /// application's, available to attach, or a VM's, attached to it —
    /// evaluated as ``snapshots(addressing:in:)`` reads a snapshot.
    ///
    /// - Throws: As ``selectors(addressing:in:)`` does.
    static func usbAccessories(addressing parameter: Any) throws -> [VMUSBAccessoryScriptObject] {
        try objects(addressing: parameter, in: nil, .usbAccessory, as: VMUSBAccessoryScriptObject.self).elements
    }

    /// The remembered USB accessories `parameter` addresses, evaluated as
    /// ``snapshots(addressing:in:)`` reads a snapshot.
    ///
    /// - Throws: As ``selectors(addressing:in:)`` does.
    static func rememberedUSBAccessories(
        addressing parameter: Any, in containers: Any? = nil
    ) throws -> [VMRememberedUSBAccessoryAddress] {
        try objects(
            addressing: parameter, in: containers, .rememberedUSBAccessory,
            as: VMRememberedUSBAccessoryScriptObject.self
        ).elements.map(\.address)
    }

    /// The `Element`s `parameter` addresses — one specifier, or a list of
    /// references to `element` — each evaluated, in the order it named them,
    /// and whether it addresses them as a list, as
    /// ``virtualMachines(addressing:in:)`` answers it.
    private static func objects<Element>(
        addressing parameter: Any, in containers: Any?, _ element: VMScriptElement, as type: Element.Type
    ) throws -> (elements: [Element], isList: Bool) {
        guard let specifier = parameter as? NSScriptObjectSpecifier else {
            let listed = try specifiers(in: parameter, naming: element)
            return (try listed.flatMap { try objects(evaluating: $0, in: nil, as: type).elements }, true)
        }
        return try objects(evaluating: specifier, in: containers, as: type)
    }

    /// The element key `parameter` addresses: its specifier's, or for a list,
    /// its first item's — `nil` for a parameter that holds no specifier
    /// first.
    static func key(addressedBy parameter: Any) -> String? {
        let first = parameter as? NSScriptObjectSpecifier ?? (parameter as? [Any])?.first as? NSScriptObjectSpecifier
        return first?.key
    }

    /// `parameter` as the specifiers it holds: one, or a list of references to
    /// `element`.
    ///
    /// A list is refused whole for one item that is something else, so a verb
    /// runs on all of it or none.
    ///
    /// - Throws: ``CommandError/invalidArgument(_:)`` for anything else, or a
    ///   list item that is not such a reference.
    private static func specifiers(
        in parameter: Any, naming element: VMScriptElement
    ) throws -> [NSScriptObjectSpecifier] {
        if let specifier = parameter as? NSScriptObjectSpecifier { return [specifier] }
        guard let list = parameter as? [Any] else {
            throw CommandError.invalidArgument("Name a \(element.singular), or a list of them.")
        }
        return try list.enumerated().map { index, item in
            guard let specifier = item as? NSScriptObjectSpecifier, specifier.key == element.key else {
                throw CommandError.invalidArgument(
                    "A list here names \(element.plural) only; item \(index + 1) is not one.")
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
        evaluating specifier: NSScriptObjectSpecifier, in containers: Any?, as type: Element.Type
    ) throws -> (elements: [Element], isList: Bool) {
        let evaluated = try evaluate(specifier, in: containers)
        return (try elements(of: evaluated.items, as: type), evaluated.isList)
    }

    /// What `specifier` evaluates to — against `containers`, or else its own
    /// container chain — read through every level of list, in order, and
    /// whether Cocoa answered a list.
    ///
    /// - Throws: ``VMScriptEvaluationFailure`` when Cocoa could not evaluate
    ///   the specifier.
    private static func evaluate(
        _ specifier: NSScriptObjectSpecifier, in containers: Any?
    ) throws -> (items: [Any], isList: Bool) {
        let evaluated = containers.map { specifier.objectsByEvaluating(withContainers: $0) }
        guard let evaluated = evaluated ?? specifier.objectsByEvaluatingSpecifier else {
            throw VMScriptEvaluationFailure(specifier)
        }
        func items(_ value: Any) -> [Any] { (value as? [Any])?.flatMap(items) ?? [value] }
        return (items(evaluated), evaluated is [Any])
    }

    /// `items`, each of it an `Element`.
    ///
    /// - Throws: ``VMScriptEvaluationFailure`` for an item that is not one.
    private static func elements<Element>(of items: [Any], as _: Element.Type) throws -> [Element] {
        try items.map { object in
            guard let element = object as? Element else {
                // The event named something else the dictionary has, which
                // Cocoa's own dispatch answers as an object with no handler
                // for the verb.
                throw VMScriptEvaluationFailure(number: Int(errAEEventNotHandled))
            }
            return element
        }
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
    ///
    /// A refusal the evaluation recorded in words of its own — the core's, for
    /// a name it resolves — keeps its number, as Cocoa's own `get` of the same
    /// reference answers it.
    func record(on command: NSScriptCommand, addressing addressed: Any?) {
        if command.scriptErrorString == nil { command.scriptErrorNumber = number }
        command.scriptErrorOffendingObjectDescriptor = addressed.flatMap {
            VMScriptSelector.specifierAtFault(in: $0)?.descriptor
        }
    }
}
