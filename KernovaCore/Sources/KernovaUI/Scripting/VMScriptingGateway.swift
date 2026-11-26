import Cocoa
import KernovaCommandModel
import KernovaCore
import KernovaKit
import KernovaLogging

/// The Apple event front door: everything Script Editor, Automator, and
/// `osascript` ask of Kernova passes through here and reaches ``VMCommandCore``.
///
/// Receiving Apple events needs no entitlement — a sandboxed app keeps the
/// ability to receive and respond to them, and only *sending* one to another
/// app needs a scripting-targets entitlement (Apple QA1888).
///
/// **Passes:** a specifier is evaluated only inside Cocoa's own dispatch of
/// the script's event. A command whose dispatch reads what is not in hand yet
/// — the library before the app's first read of it lands, a VM's storage
/// disks or a snapshot's size, which are measured from their files off the
/// main thread — is suspended, and answered from a later dispatch of the same
/// event to this process, once what it read is in hand (``answer(_:)``). A
/// Kernova command, and a Standard Suite `make`, `delete` or `duplicate` the
/// gateway answers itself, runs its verb on what such a dispatch addressed,
/// once it returns; its own dispatch only suspends it.
/// **Addressing:** a script names a VM the way a person does, so this addresses
/// VMs by ``VMSelector/name(_:)`` as readily as by identifier — on a verb and
/// on a read alike.
///
/// It presents nothing: a refusal leaves as the ``CommandError`` the core
/// threw, which the command that asked turns into the script error the event
/// carries back to whoever ran it.
@MainActor
final class VMScriptingGateway {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMScriptingGateway")

    private let commands: VMCommandCore
    /// The app's first library read, shared with every other front door.
    private let readiness: LibraryReadiness
    /// Readies the app to put up a surface something outside the process asked
    /// for, without activating it: a script that wants Kernova in front says
    /// `activate`.
    private let prepareToSurface: @MainActor @Sendable () -> Void

    /// The commands suspended until their event can be answered, each
    /// answered once it is.
    private(set) var suspended: [CommandEvaluation] = []

    /// The evaluation whose event this gateway is dispatching again, which
    /// every measured read the dispatch reaches answers from.
    private var evaluating: CommandEvaluation?

    /// The command Cocoa suspended during the dispatch it is still
    /// evaluating, which `NSScriptCommand.current()` stops reporting the
    /// moment it is suspended while Cocoa carries on evaluating the rest of
    /// the specifier.
    ///
    /// Open from ``suspend(_:because:)`` until ``answer(_:)`` begins: that is
    /// a main-actor task, and Cocoa runs the whole dispatch inside one Apple
    /// event callout on the main thread, so it cannot begin before the
    /// dispatch returns (observed on macOS 27 with a probe app that stalls
    /// inside it).
    private var openFirstPass: CommandEvaluation?

    /// How the gateway reaches the command Cocoa is executing.
    private let runtime: VMScriptCommandRuntime

    init(
        commands: VMCommandCore, readiness: LibraryReadiness,
        prepareToSurface: @escaping @MainActor @Sendable () -> Void,
        runtime: VMScriptCommandRuntime = .cocoa
    ) {
        self.commands = commands
        self.readiness = readiness
        self.prepareToSurface = prepareToSurface
        self.runtime = runtime
    }

    // MARK: - Reads

    /// Every VM in the library, in library order — or
    /// nothing, with the command asking deferred, until the library has landed.
    func virtualMachines() -> [VMScriptObject] {
        guard !deferUntilLanded() else { return [] }
        return commands.list(.all).compactMap { object(for: $0.id) }
    }

    /// The first of the VMs ``virtualMachines()`` lists that `name` names
    /// (``NameRule/sibling(named:in:name:)``) — the one Cocoa's own lookup
    /// finds there — or nothing, with the command asking deferred, until the
    /// library has landed.
    ///
    /// It looks among ``VMCommandCore/listing(_:)``, the list
    /// ``VMCommandCore/list(_:)`` answers once caught up with other copies of
    /// Kernova, so naming a VM reads only that VM's bundle.
    ///
    /// A name no VM goes by is refused in the core's words, recorded on the
    /// command being answered, so the script reads the refusal every other
    /// door shows rather than a bare "can't get".
    func virtualMachine(named name: String) -> VMScriptObject? {
        guard !deferUntilLanded() else { return nil }
        guard let found = NameRule.sibling(named: name, in: commands.listing(.all), name: \.name) else {
            answering?.refuse(CommandError.notFound(.name(name)))
            return nil
        }
        return object(for: found.id)
    }

    /// The first of `members` — a network's or a group's `virtual machine`
    /// elements, in its order — that `name` names, or nothing, with a
    /// refusal naming where the VM was looked for, `placement`, recorded on
    /// the command being answered.
    func virtualMachine(named name: String, among members: [VMScriptObject], placement: String) -> VMScriptObject? {
        if let found = NameRule.sibling(named: name, in: members, name: \.name) { return found }
        answering?.refuse(
            CommandError.itemNotFoundOnHost(item: "virtual machine named \u{201C}\(name)\u{201D} \(placement)"))
        return nil
    }

    /// One VM's whole read, as the dictionary's `virtual machine`.
    ///
    /// The listing and the read are both synchronous main-actor reads of state
    /// already in memory with no suspension between them, so a row that lists
    /// and then fails to read is a programming error, not a race.
    private func object(for id: UUID) -> VMScriptObject? {
        do {
            return VMScriptObject(try commands.info(.id(id)), gateway: self)
        } catch {
            Self.logger.log(
                .fault,
                "Listed VM \(id.uuidString, privacy: .public) has no info read: \(error.localizedDescription, privacy: .public)"
            )
            assertionFailure("Listed VM \(id.uuidString) has no info read: \(error)")
            return nil
        }
    }

    /// The command whatever is read or written now answers for — where every
    /// refusal is recorded, and what ``run(_:on:_:)`` holds a write back on:
    /// the one Cocoa is executing, or the one it suspended earlier in the same
    /// dispatch.
    ///
    /// A command Cocoa is executing is always the newer: one that arrives
    /// before ``openFirstPass`` closes is reported until it is itself
    /// suspended, and then replaces it.
    private var answering: NSScriptCommand? {
        runtime.current() ?? openFirstPass?.command
    }

    /// Records a `make` the dictionary refuses on the command being answered.
    ///
    /// `NSScriptCommand.current()` reports no command once the `make` is
    /// suspended.
    func refuseToMake(_ message: String) {
        answering?.refuse(Int(errAECantHandleClass), message)
    }

    /// The storage disks of the VM `vm` identifies, in attachment order, from
    /// the measurement the evaluation being answered holds
    /// (``measured(_:read:)``).
    func storageDisks(of vm: UUID) -> [VMStorageDiskScriptObject] {
        let disks = measured(.storageDisks(of: vm)) { $0.storageDisks[vm] }
        return (disks ?? []).map { VMStorageDiskScriptObject($0, of: vm) }
    }

    /// The size of the snapshot `address` names, from the measurement the
    /// evaluation being answered holds (``measured(_:read:)``), `nil` when
    /// its files can't be read.
    func snapshotSize(of address: VMSnapshotAddress) -> SnapshotSize? {
        measured(.snapshotSize(address)) { $0.snapshotSizes[address] } ?? nil
    }

    /// What `measurement` measured for the evaluation being answered, as
    /// `read` finds it there.
    ///
    /// A dispatch of a script's own event holds no measurement, so its command
    /// is suspended, once, and answered by dispatches that do. What is not
    /// measured yet answers `nil` for now, and the evaluation measures it
    /// before its next dispatch.
    ///
    /// Cocoa evaluates the rest of a dispatch after its command is suspended,
    /// and a `whose` test can match the empty or missing answer given for now —
    /// so the dispatch is refused, which holds back every write left in it
    /// (``run(_:on:_:)``). Only a dispatch that reads everything measured
    /// answers the script, and its outcome replaces the refusal.
    private func measured<Value>(
        _ measurement: Measurement, read: (CommandEvaluation) -> Value?
    ) -> Value? {
        let evaluation: CommandEvaluation
        if let evaluating {
            evaluation = evaluating
        } else if let command = answering {
            evaluation = suspend(command, because: "reached \(measurement)")
        } else {
            Self.logger.log(
                .fault,
                "\(String(describing: measurement), privacy: .public) read outside any script command's evaluation")
            assertionFailure("\(measurement) read outside any script command's evaluation")
            return nil
        }
        guard let value = read(evaluation) else {
            if !evaluation.unmeasured.contains(measurement) { evaluation.unmeasured.append(measurement) }
            answering?.refuse(Int(errAEEventFailed), Self.measuring)
            return nil
        }
        return value
    }

    /// The refusal a dispatch that read something unmeasured carries, which
    /// the dispatch that answers the script replaces.
    nonisolated static let measuring = "Kernova is measuring what this reads."

    /// The refusal a suspended command's own dispatch carries, which the
    /// dispatch that answers the script replaces.
    nonisolated static let answeringLater = "Kernova answers this once what it reads is in hand."

    // MARK: - Evaluations

    /// A read a dispatch can reach that is measured off the main thread
    /// first.
    enum Measurement: Hashable, CustomStringConvertible {
        case storageDisks(of: UUID)
        case snapshotSize(VMSnapshotAddress)

        var description: String {
            switch self {
            case .storageDisks(let vm): "the storage disks of \(vm.uuidString)"
            case .snapshotSize(let address):
                "the size of snapshot \(address.snapshot.uuidString) of \(address.vm.uuidString)"
            }
        }
    }

    /// A verb a dispatch reached whose core call awaits, run once the
    /// dispatch returns; it answers what the command resumes with — a
    /// reference, a list of them, or nothing.
    typealias Work = @MainActor () async throws -> Any?

    /// One suspended command's evaluation: the event every dispatch of it
    /// sends again, what was measured for it, what a dispatch reached
    /// unmeasured, and the verbs the last dispatch reached.
    ///
    /// The measurements live only as long as the evaluation, so no command
    /// answers from another's.
    @MainActor
    final class CommandEvaluation {
        /// The command the evaluation answers.
        let command: NSScriptCommand
        /// The event `command` came from, as the script sent it.
        let event: NSAppleEventDescriptor?
        /// Each reached VM's storage disks, as measured for this command.
        fileprivate(set) var storageDisks: [UUID: [StorageDiskSummary]] = [:]
        /// Each reached snapshot's size, as measured for this command: `nil`
        /// when its files can't be read.
        fileprivate(set) var snapshotSizes: [VMSnapshotAddress: SnapshotSize?] = [:]
        /// What a dispatch reached unmeasured, in the order it reached it.
        fileprivate(set) var unmeasured: [Measurement] = []
        /// The verbs the last dispatch reached, in the order it reached them;
        /// none when it reached nothing it recorded or refused first.
        fileprivate(set) var work: [Work] = []

        init(_ command: NSScriptCommand) {
            self.command = command
            event = command.appleEvent
        }
    }

    /// What one dispatch of a suspended command's event answered.
    private struct Reply {
        let result: NSAppleEventDescriptor?
        let errorNumber: Int
        let errorString: String?
        let offendingObject: NSAppleEventDescriptor?
        let expectedType: NSAppleEventDescriptor?

        init(_ reply: NSAppleEventDescriptor) {
            result = reply.paramDescriptor(forKeyword: keyDirectObject)
            errorNumber = Int(reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0)
            errorString = reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue
            offendingObject = reply.paramDescriptor(forKeyword: Self.offendingObjectKeyword)
            expectedType = reply.paramDescriptor(forKeyword: Self.expectedTypeKeyword)
        }

        init(failure number: Int, _ message: String) {
            result = nil
            errorNumber = number
            errorString = message
            offendingObject = nil
            expectedType = nil
        }

        /// `kOSAErrorOffendingObject`, where a reply names what it could not get.
        private static let offendingObjectKeyword = FourCharCode(scriptingCode: "erob")
        /// `kOSAErrorExpectedType`, where a reply names the type it wanted.
        private static let expectedTypeKeyword = FourCharCode(scriptingCode: "errt")

        /// Makes `command` answer the script with this reply's error, or none.
        func record(on command: NSScriptCommand) {
            command.scriptErrorNumber = errorNumber
            command.scriptErrorString = errorString
            command.scriptErrorOffendingObjectDescriptor = offendingObject
            command.scriptErrorExpectedTypeDescriptor = expectedType
        }

        /// What `command` resumes with for Cocoa to answer the script with
        /// ``result``.
        ///
        /// Cocoa encodes a resumed command's result as its declared type, and
        /// takes a descriptor for nothing but `any`: a count resumed with the
        /// descriptor of its integer answers missing value (observed on
        /// macOS 27 with a probe app).
        func resumption(for command: NSScriptCommand) -> Any? {
            guard let result, result.descriptorType != typeNull else { return nil }
            guard command.commandDescription.appleEventCodeForReturnType != typeWildCard else {
                return result
            }
            switch result.descriptorType {
            case typeObjectSpecifier:
                return NSScriptObjectSpecifier(descriptor: result)
            case typeBoolean, typeTrue, typeFalse:
                return NSNumber(value: result.booleanValue)
            case typeSInt16, typeSInt32:
                return NSNumber(value: result.int32Value)
            case typeSInt64, typeIEEE32BitFloatingPoint, typeIEEE64BitFloatingPoint:
                return NSNumber(value: result.doubleValue)
            default:
                return result
            }
        }
    }

    /// Dispatches `evaluation`'s event until a dispatch reaches nothing
    /// unmeasured, measuring what each one reached before the next, and returns
    /// the last one's reply.
    ///
    /// Cocoa stops a failed evaluation early, so a dispatch can reach a read
    /// the one before never got to. Each dispatch but the last measures
    /// something no earlier one did, so the dispatches end.
    private func evaluate(_ evaluation: CommandEvaluation) async -> Reply {
        while true {
            let reached = evaluation.unmeasured
            evaluation.unmeasured = []
            for measurement in reached {
                switch measurement {
                case .storageDisks(let vm):
                    evaluation.storageDisks[vm] = await measureStorageDisks(of: vm)
                case .snapshotSize(let address):
                    evaluation.snapshotSizes.updateValue(await measureSnapshotSize(address), forKey: address)
                }
            }
            evaluation.work = []
            evaluating = evaluation
            let reply = dispatch(evaluation)
            evaluating = nil
            if evaluation.unmeasured.isEmpty { return reply }
        }
    }

    /// Dispatches `evaluation`'s event again, to this process, and returns
    /// Cocoa's reply to it.
    ///
    /// Each dispatch is Cocoa's own from the event: it builds the command and
    /// its specifiers afresh, splits a `set` or `delete`'s receivers, and turns
    /// what it could not evaluate into the script error. Evaluating outside a
    /// dispatch keeps none of that — and once an evaluation there fails, every
    /// later one fails with it until Cocoa next dispatches an event (observed
    /// on macOS 27 with a probe app). An event sent to the sending process is
    /// handled before the send returns, so the dispatch runs inside this call,
    /// on the main thread, with nothing else dispatched in between.
    private func dispatch(_ evaluation: CommandEvaluation) -> Reply {
        guard let event = evaluation.event else {
            Self.logger.log(
                .fault,
                "A suspended \(evaluation.command.commandDescription.commandName, privacy: .public) has no Apple event to answer from"
            )
            assertionFailure("A suspended \(evaluation.command.commandDescription.commandName) has no Apple event")
            return Reply(failure: Int(errAEEventFailed), "Kernova could not answer this.")
        }
        do {
            return Reply(
                try Self.copy(of: event).sendEvent(
                    options: [.waitForReply], timeout: TimeInterval(kAEDefaultTimeout)))
        } catch {
            let failure = error as NSError
            Self.logger.log(
                .error,
                "Dispatching a \(evaluation.command.commandDescription.commandName, privacy: .public) again failed: \(failure.localizedDescription, privacy: .public)"
            )
            return Reply(failure: failure.code, failure.localizedDescription)
        }
    }

    /// `event` addressed to this process: its class and ID, every parameter,
    /// and the attributes Cocoa reads it by — the `tell` block's subject and
    /// the `considering` text comparisons.
    private static func copy(of event: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let copy = NSAppleEventDescriptor.appleEvent(
            withEventClass: event.eventClass, eventID: event.eventID,
            targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        for index in stride(from: 1, through: event.numberOfItems, by: 1) {
            let keyword = event.keywordForDescriptor(at: index)
            if let parameter = event.paramDescriptor(forKeyword: keyword) {
                copy.setParam(parameter, forKeyword: keyword)
            }
        }
        for keyword in readAttributes {
            if let attribute = event.attributeDescriptor(forKeyword: keyword) {
                copy.setAttribute(attribute, forKeyword: keyword)
            }
        }
        return copy
    }

    /// `keySubjectAttr`, `enumConsidsAndIgnores` and `enumConsiderations`.
    private static let readAttributes = ["subj", "csig", "cons"].map(FourCharCode.init(scriptingCode:))

    /// The storage disks of the VM `vm` identifies, measured off the main
    /// thread — none for a VM that has left the library.
    ///
    /// The next dispatch evaluates against the library as it stands, so a
    /// departed VM is reached again only if it is listed again.
    private func measureStorageDisks(of vm: UUID) async -> [StorageDiskSummary] {
        do {
            return try await commands.storageDisks(of: .id(vm))
        } catch {
            Self.logger.log(
                .notice,
                "No storage disks read for \(vm.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    /// The size of the snapshot `address` names, measured off the main thread
    /// — `nil` for one its VM no longer lists, which the next dispatch reaches
    /// again only if it is listed again.
    private func measureSnapshotSize(_ address: VMSnapshotAddress) async -> SnapshotSize? {
        do {
            return try await commands.snapshotSize(of: .id(address.vm), snapshot: address.snapshot)
        } catch {
            Self.logger.log(
                .notice,
                "No size read for snapshot \(address.snapshot.uuidString, privacy: .public) of \(address.vm.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - Suspended commands

    /// Suspends the command Cocoa is evaluating a specifier for, when the
    /// library it evaluates against has not landed, and answers it once it has.
    ///
    /// - Returns: Whether the read was deferred, which is the caller's cue to
    ///   answer nothing now.
    private func deferUntilLanded() -> Bool {
        guard !readiness.hasLanded, let command = answering else { return false }
        suspend(command, because: "arrived before the library read landed")
        return true
    }

    /// The evaluation `command` is suspended under, suspending it first when
    /// it is not yet: one dispatch can reach the library and its disk lists
    /// many times, and the command is suspended and answered once.
    ///
    /// Cocoa evaluates a specifier inside the Apple event's own callout,
    /// through synchronous KVC with no suspension of its own to await in — but
    /// the command being executed is `NSScriptCommand.current()`, and a
    /// command can be suspended from anywhere on its own stack. From then on
    /// the dispatch reaches it as ``openFirstPass``, refused, so that nothing
    /// Cocoa goes on to write in it is written.
    @discardableResult
    private func suspend(_ command: NSScriptCommand, because reason: String) -> CommandEvaluation {
        if let held = suspended.first(where: { $0.command === command }) { return held }
        let evaluation = CommandEvaluation(command)
        suspended.append(evaluation)
        Self.logger.log(
            .notice,
            "A \(command.commandDescription.commandName, privacy: .public) \(reason, privacy: .public); suspended until it can be answered"
        )
        command.refuse(Int(errAEEventFailed), Self.answeringLater)
        runtime.suspend(command)
        openFirstPass = evaluation
        Task { await answer(evaluation) }
        return evaluation
    }

    /// Answers a suspended command, once its own dispatch has returned and the
    /// library has landed: with the reply of the first dispatch of its event
    /// that reaches everything measured — or, where that dispatch reached a
    /// verb and refused nothing, with what the verb answers once run.
    ///
    /// The verbs run in the order the dispatch reached them, and the first
    /// refusal stops them: an event addressing several snapshots or VMs
    /// carries back one error, and finishing the rest would leave a script
    /// unable to tell how far it got.
    private func answer(_ evaluation: CommandEvaluation) async {
        if openFirstPass === evaluation { openFirstPass = nil }
        await readiness.ready()
        let reply = await evaluate(evaluation)
        suspended.removeAll { $0 === evaluation }
        let command = evaluation.command
        reply.record(on: command)
        Self.logger.log(
            .notice,
            "Answering the suspended \(command.commandDescription.commandName, privacy: .public)"
        )
        var result = reply.resumption(for: command)
        if command.scriptErrorNumber == 0 {
            do {
                for work in evaluation.work { result = try await work() }
            } catch let refusal as CommandError {
                command.refuse(refusal)
                result = nil
            } catch {
                command.refuse(Int(errAEEventFailed), error.localizedDescription)
                result = nil
            }
        }
        runtime.resume(command, result)
    }

    /// Runs `work` once the dispatch reaching it returns — a verb Cocoa's own
    /// command reached, `verb`, where nothing can await.
    ///
    /// Outside a dispatch of this gateway's own, suspends the command being
    /// answered instead, which such a dispatch then reaches it in. Records
    /// nothing once that command already carries a refusal, as
    /// ``run(_:on:_:)`` runs nothing.
    private func afterDispatch(_ verb: VMVerb, _ work: @escaping Work) {
        guard let evaluating else {
            if let command = answering { suspend(command, because: "reached \(verb.rawValue)") }
            return
        }
        if let answering, answering.scriptErrorNumber != 0 { return }
        evaluating.work.append(work)
    }

    // MARK: - Verbs

    /// Takes `verb`'s event over: a dispatch of this gateway's own reads what
    /// it addresses (``VMScriptCommand/work(on:)``), and any other is
    /// suspended, to run the verb once that read is answered.
    ///
    /// Cocoa evaluates no receivers for a Kernova verb (``VMScriptCommand``),
    /// so nothing is read before this, and a VM's name reaches the core as a
    /// name.
    func execute(_ verb: VMScriptCommand) {
        guard let evaluating else {
            suspend(verb, because: "arrived")
            return
        }
        if let work = verb.work(on: self) { evaluating.work.append(work) }
    }

    /// The VMs or the group `verb` addresses
    /// (``VMScriptSelector/lifecycleSubject(addressing:)``) — its direct
    /// parameter, one specifier or a list of them, or the `tell` block's
    /// subject, which Cocoa promotes into the same slot — or `nil` with the
    /// refusal recorded on it.
    func subject(addressedBy verb: VMScriptCommand) -> VMScriptSelector.LifecycleSubject? {
        addressed(
            by: verb, unnamed: "Name the virtual machine to \(verb.commandDescription.commandName).",
            { try VMScriptSelector.lifecycleSubject(addressing: $0) })
    }

    /// The snapshots `verb` addresses, as ``subject(addressedBy:)`` reads
    /// VMs — each evaluated, so a reference names the snapshot its VM
    /// lists under it as the dispatch reads it.
    func snapshots(addressedBy verb: VMScriptCommand, unnamed: String) -> [VMSnapshotAddress]? {
        addressed(by: verb, unnamed: unnamed, { try VMScriptSelector.snapshots(addressing: $0) })
    }

    /// The settings `verb` addresses, each evaluated, and whether it
    /// addresses them as a list (``VMScriptSelector/settings(addressing:)``),
    /// or `nil` with the refusal recorded on it.
    func settings(addressedBy verb: VMScriptCommand) -> (settings: [VMSettingAddress], isList: Bool)? {
        addressed(
            by: verb, unnamed: "Name the setting to \(verb.commandDescription.commandName).",
            { try VMScriptSelector.settings(addressing: $0) })
    }

    /// What `read` makes of what `verb` addresses, or `nil` with the refusal
    /// recorded on it — `unnamed` for one that addresses nothing.
    private func addressed<Addressed>(
        by verb: VMScriptCommand, unnamed: String, _ read: (Any) throws -> Addressed
    ) -> Addressed? {
        guard let addressed = verb.directParameter ?? verb.receiversSpecifier else {
            verb.refuse(Int(errAEWrongNumberArgs), unnamed)
            return nil
        }
        return reading(addressed, for: verb) { try read(addressed) }
    }

    /// What `read` makes of `addressed`, what `command` addresses, or `nil`
    /// with the reason it names nothing recorded on `command`.
    private func reading<Read>(
        _ addressed: Any, for command: NSScriptCommand, _ read: () throws -> Read
    ) -> Read? {
        do {
            return try read()
        } catch let failure as VMScriptEvaluationFailure {
            failure.record(on: command, addressing: addressed)
        } catch let refusal as CommandError {
            command.refuse(refusal)
        } catch {
            command.refuse(Int(errAEEventFailed), error.localizedDescription)
        }
        return nil
    }

    // MARK: - Lifecycle

    /// Starts each VM, answering the identifier of each one started, in
    /// order.
    func start(_ selectors: [VMSelector], recoveryMode: Bool, confirmation: Bool) async throws -> [UUID] {
        try await perform(.start, on: selectors) { selector in
            try await self.commands.start(
                selector, recovery: recoveryMode, consent: Self.consent(confirmation))
        }
    }

    /// Stops each VM the way `method` names, with `confirmation` as the
    /// consent a destructive stop refuses without, answering the identifier
    /// of each one stopped, in order.
    func stop(
        _ selectors: [VMSelector], method: StopDisposition, confirmation: Bool,
        givingUpAfter timeout: TimeInterval?
    ) async throws -> [UUID] {
        try await perform(.stop, on: selectors) { selector in
            try await self.commands.stop(
                selector, disposition: method, consent: Self.consent(confirmation), timeout: timeout)
        }
    }

    /// The consent a script's `with confirmation` gives: every confirmation,
    /// or none.
    private static func consent(_ confirmation: Bool) -> Consent {
        confirmation ? .all : .none
    }

    /// Restarts each VM, taking it down the way `method` names, with
    /// `confirmation` as the consent a destructive restart refuses without,
    /// answering the identifier of each one restarted, in order.
    func restart(
        _ selectors: [VMSelector], method: StopDisposition, confirmation: Bool,
        givingUpAfter timeout: TimeInterval?
    ) async throws -> [UUID] {
        try await perform(.restart, on: selectors) { selector in
            try await self.commands.restart(
                selector, disposition: method, timeout: timeout, consent: Self.consent(confirmation))
        }
    }

    func pause(_ selectors: [VMSelector]) async throws {
        try await perform(.pause, on: selectors) {
            try await self.commands.pause($0)
        }
    }

    func resume(_ selectors: [VMSelector], confirmation: Bool) async throws {
        try await perform(.resume, on: selectors) { selector in
            try await self.commands.resume(selector, consent: Self.consent(confirmation))
        }
    }

    /// Suspends each VM, answering the identifier of each one suspended, in
    /// order.
    func suspend(_ selectors: [VMSelector]) async throws -> [UUID] {
        try await perform(.suspend, on: selectors) {
            try await self.commands.suspend($0)
        }
    }

    func reveal(_ selectors: [VMSelector]) async throws {
        try await perform(.reveal, on: selectors) {
            try self.commands.reveal($0)
        }
    }

    /// Interrupts the guest setup each VM is running, with `confirmation` as
    /// the consent the cancel refuses without.
    func cancelGuestSetup(_ selectors: [VMSelector], confirmation: Bool) async throws {
        try await perform(.cancelGuestSetup, on: selectors) { selector in
            try self.commands.cancelGuestSetup(selector, consent: Self.consent(confirmation))
        }
    }

    // MARK: - Library

    /// Stops the copy writing each VM, with `confirmation` as the consent the
    /// cancel refuses without.
    func cancelCopy(_ selectors: [VMSelector], confirmation: Bool) async throws {
        try await perform(.cancelPreparing, on: selectors) { selector in
            try self.commands.cancelPreparing(selector, consent: Self.consent(confirmation))
        }
    }

    /// Copies the bundle at `path` into the library — a script's `import` —
    /// answering the VM it became, settled when `waiting`.
    func importVM(atPath path: String, waiting: Bool) async throws -> NSScriptObjectSpecifier? {
        try await perform(.importVM, on: [path], naming: { $0 }) { path in
            VMScriptObject.specifier(for: try await self.commands.importVM(atPath: path, waitForOutcome: waiting).id)
        }.first ?? nil
    }

    /// Renames the VM `id` identifies — a script's `set name of virtual
    /// machine`.
    func rename(_ id: UUID, to newName: String) {
        run(.rename, on: id) { try commands.rename(.id(id), to: newName) }
    }

    /// Clones each VM `specifier` names — a script's `duplicate` of it,
    /// evaluated against `containers`, which Cocoa evaluated apart from it —
    /// once the dispatch returns, as `outcome`, settled when `waiting`; or
    /// records on `duplicate` why `specifier` names none.
    ///
    /// The `duplicate` answers a reference to the clone, or a list of them
    /// for a specifier Cocoa evaluates to a list
    /// (``VMScriptSelector/virtualMachines(addressing:in:)``), as Cocoa's own
    /// duplicate answers.
    func duplicate(
        _ specifier: NSScriptObjectSpecifier, in containers: Any?, for duplicate: NSScriptCommand,
        outcome: CloneOutcome?, waiting: Bool
    ) {
        guard
            let vms = reading(
                specifier, for: duplicate,
                { try VMScriptSelector.virtualMachines(addressing: specifier, in: containers) })
        else { return }
        afterDispatch(.clone) {
            let clones = try await self.perform(.clone, on: vms.selectors) { selector in
                VMScriptObject.specifier(
                    for: try await self.commands.clone(selector, outcome: outcome, waitForOutcome: waiting).id)
            }.compactMap(\.self)
            return vms.isList ? clones : clones.first
        }
    }

    /// Deletes what `addressed` names — a script's `delete` of one reference,
    /// evaluated against `containers` where Cocoa evaluated them apart from
    /// it, or of a list of them — once the dispatch returns, with `delete`'s
    /// `with confirmation` as the consent it refuses without; or records on
    /// `delete` why `addressed` names nothing it deletes.
    ///
    /// What the reference names, or the list's first item, decides whether it
    /// deletes virtual machines, snapshots, shared directories or remembered
    /// USB accessories, and a list naming anything else is refused whole
    /// (``VMScriptSelector``). Each is evaluated as every other verb on it is,
    /// never by the index Cocoa's own delete computes, which named the first
    /// of two snapshots sharing a name (observed on macOS 27).
    func delete(_ addressed: Any, in containers: Any?, for delete: NSScriptCommand) {
        guard (addressed as? [Any])?.isEmpty != true else { return }
        switch VMScriptSelector.key(addressedBy: addressed) {
        case VMScriptingRoot.virtualMachinesKey:
            // The files a VM uses outside its bundle are the app's own sheet's
            // to offer: it is the one surface that shows the user which they
            // are.
            deleteEach(
                addressed, in: containers, for: delete, verb: .delete,
                evaluate: VMScriptSelector.selectors(addressing:in:), naming: \.displayText,
                insteadOfImmediateDeletion: nil
            ) { vm, permanently, consent in
                try await self.commands.delete(vm, permanently: permanently, alsoRemoving: [], consent: consent)
            }
        case VMScriptObject.snapshotsKey:
            deleteEach(
                addressed, in: containers, for: delete, verb: .deleteSnapshot,
                evaluate: VMScriptSelector.snapshots(addressing:in:), naming: \.snapshot.uuidString,
                insteadOfImmediateDeletion: "A snapshot\u{2019}s files move to the Trash"
            ) { snapshot, _, consent in
                try await self.commands.deleteSnapshot(.id(snapshot.vm), snapshot: snapshot.snapshot, consent: consent)
            }
        case VMScriptObject.sharedDirectoriesKey:
            deleteEach(
                addressed, in: containers, for: delete, verb: .editSharedDirectory,
                evaluate: VMScriptSelector.sharedDirectories(addressing:in:), naming: \.path,
                insteadOfImmediateDeletion: "Deleting a shared directory stops sharing its folder and deletes nothing"
            ) { share, _, _ in
                try self.commands.removeSharedDirectory(.id(share.vm), path: share.path)
            }
        case VMScriptObject.rememberedUSBAccessoriesKey:
            deleteEach(
                addressed, in: containers, for: delete, verb: .forgetUSBPairing,
                evaluate: VMScriptSelector.rememberedUSBAccessories(addressing:in:), naming: \.key,
                insteadOfImmediateDeletion: "Deleting a remembered USB accessory forgets it and deletes nothing"
            ) { accessory, _, _ in
                try self.commands.forgetUSBPairing(.id(accessory.vm), key: accessory.key)
            }
        case VMScriptObject.usbAccessoriesKey:
            delete.refuse(
                Int(errAENotModifiable),
                "A script can\u{2019}t delete a USB accessory; detach takes one back off its guest.")
        default:
            delete.refuse(
                CommandError.invalidArgument(
                    "A list here names virtual machines, snapshots, shared directories or remembered USB accessories; item 1 is none of them."
                ))
        }
    }

    /// Runs `remove` on each `Item` that `evaluate` reads `addressed` as,
    /// against `containers` — a script's `delete` of one kind of element —
    /// once the dispatch returns, as `verb`, logging each under `name`; or
    /// records on `delete` why it removes nothing.
    ///
    /// `remove` takes whether the delete was `with immediate deletion` and
    /// the consent its `with confirmation` gives. Every kind but a VM refuses
    /// an immediate deletion, saying what its delete does instead.
    private func deleteEach<Item: Sendable>(
        _ addressed: Any, in containers: Any?, for delete: NSScriptCommand, verb: VMVerb,
        evaluate: (Any, Any?) throws -> [Item], naming name: @escaping (Item) -> String,
        insteadOfImmediateDeletion: String?,
        remove: @escaping (Item, _ permanently: Bool, Consent) async throws -> Void
    ) {
        let consent = Self.consent(delete.arguments?[VMScriptCommand.confirmationKey] as? Bool ?? false)
        let immediately = delete.arguments?[VMDeleteScriptCommand.immediateDeletionKey] as? Bool ?? false
        guard let items = reading(addressed, for: delete, { try evaluate(addressed, containers) }) else { return }
        if immediately, let instead = insteadOfImmediateDeletion {
            delete.refuse(CommandError.invalidArgument("\(instead); immediate deletion deletes a virtual machine."))
            return
        }
        afterDispatch(verb) {
            try await self.perform(verb, on: items, naming: name) { try await remove($0, immediately, consent) }
            return nil
        }
    }

    // MARK: - Settings

    /// The settings of the VM `vm` identifies that its guest has, as
    /// ``VMCommandCore/configuration(_:keys:)`` reads them — none, with the
    /// refusal recorded on the command being answered, when the VM can't be
    /// read.
    func settings(of vm: UUID) -> [VMSettingScriptObject] {
        guard let entries = answeringRefusal({ try commands.configuration(.id(vm), keys: nil) }) else { return [] }
        let descriptors = settingDescriptors()
        return entries.compactMap { setting($0, of: vm, descriptors: descriptors) }
    }

    /// The setting `key` names among the VM's — or `nil`, with the core's
    /// refusal recorded on the command being answered, for a key the keyspace
    /// doesn't hold or the VM's guest doesn't have.
    func setting(named key: String, of vm: UUID) -> VMSettingScriptObject? {
        guard let entry = answeringRefusal({ try commands.configuration(.id(vm), key: key) }) else { return nil }
        return setting(entry, of: vm, descriptors: settingDescriptors())
    }

    /// `entry`, one of the settings of the VM `vm` identifies, as its key's
    /// descriptor in `descriptors` describes it.
    ///
    /// The core reads only keys of its keyspace, so a key without a
    /// descriptor is a programming error, and is left out.
    private func setting(
        _ entry: ConfigurationEntry, of vm: UUID, descriptors: [String: ConfigurationKeyDescriptor]
    ) -> VMSettingScriptObject? {
        guard let descriptor = descriptors[entry.key] else {
            Self.logger.log(.fault, "Setting \(entry.key, privacy: .public) is not in the keyspace")
            assertionFailure("Setting \(entry.key) is not in the keyspace")
            return nil
        }
        return VMSettingScriptObject(entry, describedBy: descriptor, of: vm, gateway: self)
    }

    /// The keyspace's descriptors, by key.
    private func settingDescriptors() -> [String: ConfigurationKeyDescriptor] {
        Dictionary(uniqueKeysWithValues: commands.configurationKeys().map { ($0.name, $0) })
    }

    /// Sets the setting `address` names to `value` — a script's `set value
    /// of setting`, read as ``VMScriptSettingValue/text(of:for:)`` reads it.
    ///
    /// A `set` carries its value and nothing else, so it gives no consent: a
    /// change that asks for it is refused, naming `change` as the way to give
    /// it.
    func setSetting(_ address: VMSettingAddress, to value: Any?) {
        run(.setConfiguration, on: address.vm, consenting: Self.changeGivesConsent) {
            let text = try VMScriptSettingValue.text(of: value, for: address)
            try commands.setConfiguration(
                .id(address.vm), assignments: [ConfigurationEntry(key: address.key, value: text)], consent: .none)
        }
    }

    /// How a script gives the consent a `set` of a setting's value was
    /// refused for.
    ///
    /// AppleScript compiles no parameter after a `set`'s value ("A
    /// confirmation:true can't go after this …", observed on macOS 27).
    nonisolated static let changeGivesConsent =
        "`set` can\u{2019}t give consent; `change \u{2026} with confirmation` does it anyway."

    /// Changes each of `settings` to the value at its place in `values`, in
    /// the text the core takes — a script's `change` — with `confirmation` as
    /// the consent a change refuses without, answering the value each holds
    /// afterwards, typed as its kind is, in the order given.
    ///
    /// The settings of one VM are one write, all or none
    /// (``VMCommandCore/setConfiguration(_:assignments:consent:)``); the VMs
    /// are written in the order first named, and a refusal stops the rest.
    func change(
        _ settings: [VMSettingAddress], to values: [String], confirmation: Bool
    ) async throws -> [VMScriptSettingValue] {
        var writes: [SettingsWrite] = []
        var places: [(write: Int, assignment: Int)] = []
        for (setting, value) in zip(settings, values) {
            let write =
                writes.firstIndex { $0.vm == setting.vm }
                ?? {
                    writes.append(SettingsWrite(vm: setting.vm, assignments: []))
                    return writes.count - 1
                }()
            places.append((write, writes[write].assignments.count))
            writes[write].assignments.append(ConfigurationEntry(key: setting.key, value: value))
        }
        let held = try await perform(.setConfiguration, on: writes, naming: \.vm.uuidString) { write in
            try self.commands.setConfiguration(
                .id(write.vm), assignments: write.assignments, consent: Self.consent(confirmation))
        }
        return zip(settings, places).map { setting, place in
            VMScriptSettingValue(VMSettingScriptObject.value(held[place.write][place.assignment], as: setting.kind))
        }
    }

    /// The assignments one `change` makes to one VM.
    private struct SettingsWrite: Sendable {
        let vm: UUID
        var assignments: [ConfigurationEntry]
    }

    /// What `read` answers, or `nil` with its refusal recorded on the command
    /// being answered.
    private func answeringRefusal<Read>(_ read: () throws -> Read) -> Read? {
        do {
            return try read()
        } catch let refusal as CommandError {
            answering?.refuse(refusal)
        } catch {
            answering?.refuse(Int(errAEEventFailed), error.localizedDescription)
        }
        return nil
    }

    // MARK: - Snapshots

    /// The snapshots of the VM `vm` identifies, newest first — none, with the
    /// refusal recorded on the command being answered, when the VM can't be
    /// read.
    ///
    /// Every snapshot a script reaches is one of these, so a verb on it names
    /// a snapshot the VM listed as the dispatch read it.
    func snapshots(of vm: UUID) -> [VMSnapshotScriptObject] {
        listedSnapshots(of: vm)?.map { VMSnapshotScriptObject($0, of: vm, gateway: self) } ?? []
    }

    /// The snapshot `text` names among ``snapshots(of:)`` — the one its
    /// identifier spells, else the first it names
    /// (``NameRule/sibling(identifiedOrNamedBy:in:id:name:)``), the one
    /// Cocoa's own lookup finds there — or `nil`, with the refusal recorded on
    /// the command being answered, for text that names none of them.
    func snapshot(named text: String, of vm: UUID) -> VMSnapshotScriptObject? {
        guard let listed = listedSnapshots(of: vm) else { return nil }
        guard let found = NameRule.sibling(identifiedOrNamedBy: text, in: listed, id: \.id, name: \.name) else {
            if let refusal = itemNotFound("snapshot named \u{201C}\(text)\u{201D}", on: vm) {
                answering?.refuse(refusal)
            }
            return nil
        }
        return VMSnapshotScriptObject(found, of: vm, gateway: self)
    }

    /// The item `selection` found — or `nil`, with the refusal recorded on the
    /// command being answered: `missing`'s for text that names none of them,
    /// and `ambiguity`'s words for text that names several.
    private func selected<Item>(
        _ selection: NamedSelection<Item>, missing: () -> CommandError?, ambiguity: ([Item]) -> String
    ) -> Item? {
        switch selection {
        case .found(let item):
            return item
        case .notFound:
            if let refusal = missing() { answering?.refuse(refusal) }
            return nil
        case .ambiguous(let candidates):
            answering?.refuse(Int(errAENoSuchObject), ambiguity(candidates))
            return nil
        }
    }

    /// The refusal of `item`, something the VM `vm` identifies lists none of;
    /// `nil` once that VM has left the library, whose own evaluation then
    /// fails.
    private func itemNotFound(_ item: String, on vm: UUID) -> CommandError? {
        commands.list(.all).first { $0.id == vm }.map { CommandError.itemNotFound(vm: $0, item: item) }
    }

    /// The core's listing of the VM `vm` identifies, or `nil` with the refusal
    /// recorded on the command being answered.
    private func listedSnapshots(of vm: UUID) -> [SnapshotSummary]? {
        answeringRefusal { try commands.snapshots(of: .id(vm)) }
    }

    /// Takes a snapshot of the VM `vm` identifies, called `name` and noted
    /// `notes` — a script's `make new snapshot at` it
    /// (``VMCreateScriptCommand``) — once the dispatch returns
    /// (``afterDispatch(_:_:)``), answering the `make` with the snapshot
    /// taken.
    ///
    /// No name is the name the app's own sheet proposes.
    func makeSnapshot(of vm: UUID, name: String?, notes: String?) {
        afterDispatch(.takeSnapshot) {
            try await self.perform(.takeSnapshot, on: [vm], naming: \.uuidString) { vm in
                let taken = try await self.commands.takeSnapshot(
                    .id(vm), name: name ?? "", notes: notes ?? "", asEphemeralBaseline: false)
                return VMSnapshotScriptObject.specifier(for: VMSnapshotAddress(vm: vm, snapshot: taken.id))
            }.first ?? nil
        }
    }

    /// Refuses Cocoa's removal of a snapshot by index, which only a `move`
    /// asks for: the snapshots are ordered newest first, so there is no move
    /// to make.
    func refuseToMoveSnapshot() {
        answering?.refuse(
            Int(errAEEventNotHandled), "Kernova lists snapshots newest first, so a script can\u{2019}t move one.")
    }

    /// Returns each snapshot's VM to it, with `confirmation` as the consent a
    /// revert refuses without.
    func revert(to snapshots: [VMSnapshotAddress], confirmation: Bool) async throws {
        try await perform(.revertToSnapshot, on: snapshots, naming: \.snapshot.uuidString) { snapshot in
            try await self.commands.revertToSnapshot(
                .id(snapshot.vm), snapshot: snapshot.snapshot, consent: Self.consent(confirmation))
        }
    }

    /// Renames the snapshot `address` names — a script's `set name of
    /// snapshot`.
    func renameSnapshot(_ address: VMSnapshotAddress, to newName: String) {
        run(.renameSnapshot, on: address.vm) {
            try commands.renameSnapshot(.id(address.vm), snapshot: address.snapshot, to: newName)
        }
    }

    /// Replaces the note of the snapshot `address` names — a script's
    /// `set notes of snapshot`.
    func setSnapshotNotes(_ address: VMSnapshotAddress, to notes: String) {
        run(.setSnapshotNotes, on: address.vm) {
            try commands.setSnapshotNotes(.id(address.vm), snapshot: address.snapshot, notes: notes)
        }
    }

    // MARK: - Shared directories

    /// The folders the VM `vm` identifies shares with its guest, in the order
    /// it shares them — none, with the refusal recorded on the command being
    /// answered, when the VM can't be read.
    func sharedDirectories(of vm: UUID) -> [VMSharedDirectoryScriptObject] {
        listedSharedDirectories(of: vm)?.map { VMSharedDirectoryScriptObject($0, of: vm) } ?? []
    }

    /// The share `text` names among ``sharedDirectories(of:)``: a full path,
    /// starting with `/` or `~/`, names the share of that folder, as the core
    /// compares two paths; any other text the first share it names
    /// (``NameRule/sibling(identifiedBy:orNamedBy:in:name:)``), the one
    /// Cocoa's own lookup finds there. `nil`, with the refusal recorded on the
    /// command being answered, for text that names none of them.
    func sharedDirectory(named text: String, of vm: UUID) -> VMSharedDirectoryScriptObject? {
        guard let listed = listedSharedDirectories(of: vm) else { return nil }
        let folder = (try? UserHome.fullPath(text, of: "A folder")).map(VMCommandCore.comparablePath)
        guard
            let found = NameRule.sibling(
                identifiedBy: { VMCommandCore.comparablePath($0.path) == folder }, orNamedBy: text, in: listed,
                name: \.name)
        else {
            if let refusal = itemNotFound("shared directory named \u{201C}\(text)\u{201D}", on: vm) {
                answering?.refuse(refusal)
            }
            return nil
        }
        return VMSharedDirectoryScriptObject(found, of: vm)
    }

    /// The core's listing of the VM `vm` identifies, or `nil` with the refusal
    /// recorded on the command being answered.
    private func listedSharedDirectories(of vm: UUID) -> [SharedDirectorySummary]? {
        answeringRefusal { try commands.sharedDirectories(of: .id(vm)) }
    }

    /// Shares the folder at the full path `path` with the guest of the VM `vm`
    /// identifies — a script's `make new shared directory at` it
    /// (``VMCreateScriptCommand``) — once the dispatch returns, answering the
    /// `make` with the share the folder fills.
    ///
    /// The core asks for a folder Kernova can't already read in an open
    /// panel, which ``perform(_:on:naming:_:)`` readies the app to put up.
    func makeSharedDirectory(of vm: UUID, path: String, readOnly: Bool) {
        afterDispatch(.editSharedDirectory) {
            try await self.perform(.editSharedDirectory, on: [vm], naming: \.uuidString) { vm in
                let shared = try await self.commands.addSharedDirectory(.id(vm), path: path, readOnly: readOnly)
                return VMSharedDirectoryScriptObject.specifier(for: VMSharedDirectoryAddress(vm: vm, path: shared.path))
            }.first ?? nil
        }
    }

    // MARK: - USB accessories

    /// The USB accessories macOS has assigned to Kernova that no guest holds —
    /// or nothing, with the command asking deferred, until the library has
    /// landed, and with the core's refusal recorded where this Mac or build
    /// can't pass accessories through.
    func availableUSBAccessories() -> [VMUSBAccessoryScriptObject] {
        listedUSBAccessories(attachedTo: nil) ?? []
    }

    /// The USB accessories the guest of the VM `vm` identifies holds — none,
    /// with the core's refusal recorded on the command being answered, when
    /// the VM can't be read or this Mac or build can't pass accessories
    /// through.
    func usbAccessories(of vm: UUID) -> [VMUSBAccessoryScriptObject] {
        listedUSBAccessories(attachedTo: vm) ?? []
    }

    /// The accessory `text` names (``NamedSelection``) among the guest's of
    /// the VM `vm` identifies, or among the ones no guest holds for `nil`: the
    /// text of its `id`, or else its name. `nil`, with the refusal recorded on
    /// the command being answered, for text that names none of them, or
    /// several.
    func usbAccessory(named text: String, attachedTo vm: UUID?) -> VMUSBAccessoryScriptObject? {
        guard let listed = listedUSBAccessories(attachedTo: vm) else { return nil }
        return selected(
            NamedSelection(
                text, in: listed, identifiedBy: { $0.uniqueID == text }, name: \.name),
            missing: {
                let item = "USB accessory named \u{201C}\(text)\u{201D}"
                guard let vm else { return CommandError.itemNotFoundOnHost(item: "\(item) available to attach") }
                return self.itemNotFound(item, on: vm)
            },
            ambiguity: {
                NamedSelection.ambiguity(
                    text, among: $0, plural: "USB accessories", namedAloneBy: "identifiers",
                    label: { "\($0.name) (\($0.uniqueID))" })
            })
    }

    /// The core's listing of the accessories the guest of the VM `vm`
    /// identifies holds, or of the ones no guest holds for `nil` — or `nil`,
    /// deferred until the library has landed, or with the refusal recorded on
    /// the command being answered.
    private func listedUSBAccessories(attachedTo vm: UUID?) -> [VMUSBAccessoryScriptObject]? {
        guard let vm else {
            guard !deferUntilLanded() else { return nil }
            return answeringRefusal { try commands.availableUSBAccessories() }?
                .map(VMUSBAccessoryScriptObject.init(available:))
        }
        return answeringRefusal { try commands.usbAccessories(of: .id(vm)) }?
            .compactMap { VMUSBAccessoryScriptObject($0, attachedTo: vm) }
    }

    /// The accessories `verb` addresses, each where it is, as
    /// ``subject(addressedBy:)`` reads VMs — or `nil` with the refusal
    /// recorded on it, `unnamed` for one that addresses nothing.
    func usbAccessories(addressedBy verb: VMScriptCommand, unnamed: String) -> [VMUSBAccessoryScriptObject]? {
        addressed(by: verb, unnamed: unnamed, { try VMScriptSelector.usbAccessories(addressing: $0) })
    }

    /// The one VM `verb`'s argument under `key` names, as a verb's direct
    /// parameter names VMs (``VMScriptSelector/selectors(addressing:in:)``) —
    /// or `nil` with the refusal recorded on it. `purpose` completes "Name one
    /// virtual machine …": "to attach to".
    func virtualMachine(namedBy verb: VMScriptCommand, argument key: String, purpose: String) -> VMSelector? {
        // The dictionary requires the argument, and Cocoa refuses an event
        // that lacks it or gives it as no reference before any command runs
        // (−1701, −1700; observed on macOS 27).
        let named = verb.arguments?[key] as Any
        guard let vms = reading(named, for: verb, { try VMScriptSelector.selectors(addressing: named) }) else {
            return nil
        }
        guard vms.count == 1, let vm = vms.first else {
            verb.refuse(CommandError.invalidArgument("Name one virtual machine \(purpose); this names \(vms.count)."))
            return nil
        }
        return vm
    }

    /// Passes each accessory `registryIDs` names through to the guest of the
    /// VM `vm` names, in order.
    func attach(_ registryIDs: [UInt64], to vm: VMSelector) async throws {
        try await perform(.editUSBAccessory, on: registryIDs, naming: { String($0) }) { registryID in
            try await self.commands.attachUSBAccessory(vm, accessory: registryID)
        }
    }

    /// Takes each attachment back off its VM's guest, in order.
    func detach(_ attachments: [VMUSBAttachment]) async throws {
        try await perform(.editUSBAccessory, on: attachments, naming: \.device.uuidString) { attachment in
            try await self.commands.detachUSBAccessory(.id(attachment.vm), device: attachment.device)
        }
    }

    /// The USB accessories the VM `vm` identifies takes back automatically —
    /// none, with the core's refusal recorded on the command being answered,
    /// when the VM can't be read or this Mac or build can't pass accessories
    /// through.
    func rememberedUSBAccessories(of vm: UUID) -> [VMRememberedUSBAccessoryScriptObject] {
        listedRememberedUSBAccessories(of: vm)?.map { VMRememberedUSBAccessoryScriptObject($0, of: vm) } ?? []
    }

    /// The remembered accessory `text` names among the VM's
    /// (``NamedSelection``): its key, or else its name. `nil`, with the
    /// refusal recorded on the command being answered, for text that names
    /// none of them, or several.
    func rememberedUSBAccessory(named text: String, of vm: UUID) -> VMRememberedUSBAccessoryScriptObject? {
        guard let listed = listedRememberedUSBAccessories(of: vm) else { return nil }
        return selected(
            NamedSelection(text, in: listed, identifiedBy: { $0.key == text }, name: \.name),
            missing: { self.itemNotFound("remembered USB accessory named \u{201C}\(text)\u{201D}", on: vm) },
            ambiguity: {
                NamedSelection.ambiguity(
                    text, among: $0, plural: "remembered USB accessories", namedAloneBy: "keys",
                    label: { "\($0.name) (\($0.key))" })
            }
        ).map { VMRememberedUSBAccessoryScriptObject($0, of: vm) }
    }

    /// The core's listing of the VM `vm` identifies, or `nil` with the refusal
    /// recorded on the command being answered.
    private func listedRememberedUSBAccessories(of vm: UUID) -> [USBPairingSummary]? {
        answeringRefusal { try commands.usbPairings(of: .id(vm)) }
    }

    // MARK: - Networks

    /// What a script that asks to make a virtual machine reads back.
    nonisolated static let cannotMakeVirtualMachine =
        "A script can\u{2019}t make a virtual machine; duplicate one, or import a bundle."

    /// What a script that asks to make a storage disk reads back.
    nonisolated static let cannotMakeStorageDisk = "A script can\u{2019}t make a storage disk."

    /// What a script that asks to make a guest agent reads back.
    nonisolated static let cannotMakeGuestAgent = "A script can\u{2019}t make a guest agent."

    /// What a script that asks to make a setting reads back.
    nonisolated static let cannotMakeSetting = "A script can\u{2019}t make a setting."

    /// What a script that asks to make a USB accessory reads back.
    nonisolated static let cannotMakeUSBAccessory =
        "A script can\u{2019}t make a USB accessory; attach passes one through to a guest."

    /// What a script that asks to make a remembered USB accessory reads back.
    nonisolated static let cannotMakeRememberedUSBAccessory =
        "A script can\u{2019}t make a remembered USB accessory; attaching a USB accessory remembers it."

    /// Every named network, ordered by name — or nothing, with the command
    /// asking deferred, until the library has landed, and with the command
    /// refused while the library's list of networks cannot be read.
    ///
    /// The deferral is what holds a `delete` or a `set` back too: each
    /// evaluates its network specifier through here before it acts, and a
    /// delete run against a library that has not landed would move no VM off
    /// the network.
    func networks() -> [VMNetworkScriptObject] {
        guard !deferUntilLanded() else { return [] }
        return run(.networks, on: nil) { try commands.networks() }?.map(object(for:)) ?? []
    }

    /// One network's read, with the VMs on it.
    private func object(for network: NetworkSummary) -> VMNetworkScriptObject {
        VMNetworkScriptObject(
            network, members: network.members.compactMap { object(for: $0.id) }, gateway: self)
    }

    /// What `make new <class>` creates as an element of the application under
    /// `key`, with the `name` and `kind` its `with properties` record names —
    /// a network, listed by the core before this returns, or `nil` with the
    /// refusal recorded.
    ///
    /// Cocoa inserts what this answers into the element afterwards, which
    /// therefore has nothing left to do. Every other element is refused:
    /// Cocoa's own answer allocates the class with `init()`, which none of
    /// their classes has.
    func makeElement(forKey key: String, name: String?, kind: NSNumber?) -> VMNetworkScriptObject? {
        guard key == VMScriptingRoot.networksKey else {
            refuseToMake(
                key == VMScriptObject.usbAccessoriesKey
                    ? Self.cannotMakeUSBAccessory
                    : VMScriptingRoot.groupKind(forKey: key).map { "A script can\u{2019}t make a \($0.noun)." }
                        ?? Self.cannotMakeVirtualMachine)
            return nil
        }
        return run(.createNetwork, on: nil) {
            object(for: try commands.createNetwork(name: name ?? "", kind: try Self.networkKind(kind)))
        }
    }

    /// The kind a `make`'s `kind` property names, as its enumerator's code: a
    /// NAT network when it names none.
    private static func networkKind(_ code: NSNumber?) throws -> NetworkKind {
        guard let code else { return .nat }
        guard let term = VMScriptNetworkKind(code: code.uint32Value) else {
            throw CommandError.invalidArgument("That is not a kind of network Kernova makes.")
        }
        return term.kind
    }

    /// Renames the network `id` identifies — a script's `set name of network`.
    func renameNetwork(_ id: UUID, to newName: String) {
        run(.renameNetwork, on: id) { try commands.renameNetwork(id.uuidString, to: newName) }
    }

    /// Deletes the network at `index` of ``networks()`` — a script's
    /// `delete network`.
    ///
    /// Cocoa removes an element through this for a `move` too, then inserts it
    /// again (observed on macOS 27: `move network 1 to end of networks` sends
    /// `removeFromNetworksAtIndex:` then `insertInNetworks:atIndex:`), and
    /// that removal would delete the network. The networks are ordered by
    /// name, so there is no move to make: only a delete reaches the core.
    func removeNetwork(at index: Int) {
        guard let command = answering, command is NSDeleteCommand else {
            answering?.refuse(
                Int(errAEEventNotHandled),
                "Kernova orders networks by name, so a script can\u{2019}t move one.")
            return
        }
        guard let listed = run(.deleteNetwork, on: nil, { try commands.networks() }) else { return }
        // Cocoa evaluated the index against this same list on this turn.
        guard listed.indices.contains(index) else {
            Self.logger.log(
                .fault,
                "Asked to remove network \(index, privacy: .public) of \(listed.count, privacy: .public)")
            assertionFailure("Asked to remove network \(index) of \(listed.count)")
            command.refuse(Int(errAEIllegalIndex), "There is no network \(index + 1).")
            return
        }
        let network = listed[index].id
        run(.deleteNetwork, on: network) { try commands.deleteNetwork(network.uuidString) }
    }

    /// Runs a verb Cocoa's own command asked for — inside its specifier
    /// evaluation, where nothing can suspend — logging and recording any
    /// refusal on the command being answered.
    ///
    /// Runs nothing once that command already carries a refusal, so a command
    /// addressing several elements stops at the first, as ``perform(_:on:_:)``
    /// does: Cocoa carries on setting or removing the rest, a later refusal
    /// would overwrite the first, and a script could not tell how far it got.
    ///
    /// `id` names the network or VM the verb addresses, `nil` for a create;
    /// `consenting`, how a script gives a consent the verb refuses without,
    /// where the command being answered can't take `with confirmation`.
    @discardableResult
    private func run<T>(
        _ verb: VMVerb, on id: UUID?, consenting: String? = nil, _ body: () throws -> T
    ) -> T? {
        if let answering, answering.scriptErrorNumber != 0 { return nil }
        do {
            return try body()
        } catch let refusal as CommandError {
            let subject = id.map { " for \($0.uuidString)" } ?? ""
            Self.logger.log(
                .notice,
                "Script \(verb.rawValue, privacy: .public) refused\(subject, privacy: .public): \(refusal.message(in: .log), privacy: .public)"
            )
            if let consenting {
                answering?.refuse(refusal, consenting: consenting)
            } else {
                answering?.refuse(refusal)
            }
            return nil
        } catch {
            answering?.refuse(Int(errAEEventFailed), error.localizedDescription)
            return nil
        }
    }

    // MARK: - Groups

    /// The library's smart groups or folders, as `kind` says, in the order
    /// the sidebar lists them — or nothing, with the command asking deferred,
    /// until the library has landed, and with the command refused while the
    /// library's groups cannot be read.
    func groups(of kind: VMGroupKind) -> [VMGroupScriptObject] {
        listedGroups(of: kind)?.map(object(for:)) ?? []
    }

    /// The first of ``groups(of:)`` that `name` names — by its identifier,
    /// else by name (``NameRule/sibling(identifiedOrNamedBy:in:id:name:)``)
    /// — or `nil`, deferred until the library has landed, or with the core's
    /// refusal recorded on the command being answered.
    func group(_ kind: VMGroupKind, named name: String) -> VMGroupScriptObject? {
        guard let listed = listedGroups(of: kind) else { return nil }
        guard let found = NameRule.sibling(identifiedOrNamedBy: name, in: listed, id: \.id, name: \.name) else {
            answering?.refuse(VMCommandCore.noGroup(VMGroupReference(kind, named: name)))
            return nil
        }
        return object(for: found)
    }

    /// The library's groups of `kind`, in the order the sidebar lists them,
    /// as ``groups(of:)`` lists them and ``group(_:named:)`` looks among them
    /// — `nil`, deferred until the library has landed, or with the core's
    /// refusal recorded on the command being answered.
    private func listedGroups(of kind: VMGroupKind) -> [GroupSummary]? {
        guard !deferUntilLanded() else { return nil }
        return run(.groups, on: nil) { try commands.groups() }?.filter { $0.kind == kind }
    }

    /// Refuses Cocoa's removal of a group of `kind` by index, which a
    /// `delete` or a `move` of one asks for: a script deletes and moves none.
    func refuseToRemove(_ kind: VMGroupKind) {
        guard let command = answering else { return }
        command.refuse(
            Int(errAENotModifiable),
            "A script can\u{2019}t \(command is NSDeleteCommand ? "delete" : "move") a \(kind.noun).")
    }

    /// One group's read, with the VMs in it.
    private func object(for group: GroupSummary) -> VMGroupScriptObject {
        VMGroupScriptObject.make(group, members: group.members.compactMap { object(for: $0.id) }, gateway: self)
    }

    /// Takes `action` on every VM in `group` — a lifecycle command given a
    /// smart group or folder — answering a reference to each VM it was done
    /// to, in the group's order.
    ///
    /// - Throws: The core's refusal of the group, before any VM is acted on,
    ///   and ``VMGroupActionReport/undoneFailure(in:)`` once every VM's turn
    ///   has come, when the action left one it concerned undone.
    func groupAction(_ action: VMGroupAction, on group: VMGroupReference) async throws -> [NSScriptObjectSpecifier] {
        try await perform(action.verb, on: [group], naming: \.name) { group in
            let report = try await self.commands.groupAction(action, on: group)
            if let failure = report.undoneFailure(in: .appleScript) { throw failure }
            return report.done.compactMap { VMScriptObject.specifier(for: $0.vm.id) }
        }.first ?? []
    }

    // MARK: - Dispatch

    /// Runs `verb` on each VM, as ``perform(_:on:naming:_:)`` runs it on each
    /// subject.
    @discardableResult
    private func perform<Answer>(
        _ verb: VMVerb, on selectors: [VMSelector],
        _ body: (VMSelector) async throws -> Answer
    ) async throws -> [Answer] {
        try await perform(verb, on: selectors, naming: \.displayText, body)
    }

    /// Runs `verb` on each subject once the library read has landed, logging
    /// the first refusal under the subject's `name` and rethrowing it, and
    /// answers what it answered for each, in order.
    ///
    /// The verbs run under an ``ActivationRequester`` that only readies the
    /// app, so a verb that surfaces readies it at that moment — a window put up
    /// from a hidden, headless app is on screen — and a refused one leaves it
    /// as it was. A refusal stops the run where it happened: an event
    /// addressing several VMs carries back one error, and finishing the rest
    /// would leave a script unable to tell how far the verb got.
    @discardableResult
    private func perform<Subject: Sendable, Answer>(
        _ verb: VMVerb, on subjects: [Subject], naming name: (Subject) -> String,
        _ body: (Subject) async throws -> Answer
    ) async throws -> [Answer] {
        await readiness.ready()
        return try await ActivationRequester.$current.withValue(ActivationRequester(prepareToSurface)) {
            var answers: [Answer] = []
            for subject in subjects {
                do {
                    answers.append(try await body(subject))
                } catch let failure as CommandError {
                    Self.logger.log(
                        .notice,
                        "Script \(verb.rawValue, privacy: .public) refused for '\(name(subject), privacy: .private)': \(failure.message(in: .log), privacy: .public)"
                    )
                    throw failure
                }
            }
            return answers
        }
    }
}

/// How ``VMScriptingGateway`` reaches the command Cocoa is executing on this
/// thread: reading it, suspending it, and resuming it with its answer.
///
/// A test watches what a command is resumed with, or stands a command it
/// built in for the one Cocoa is executing, through closures of its own.
struct VMScriptCommandRuntime {
    var current: @MainActor () -> NSScriptCommand?
    var suspend: @MainActor (NSScriptCommand) -> Void
    var resume: @MainActor (NSScriptCommand, Any?) -> Void

    /// Cocoa's own.
    static var cocoa: Self {
        Self(
            current: { NSScriptCommand.current() },
            suspend: { $0.suspendExecution() },
            resume: { $0.resumeExecution(withResult: $1) })
    }
}
