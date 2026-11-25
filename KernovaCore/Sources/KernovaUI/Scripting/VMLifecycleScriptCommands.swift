import Cocoa
import CoreServices
import KernovaCommandModel
import KernovaCore
import KernovaLogging

/// The dictionary's `VM stop method` enumeration, in Swift: how `stop` and
/// `restart` take the guest down.
///
/// The cases and codes here and the enumerators in `Kernova.sdef` are two
/// halves of one thing, which is what `KernovaScriptingDefinitionTests` checks.
enum VMScriptStopMethod: CaseIterable {
    case normal
    case anyway
    case force

    // periphery:ignore - never called: an exhaustive switch, so a disposition added stops compiling here
    /// The way of stopping `disposition` names. Exhaustive, so a new
    /// disposition has to be given a term before it compiles.
    init(_ disposition: StopDisposition) {
        switch disposition {
        case .graceful: self = .normal
        case .force: self = .force
        case .anyway: self = .anyway
        }
    }

    /// The method an Apple event naming `code` asked for, `nil` for a code from
    /// no vocabulary this app writes.
    init?(code: FourCharCode) {
        guard let match = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = match
    }

    /// The Apple event code the dictionary gives this case's term.
    var code: FourCharCode {
        switch self {
        case .normal: FourCharCode(scriptingCode: "KmNo")
        case .force: FourCharCode(scriptingCode: "KmFo")
        case .anyway: FourCharCode(scriptingCode: "KmSa")
        }
    }

    /// The phrase a script gives this method in, as the dictionary spells it.
    var phrase: String {
        switch self {
        case .normal: "method normal"
        case .anyway: "method anyway"
        case .force: "method force"
        }
    }

    /// How the core reaches a powered-off guest this way.
    var disposition: StopDisposition {
        switch self {
        case .normal: .graceful
        case .force: .force
        case .anyway: .anyway
        }
    }
}

/// The dictionary's `clone outcome` enumeration, in Swift: what `duplicate`
/// makes of a virtual machine.
///
/// The cases and codes here and the enumerators in `Kernova.sdef` are two
/// halves of one thing, which is what `KernovaScriptingDefinitionTests` checks.
enum VMScriptCloneOutcome: CaseIterable {
    case newMachine
    case exactCopy

    // periphery:ignore - never called: an exhaustive switch, so an outcome added stops compiling here
    /// The term `outcome` is named by. Exhaustive, so a new outcome has to be
    /// given a term before it compiles.
    init(_ outcome: CloneOutcome) {
        switch outcome {
        case .newMachine: self = .newMachine
        case .exactCopy: self = .exactCopy
        }
    }

    /// The outcome an Apple event naming `code` asked for, `nil` for a code
    /// from no vocabulary this app writes.
    init?(code: FourCharCode) {
        guard let match = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = match
    }

    /// The Apple event code the dictionary gives this case's term.
    var code: FourCharCode {
        switch self {
        case .newMachine: FourCharCode(scriptingCode: "KcNm")
        case .exactCopy: FourCharCode(scriptingCode: "KcEx")
        }
    }

    /// The outcome this term names.
    var outcome: CloneOutcome {
        switch self {
        case .newMachine: .newMachine
        case .exactCopy: .exactCopy
        }
    }
}

// MARK: - The shape every Kernova verb takes

/// What every Kernova verb an Apple event can ask for is built out of: take
/// the event over, read what it addressed once the library has landed, run the
/// verb, and answer once it settles.
///
/// Main-actor isolated because everything it touches is: Cocoa creates and
/// executes every script command on the main thread, and the gateway a verb
/// reaches is main-actor state.
@MainActor
class VMScriptCommand: NSScriptCommand {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMScriptCommand")

    /// What a script reads back before the app has a gateway to answer it.
    nonisolated static let notReady = "Kernova is not ready to answer scripts."

    /// The Cocoa key of `waiting`, on every command that takes it.
    nonisolated static let waitingKey = "Waiting"

    /// Takes the event over from Cocoa's own dispatch, for the gateway to
    /// answer (``VMScriptingGateway/execute(_:)``).
    ///
    /// Cocoa's `execute()` evaluates the receivers first and answers a failure
    /// itself, before any implementation runs: a name that resolves to nothing,
    /// or to two VMs, is "can't get" and never reaches the core. Overriding it
    /// is what lets a name reach the core as a name, and what lets the
    /// resolution wait for the library.
    ///
    /// A selector hop rather than a closure, so nothing crosses isolation:
    /// Cocoa executes every command on the main thread, where waiting for the
    /// hop runs it before this returns — inside the dispatch, which is where
    /// the gateway reads what the event addresses.
    nonisolated override func execute() -> Any? {
        performSelector(onMainThread: #selector(takeOver), with: nil, waitUntilDone: true)
        return nil
    }

    /// Where the hop lands, on the main actor.
    @objc private func takeOver() {
        guard let gateway = (NSApp.delegate as? VMScriptingRoot)?.scriptingGateway else {
            refuse(Int(errAEEventFailed), Self.notReady)
            return
        }
        gateway.execute(self)
    }

    /// Reads what the event addresses — inside a dispatch of the gateway's
    /// own — and answers the verb to run on it once that dispatch returns, or
    /// `nil` with the refusal recorded.
    ///
    /// A ``VMGroupActionCommand`` answers what it addresses its own way. Any
    /// other command addressing VMs runs ``run(_:on:)`` on the ones its direct
    /// parameter names, answering nothing, and refuses a smart group or
    /// folder; one addressing anything else overrides this.
    func work(on gateway: VMScriptingGateway) -> VMScriptingGateway.Work? {
        guard let subject = gateway.subject(addressedBy: self) else { return nil }
        if let acting = self as? any VMGroupActionCommand { return acting.work(on: gateway, addressing: subject) }
        switch subject {
        case .virtualMachines(let selectors, _):
            return {
                try await self.run(gateway, on: selectors)
                return nil
            }
        case .group:
            refuse(CommandError.invalidArgument(Self.groupActionsRefusal(commandDescription.commandName)))
            return nil
        }
    }

    /// What a command a smart group or folder doesn't take reads back for
    /// one: the commands it does take, as the dictionary names them.
    private static func groupActionsRefusal(_ command: String) -> String {
        let offered = VMGroupAction.allCases.compactMap { VMVerbVocabulary.appleScript.name(of: $0.verb) }
        return "\(command) acts on virtual machines; a smart group or folder takes "
            + "\(offered.dropLast().joined(separator: ", ")) or \(offered.last ?? "")."
    }

    /// The verb, run on the VMs the event addressed.
    ///
    /// Every command addressing VMs but a ``VMGroupActionCommand`` overrides
    /// this; reaching the base is a programming error.
    func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        Self.logger.log(
            .fault,
            "The \(self.commandDescription.commandName, privacy: .public) command runs no verb")
        assertionFailure("The \(commandDescription.commandName) command runs no verb")
        throw CommandError.unsupported(capability: "the \(commandDescription.commandName) command")
    }

    /// Whether the `with`/`without` parameter under `key` was given as `with`.
    func flag(_ key: String) -> Bool {
        arguments?[key] as? Bool ?? false
    }

    /// The deadline in seconds the parameter under `key` carries, `nil` when
    /// the script named none — which is a wait as long as the guest takes.
    func seconds(_ key: String) -> TimeInterval? {
        guard let number = arguments?[key] as? NSNumber else { return nil }
        return number.doubleValue
    }
}

// MARK: - The verbs of a group action

/// A lifecycle command a smart group or folder takes as a whole — the verb of
/// one of the core's group actions — answering the VMs it acted on, each by
/// identifier: a reference for one VM named by one reference, and a list for
/// a list of them, a reference to several, or a group.
///
/// Its dictionary entry declares that result, as no other lifecycle
/// command's does: Cocoa answers a resumed command as its declared result
/// type, a declared one with nothing to answer as `missing value` (observed
/// on macOS 27).
@MainActor
protocol VMGroupActionCommand: VMScriptCommand {
    /// The action it takes on every VM in a smart group or folder.
    var groupAction: VMGroupAction { get }

    /// The first parameter given that changes only one VM's verb, as the
    /// script writes it — what the command refuses a group with — or `nil`
    /// for none.
    ///
    /// - Throws: ``CommandError/invalidArgument(_:)`` for a parameter whose
    ///   value names nothing the command takes.
    func parameterTakenByOneVM() throws(CommandError) -> String?

    /// The verb, run on the VMs the event addressed, answering the identifier
    /// of each one it acted on, in order.
    func act(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws -> [UUID]
}

extension VMGroupActionCommand {
    func parameterTakenByOneVM() throws(CommandError) -> String? { nil }

    /// The work ``VMScriptCommand/work(on:)`` answers for `subject`: the verb
    /// on its VMs, or the group action on its group, each answering the VMs
    /// it acted on — or `nil`, with the refusal recorded, for a group given a
    /// parameter only one VM's verb takes.
    fileprivate func work(
        on gateway: VMScriptingGateway, addressing subject: VMScriptSelector.LifecycleSubject
    ) -> VMScriptingGateway.Work? {
        switch subject {
        case .virtualMachines(let selectors, let isList):
            return {
                let acted = try await self.act(gateway, on: selectors).compactMap(VMScriptObject.specifier(for:))
                guard isList else { return acted.first }
                return acted
            }
        case .group(let group):
            do throws(CommandError) {
                if let given = try parameterTakenByOneVM() {
                    throw CommandError.invalidArgument(
                        "`\(given)` acts on one virtual machine, not a smart group or folder.")
                }
            } catch {
                refuse(error)
                return nil
            }
            let action = groupAction
            return { try await gateway.groupAction(action, on: group) }
        }
    }
}

/// `start virtual machine … [with recovery mode] [with confirmation]`, or
/// `start <smart group or folder>`
@objc(VMStartScriptCommand)
final class VMStartScriptCommand: VMScriptCommand, VMGroupActionCommand {
    var groupAction: VMGroupAction { .start }

    func act(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws -> [UUID] {
        try await gateway.start(
            selectors, recoveryMode: flag("RecoveryMode"), confirmation: flag(Self.confirmationKey))
    }

    func parameterTakenByOneVM() throws(CommandError) -> String? {
        if flag("RecoveryMode") { return "with recovery mode" }
        return flag(Self.confirmationKey) ? "with confirmation" : nil
    }
}

/// `stop virtual machine … [method <method>] [with confirmation] [giving up
/// after <seconds>]`, or `stop <smart group or folder>`
@objc(VMStopScriptCommand)
final class VMStopScriptCommand: VMScriptCommand, VMGroupActionCommand {
    var groupAction: VMGroupAction { .stop }

    func act(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws -> [UUID] {
        try await gateway.stop(
            selectors, method: try stopMethod().disposition, confirmation: flag(Self.confirmationKey),
            givingUpAfter: seconds(Self.givingUpAfterKey))
    }

    func parameterTakenByOneVM() throws(CommandError) -> String? {
        try stopParameterTakenByOneVM()
    }
}

/// `restart virtual machine … [method <method>] [with confirmation] [giving
/// up after <seconds>]`, or `restart <smart group or folder>`
@objc(VMRestartScriptCommand)
final class VMRestartScriptCommand: VMScriptCommand, VMGroupActionCommand {
    var groupAction: VMGroupAction { .restart }

    func act(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws -> [UUID] {
        try await gateway.restart(
            selectors, method: try stopMethod().disposition, confirmation: flag(Self.confirmationKey),
            givingUpAfter: seconds(Self.givingUpAfterKey))
    }

    func parameterTakenByOneVM() throws(CommandError) -> String? {
        try stopParameterTakenByOneVM()
    }
}

/// `suspend virtual machine …`, or `suspend <smart group or folder>`
@objc(VMSuspendScriptCommand)
final class VMSuspendScriptCommand: VMScriptCommand, VMGroupActionCommand {
    var groupAction: VMGroupAction { .suspend }

    func act(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws -> [UUID] {
        try await gateway.suspend(selectors)
    }
}

// MARK: - Commands

extension VMScriptCommand {
    /// The Cocoa key of `giving up after`, on `stop` and `restart`.
    nonisolated static let givingUpAfterKey = "GivingUpAfter"

    /// The way down the `method` parameter asked for, `normal` when the script
    /// named none.
    ///
    /// - Throws: ``CommandError/invalidArgument(_:)`` for a code from no
    ///   vocabulary this app writes.
    func stopMethod() throws(CommandError) -> VMScriptStopMethod {
        guard let named = arguments?["StopMethod"] as? NSNumber else { return .normal }
        guard let method = VMScriptStopMethod(code: named.uint32Value) else {
            throw CommandError.invalidArgument("That is not a way Kernova can stop a guest.")
        }
        return method
    }

    /// The first of `stop`'s or `restart`'s parameters given that changes
    /// only one VM's verb, as ``VMGroupActionCommand/parameterTakenByOneVM()``
    /// answers it: a group
    /// takes its guests down by `method normal`, asking nothing, with no
    /// deadline.
    func stopParameterTakenByOneVM() throws(CommandError) -> String? {
        let method = try stopMethod()
        if method != .normal { return method.phrase }
        if flag(Self.confirmationKey) { return "with confirmation" }
        return seconds(Self.givingUpAfterKey) != nil ? "giving up after" : nil
    }
}

/// `pause virtual machine …`
@objc(VMPauseScriptCommand)
final class VMPauseScriptCommand: VMScriptCommand {
    override func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        try await gateway.pause(selectors)
    }
}

/// `resume virtual machine … [with confirmation]`
@objc(VMResumeScriptCommand)
final class VMResumeScriptCommand: VMScriptCommand {
    override func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        try await gateway.resume(selectors, confirmation: flag(Self.confirmationKey))
    }
}

/// `reveal virtual machine …`
@objc(VMRevealScriptCommand)
final class VMRevealScriptCommand: VMScriptCommand {
    override func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        try await gateway.reveal(selectors)
    }
}

/// `cancel guest setup virtual machine … [with confirmation]`
@objc(VMCancelGuestSetupScriptCommand)
final class VMCancelGuestSetupScriptCommand: VMScriptCommand {
    override func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        try await gateway.cancelGuestSetup(selectors, confirmation: flag(Self.confirmationKey))
    }
}

/// `cancel copy virtual machine … [with confirmation]`
@objc(VMCancelCopyScriptCommand)
final class VMCancelCopyScriptCommand: VMScriptCommand {
    override func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        try await gateway.cancelCopy(selectors, confirmation: flag(Self.confirmationKey))
    }
}

/// `import <file or path> [without waiting]`
@objc(VMImportScriptCommand)
final class VMImportScriptCommand: VMScriptCommand {
    override func work(on gateway: VMScriptingGateway) -> VMScriptingGateway.Work? {
        let path: String
        do {
            path = try bundlePath()
        } catch let refusal as CommandError {
            refuse(refusal)
            return nil
        } catch {
            refuse(Int(errAEEventFailed), error.localizedDescription)
            return nil
        }
        let waiting = arguments?[Self.waitingKey] as? Bool ?? true
        return { try await gateway.importVM(atPath: path, waiting: waiting) }
    }

    /// The full path of the bundle the direct parameter names: a file's own,
    /// or text read as ``UserHome/fullPath(_:of:)`` reads it.
    ///
    /// A file reference is read for its path alone, which the core's import
    /// reads as is where Kernova may already read it and asks for in an open
    /// panel where it may not: Apple documents an app's sandbox extended to
    /// what open and save panels and a drag to its Dock icon hand it
    /// ("Accessing files from the macOS App Sandbox"), and to no file an
    /// Apple event names.
    private func bundlePath() throws -> String {
        switch directParameter {
        case let url as URL where url.isFileURL: url.path(percentEncoded: false)
        case let text as String: try UserHome.fullPath(text, of: "A virtual machine bundle")
        default: throw CommandError.invalidArgument("Name the bundle to import, as a file or its full path.")
        }
    }
}

/// `revert to snapshot … [with confirmation]`
///
/// It addresses snapshots, each of which names its VM, so it reverts a VM to
/// a snapshot of its own by construction.
@objc(VMRevertScriptCommand)
final class VMRevertScriptCommand: VMScriptCommand {
    override func work(on gateway: VMScriptingGateway) -> VMScriptingGateway.Work? {
        guard let snapshots = gateway.snapshots(addressedBy: self, unnamed: "Name the snapshot to revert to.")
        else { return nil }
        let confirmation = flag(Self.confirmationKey)
        return {
            try await gateway.revert(to: snapshots, confirmation: confirmation)
            return nil
        }
    }
}

/// `change setting … to <value or list of values> [with confirmation]`
///
/// What the Standard Suite's `set value of setting …` writes, with the consent
/// a `set` can't carry, and several settings in one write.
@objc(VMChangeScriptCommand)
final class VMChangeScriptCommand: VMScriptCommand {
    /// The Cocoa key of `change`'s `to`, as the dictionary declares it.
    nonisolated private static let valueKey = "Value"

    override func work(on gateway: VMScriptingGateway) -> VMScriptingGateway.Work? {
        guard let addressed = gateway.settings(addressedBy: self) else { return nil }
        let values: [String]
        do {
            values = try self.values(for: addressed.settings)
        } catch let refusal as CommandError {
            refuse(refusal)
            return nil
        } catch {
            refuse(Int(errAEEventFailed), error.localizedDescription)
            return nil
        }
        let confirmation = flag(Self.confirmationKey)
        return {
            let held = try await gateway.change(addressed.settings, to: values, confirmation: confirmation)
            guard addressed.isList else { return held.first }
            let list = NSAppleEventDescriptor.list()
            for value in held { list.insert(value, at: list.numberOfItems + 1) }
            return list
        }
    }

    /// The text the core takes for each of `settings`, from the value `to`
    /// gives: one for all of them, or a list with one for each, in order —
    /// each read as ``VMScriptSettingValue/text(of:for:)`` reads it.
    ///
    /// - Throws: ``CommandError/invalidArgument(_:)`` for a list of another
    ///   length, and for a value its setting can't read.
    private func values(for settings: [VMSettingAddress]) throws -> [String] {
        let given = arguments?[Self.valueKey]
        guard let list = Self.items(given) else {
            return try settings.map { try VMScriptSettingValue.text(of: given, for: $0) }
        }
        guard list.count == settings.count else {
            throw CommandError.invalidArgument(
                "Give one value, or one for each of the \(settings.count) settings named; this gives \(list.count).")
        }
        return try zip(list, settings).map { try VMScriptSettingValue.text(of: $0, for: $1) }
    }

    /// `value`'s items, when it is a list; `nil` for one value.
    private static func items(_ value: Any?) -> [Any]? {
        if let list = value as? [Any] { return list }
        guard let list = value as? NSAppleEventDescriptor, list.descriptorType == typeAEList else { return nil }
        return stride(from: 1, through: list.numberOfItems, by: 1).compactMap { list.atIndex($0) }
    }
}

// MARK: - Standard Suite

/// The Standard Suite's `delete … [with confirmation] [with immediate
/// deletion]`: a delete of a virtual machine, a snapshot, a shared directory,
/// a USB accessory or a remembered USB accessory, or of a list of references,
/// goes to ``VMScriptingGateway/delete(_:in:for:)``, and every other delete is
/// Cocoa's own.
@MainActor
@objc(VMDeleteScriptCommand)
final class VMDeleteScriptCommand: NSDeleteCommand {
    /// The Cocoa key of `delete`'s `immediate deletion`, as the dictionary
    /// declares it.
    nonisolated static let immediateDeletionKey = "ImmediateDeletion"

    /// The element keys whose delete the gateway answers.
    nonisolated private static let handled: Set = [
        VMScriptingRoot.virtualMachinesKey, VMScriptObject.snapshotsKey, VMScriptObject.sharedDirectoriesKey,
        VMScriptObject.usbAccessoriesKey, VMScriptObject.rememberedUSBAccessoriesKey,
    ]

    /// A selector hop to the main actor, as ``VMScriptCommand/execute()``
    /// takes, for a delete the gateway answers.
    nonisolated override func performDefaultImplementation() -> Any? {
        guard directParameter is [Any] || splitElement.map({ Self.handled.contains($0.key) }) == true else {
            return super.performDefaultImplementation()
        }
        performSelector(onMainThread: #selector(deleteObjects), with: nil, waitUntilDone: true)
        return nil
    }

    /// Where the hop lands, on the main actor.
    @objc private func deleteObjects() {
        guard let gateway = (NSApp.delegate as? VMScriptingRoot)?.scriptingGateway else {
            refuse(Int(errAEEventFailed), VMScriptCommand.notReady)
            return
        }
        if let list = directParameter as? [Any] {
            gateway.delete(list, in: nil, for: self)
        } else if let deleted = splitElement {
            gateway.delete(deleted, in: evaluatedReceivers, for: self)
        }
    }
}

/// The Standard Suite's `duplicate … [as <clone outcome>] [without waiting]`:
/// a duplicate of a virtual machine goes to
/// ``VMScriptingGateway/duplicate(_:in:for:outcome:waiting:)``, and every
/// other duplicate is Cocoa's own.
///
/// Its direct parameter is one reference, as the Standard Suite's is: Cocoa
/// answers a list of them with a coercion error (`errAECoercionFail`) before
/// any command runs, whatever the dictionary declares (observed on macOS 27).
@MainActor
@objc(VMDuplicateScriptCommand)
final class VMDuplicateScriptCommand: NSCloneCommand {
    /// The Cocoa keys of `duplicate`'s parameters, as the dictionary declares
    /// them.
    nonisolated private static let locationKey = "ToLocation"
    nonisolated private static let propertiesKey = "WithProperties"
    nonisolated private static let cloneOutcomeKey = "CloneOutcome"

    /// A selector hop to the main actor, as ``VMScriptCommand/execute()``
    /// takes, for a duplicate the gateway answers.
    nonisolated override func performDefaultImplementation() -> Any? {
        guard splitElement?.key == VMScriptingRoot.virtualMachinesKey else {
            return super.performDefaultImplementation()
        }
        performSelector(onMainThread: #selector(duplicateVirtualMachines), with: nil, waitUntilDone: true)
        return nil
    }

    /// Where the hop lands, on the main actor: refuses the parameters a
    /// clone has no use for, and hands the rest to the gateway.
    ///
    /// The library places a clone, and a clone takes its properties from the
    /// verbs a script runs on the reference `duplicate` answers.
    @objc private func duplicateVirtualMachines() {
        guard let gateway = (NSApp.delegate as? VMScriptingRoot)?.scriptingGateway else {
            refuse(Int(errAEEventFailed), VMScriptCommand.notReady)
            return
        }
        guard arguments?[Self.locationKey] == nil else {
            refuse(Int(errAECantPutThatThere), "Kernova puts a clone in the library itself, so duplicate takes no to.")
            return
        }
        guard arguments?[Self.propertiesKey] == nil else {
            refuse(
                Int(errAEEventFailed),
                "Set a clone\u{2019}s properties on the virtual machine duplicate answers, so duplicate takes no with properties."
            )
            return
        }
        let outcome: CloneOutcome?
        do {
            outcome = try cloneOutcome()
        } catch let refusal as CommandError {
            refuse(refusal)
            return
        } catch {
            refuse(Int(errAEEventFailed), error.localizedDescription)
            return
        }
        guard let cloned = splitElement else { return }
        gateway.duplicate(
            cloned, in: evaluatedReceivers, for: self, outcome: outcome,
            waiting: arguments?[VMScriptCommand.waitingKey] as? Bool ?? true)
    }

    /// The outcome `as` asked for, `nil` — Kernova's own setting — when the
    /// script named none.
    ///
    /// - Throws: ``CommandError/invalidArgument(_:)`` for a code from no
    ///   vocabulary this app writes.
    private func cloneOutcome() throws -> CloneOutcome? {
        guard let named = arguments?[Self.cloneOutcomeKey] as? NSNumber else { return nil }
        guard let outcome = VMScriptCloneOutcome(code: named.uint32Value) else {
            throw CommandError.invalidArgument("That is not a way Kernova clones a virtual machine.")
        }
        return outcome.outcome
    }
}

extension NSScriptCommand {
    /// The element a Standard Suite `delete`'s or `duplicate`'s one reference
    /// names, which Cocoa splits off from the container it evaluates apart
    /// (`keySpecifier`, against `evaluatedReceivers`) — `nil` for a list,
    /// which it leaves whole, as the direct parameter.
    ///
    /// Read by key: the header declares `keySpecifier` non-null, and Cocoa
    /// sets it only when the direct parameter is one reference.
    nonisolated fileprivate var splitElement: NSScriptObjectSpecifier? {
        value(forKey: #keyPath(NSDeleteCommand.keySpecifier)) as? NSScriptObjectSpecifier
    }
}

/// The Standard Suite's `make`: a snapshot is taken by
/// ``VMScriptObject/makeSnapshot(name:notes:)``, a folder shared by
/// ``VMScriptObject/makeSharedDirectory(path:readOnly:)``, and every other
/// class's make is Cocoa's own.
@MainActor
@objc(VMCreateScriptCommand)
final class VMCreateScriptCommand: NSCreateCommand {
    /// The Cocoa key of `make`'s `at`, as the dictionary declares it.
    nonisolated private static let locationKey = "Location"

    /// An element of a VM whose make Kernova answers itself.
    private enum Made {
        case snapshot
        case sharedDirectory

        /// What `description`, the class a make names, makes; `nil` for a
        /// class whose make is Cocoa's own.
        init?(_ description: NSScriptClassDescription) {
            switch description.implementationClassName {
            case NSStringFromClass(VMSnapshotScriptObject.self): self = .snapshot
            case NSStringFromClass(VMSharedDirectoryScriptObject.self): self = .sharedDirectory
            default: return nil
            }
        }

        /// The VM element it is made in.
        var key: String {
            switch self {
            case .snapshot: VMScriptObject.snapshotsKey
            case .sharedDirectory: VMScriptObject.sharedDirectoriesKey
            }
        }

        /// What a make naming no single VM reads back.
        var unplaced: String {
            switch self {
            case .snapshot: "Name the virtual machine to take a snapshot of."
            case .sharedDirectory: "Name the virtual machine to share a folder with."
            }
        }
    }

    /// A selector hop to the main actor, as ``VMScriptCommand/execute()``
    /// takes, for a make Kernova answers itself.
    nonisolated override func performDefaultImplementation() -> Any? {
        guard Made(createClassDescription) != nil else { return super.performDefaultImplementation() }
        performSelector(onMainThread: #selector(makeElement), with: nil, waitUntilDone: true)
        return nil
    }

    /// Where the hop lands, on the main actor: makes the element in the one
    /// VM the make names, or records why it names none.
    @objc private func makeElement() {
        guard let made = Made(createClassDescription), let vm = virtualMachine(making: made) else { return }
        let properties = resolvedKeyDictionary
        switch made {
        case .snapshot:
            vm.makeSnapshot(
                name: Self.text(properties[#keyPath(VMSnapshotScriptObject.name)]),
                notes: Self.text(properties[#keyPath(VMSnapshotScriptObject.notes)]))
        case .sharedDirectory:
            let path: String
            do {
                path = try folderPath()
            } catch let refusal as CommandError {
                refuse(refusal)
                return
            } catch {
                refuse(Int(errAEEventFailed), error.localizedDescription)
                return
            }
            let readOnly = properties[#keyPath(VMSharedDirectoryScriptObject.readOnly)]
            vm.makeSharedDirectory(path: path, readOnly: Self.flag(readOnly))
        }
    }

    /// The full path of the folder the make's `with properties` record names
    /// as its `path`: a file reference's own — `POSIX file "…"`, an alias,
    /// what `choose folder` answers — or text read as
    /// ``UserHome/fullPath(_:of:)`` reads it: the path the core's add takes,
    /// for the reason ``VMImportScriptCommand`` states for a bundle.
    ///
    /// A file reference is read off the event as the script sent it:
    /// ``resolvedKeyDictionary`` holds it coerced to the text the dictionary
    /// declares, an HFS path (observed on macOS 27).
    private func folderPath() throws -> String {
        let given = appleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.forKeyword(Self.pathCode)
        if let given, Self.fileTypes.contains(given.descriptorType), let url = given.fileURLValue {
            return url.path(percentEncoded: false)
        }
        guard let text = Self.text(resolvedKeyDictionary[#keyPath(VMSharedDirectoryScriptObject.path)]) else {
            throw CommandError.invalidArgument("Name the folder to share, with properties {path:\u{2026}}.")
        }
        return try UserHome.fullPath(text, of: "A folder")
    }

    /// The code the dictionary gives a shared directory's `path`.
    private static let pathCode = FourCharCode(scriptingCode: "KvPa")

    /// The descriptor types AppleScript sends a file reference as.
    private static let fileTypes: Set<DescType> = [typeFileURL, typeAlias, typeBookmarkData]

    /// `value` as the boolean the dictionary declares the property as, false
    /// for none.
    private static func flag(_ value: Any?) -> Bool {
        guard let value else { return false }
        return (NSScriptCoercionHandler.shared().coerceValue(value, to: NSNumber.self) as? NSNumber)?.boolValue
            ?? false
    }

    /// The VM the make of `made` names: `at`'s container when it is that VM
    /// element, or else, with no `at`, the `tell` block's subject — `tell
    /// virtual machine … to make new snapshot`, whose target travels only as
    /// the event's subject attribute, the container Cocoa's own make inserts
    /// into.
    ///
    /// `nil`, with the refusal recorded, for a reference that names nothing
    /// and for one that names no single VM.
    private func virtualMachine(making made: Made) -> VMScriptObject? {
        guard let location = arguments?[Self.locationKey] as? NSPositionalSpecifier else {
            guard let subject = Self.subject(of: appleEvent) else { return unplaced(made) }
            guard let evaluated = subject.objectsByEvaluatingSpecifier else { return failure(evaluating: subject) }
            return evaluated as? VMScriptObject ?? unplaced(made)
        }
        // Evaluated before the location is: after the location's evaluation
        // finds no place for a snapshot in a network, the same reference
        // evaluates to nothing (observed on macOS 27), and "Can't get" would
        // name a network that exists.
        guard location.objectSpecifier.objectsByEvaluatingSpecifier != nil else {
            return failure(evaluating: location.objectSpecifier)
        }
        location.setInsertionClassDescription(createClassDescription)
        location.evaluate()
        guard location.insertionKey == made.key, let vm = location.insertionContainer as? VMScriptObject
        else { return unplaced(made) }
        return vm
    }

    /// The object a `tell` block names, as `event`'s subject attribute
    /// carries it; `nil` for none, or for the application.
    private static func subject(of event: NSAppleEventDescriptor?) -> NSScriptObjectSpecifier? {
        guard let descriptor = event?.attributeDescriptor(forKeyword: FourCharCode(scriptingCode: "subj")),
            descriptor.descriptorType == typeObjectSpecifier
        else { return nil }
        return NSScriptObjectSpecifier(descriptor: descriptor)
    }

    /// Records `specifier`'s failed evaluation as what the script reads —
    /// "Can't get …" — unless the evaluation recorded a refusal in words of its
    /// own, such as a VM name nothing answers to.
    private func failure(evaluating specifier: NSScriptObjectSpecifier) -> VMScriptObject? {
        if scriptErrorString == nil {
            VMScriptEvaluationFailure(specifier).record(on: self, addressing: specifier)
        }
        return nil
    }

    /// Refuses a make of `made` that names no single VM to make it in, in
    /// place of the bare error Cocoa's search for a place recorded.
    private func unplaced(_ made: Made) -> VMScriptObject? {
        refuse(Int(errAECantPutThatThere), made.unplaced)
        scriptErrorOffendingObjectDescriptor = nil
        return nil
    }

    /// `value` as the text the dictionary declares the property as, `nil` for
    /// none.
    private static func text(_ value: Any?) -> String? {
        guard let value else { return nil }
        return NSScriptCoercionHandler.shared().coerceValue(value, to: NSString.self) as? String
    }
}
