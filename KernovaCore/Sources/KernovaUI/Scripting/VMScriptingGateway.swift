import Cocoa
import KernovaCommandModel
import KernovaCore
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
/// disks, which are measured from their image files off the main thread — is
/// suspended, and answered from a later dispatch of the same event to this
/// process, once what it read is in hand (``answer(_:)``). A verb's own
/// dispatch only suspends it: what it addresses is read in such a dispatch,
/// and the verb runs once that read is answered.
/// **Addressing:** a script names a VM the way a person does, so this addresses
/// VMs by ``VMSelector/name(_:)`` as readily as by identifier and the ambiguity
/// refusal can fire here — on a verb and on a read alike.
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
    /// every disk-list read the dispatch reaches answers from.
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

    /// The one VM called `name`, resolved by the core — or nothing, with the
    /// command asking deferred, until the library has landed.
    ///
    /// Cocoa's own name lookup answers with the first match, which for two VMs
    /// sharing a display name is whichever the library happens to list first.
    /// The core refuses that name instead, with the candidates, and a name no
    /// VM answers to in its own words too — both recorded on the command being
    /// answered, so the script reads the refusal every other door shows rather
    /// than a bare "can't get".
    func virtualMachine(named name: String) -> VMScriptObject? {
        guard !deferUntilLanded() else { return nil }
        do {
            return VMScriptObject(try commands.info(.name(name)), gateway: self)
        } catch let refusal as CommandError {
            answering?.refuse(refusal)
            return nil
        } catch {
            answering?.refuse(Int(errAEEventFailed), error.localizedDescription)
            return nil
        }
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
    /// the measurement the evaluation being answered holds.
    ///
    /// A dispatch of a script's own event holds no measurement, so its command
    /// is suspended, once, and answered by dispatches that do. A list not
    /// measured yet answers nothing for now, and the evaluation measures it
    /// before its next dispatch.
    ///
    /// Cocoa evaluates the rest of a dispatch after its command is suspended,
    /// and a `whose` test can match the empty list answered for now — so the
    /// dispatch is refused, which holds back every write left in it
    /// (``run(_:on:_:)``). Only a dispatch that reads every list measured
    /// answers the script, and its outcome replaces the refusal.
    func storageDisks(of vm: UUID) -> [VMStorageDiskScriptObject] {
        let evaluation: CommandEvaluation
        if let evaluating {
            evaluation = evaluating
        } else if let command = answering {
            evaluation = suspend(command, because: "reached a storage disk list")
        } else {
            Self.logger.log(
                .fault,
                "Storage disks of \(vm.uuidString, privacy: .public) read outside any script command's evaluation")
            assertionFailure("Storage disks of \(vm.uuidString) read outside any script command's evaluation")
            return []
        }
        guard let disks = evaluation.measured[vm] else {
            if !evaluation.unmeasured.contains(vm) { evaluation.unmeasured.append(vm) }
            answering?.refuse(Int(errAEEventFailed), Self.measuringStorageDisks)
            return []
        }
        return disks.map { VMStorageDiskScriptObject($0, of: vm) }
    }

    /// The refusal a dispatch that read a disk list unmeasured carries, which
    /// the dispatch that answers the script replaces.
    nonisolated static let measuringStorageDisks = "Kernova is measuring the storage disks this reads."

    /// The refusal a suspended command's own dispatch carries, which the
    /// dispatch that answers the script replaces.
    nonisolated static let answeringLater = "Kernova answers this once what it reads is in hand."

    // MARK: - Evaluations

    /// One suspended command's evaluation: the event every dispatch of it
    /// sends again, the storage disks measured for it, the lists a dispatch
    /// reached unmeasured, and — for a verb — what the last dispatch
    /// addressed.
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
        fileprivate(set) var measured: [UUID: [StorageDiskSummary]] = [:]
        /// The VMs whose disk lists a dispatch reached unmeasured, in the order
        /// it reached them.
        fileprivate(set) var unmeasured: [UUID] = []
        /// The VMs a verb's last dispatch addressed, `nil` when it refused.
        fileprivate(set) var addressed: [VMSelector]?

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

    /// Dispatches `evaluation`'s event until a dispatch reaches no disk list
    /// unmeasured, measuring what each one reached before the next, and returns
    /// the last one's reply.
    ///
    /// Cocoa stops a failed evaluation early, so a dispatch can reach a list
    /// the one before never got to. Each dispatch but the last measures a VM
    /// no earlier one did, so the dispatches end.
    private func evaluate(_ evaluation: CommandEvaluation) async -> Reply {
        while true {
            let reached = evaluation.unmeasured
            evaluation.unmeasured = []
            for vm in reached {
                evaluation.measured[vm] = await measureStorageDisks(of: vm)
            }
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
    /// that reaches every disk list measured — or, for a verb, by running it
    /// on what that dispatch addressed.
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
        guard let verb = command as? VMScriptCommand else {
            runtime.resume(command, reply.resumption(for: command))
            return
        }
        if verb.scriptErrorNumber == 0, let selectors = evaluation.addressed {
            await verb.perform(self, on: selectors)
        }
        runtime.resume(verb, nil)
    }

    // MARK: - Verbs

    /// Takes `verb`'s event over: a dispatch of this gateway's own reads what
    /// it addresses, and any other is suspended, to run the verb once that
    /// read is answered.
    ///
    /// Cocoa evaluates no receivers for a Kernova verb (``VMScriptCommand``),
    /// so nothing is read before this, and a name reaches the core as a name.
    func execute(_ verb: VMScriptCommand) {
        guard let evaluating else {
            suspend(verb, because: "arrived")
            return
        }
        evaluating.addressed = address(verb)
    }

    /// The VMs `verb` addresses — its direct parameter, one specifier or a
    /// list of them, or the `tell` block's subject, which Cocoa promotes into
    /// the same slot — or `nil` with the refusal recorded on it.
    private func address(_ verb: VMScriptCommand) -> [VMSelector]? {
        guard let addressed = verb.directParameter ?? verb.receiversSpecifier else {
            verb.refuse(
                Int(errAEWrongNumberArgs),
                "Name the virtual machine to \(verb.commandDescription.commandName).")
            return nil
        }
        do {
            return try VMScriptSelector.selectors(addressing: addressed)
        } catch let failure as VMScriptEvaluationFailure {
            failure.record(on: verb, addressing: addressed)
        } catch let refusal as CommandError {
            verb.refuse(refusal)
        } catch {
            verb.refuse(Int(errAEEventFailed), error.localizedDescription)
        }
        return nil
    }

    // MARK: - Lifecycle

    func start(_ selectors: [VMSelector], recoveryMode: Bool, confirmation: Bool) async throws {
        try await perform(.start, on: selectors) { selector in
            try await Self.consenting(confirmation) { consent in
                try await self.commands.start(selector, recovery: recoveryMode, consent: consent)
            }
        }
    }

    /// Stops each VM the way `method` names, with `confirmation` as the
    /// consent a destructive stop refuses without.
    func stop(
        _ selectors: [VMSelector], method: StopDisposition, confirmation: Bool,
        givingUpAfter timeout: TimeInterval?
    ) async throws {
        try await perform(.stop, on: selectors) { selector in
            try await Self.consenting(confirmation) { consent in
                try await self.commands.stop(
                    selector, disposition: method, consent: consent, timeout: timeout)
            }
        }
    }

    /// Runs `verb` with the consent a script's `with confirmation` gives:
    /// every confirmation it asks for, or none.
    ///
    /// The round trip is ``VMConsentPolicy``'s, with nothing to present: a
    /// script has already said whether it consents, so each prompt the core
    /// describes is either answered by the flag or thrown back as the refusal
    /// it is.
    private static func consenting(
        _ confirmation: Bool, _ verb: (Consent) async throws -> Void
    ) async throws {
        try await VMConsentPolicy.run(
            prompting: { prompt in
                guard confirmation else { throw CommandError.confirmationRequired(prompt) }
            },
            verb)
    }

    func restart(
        _ selectors: [VMSelector], confirmation: Bool, givingUpAfter timeout: TimeInterval?
    ) async throws {
        try await perform(.restart, on: selectors) { selector in
            try await Self.consenting(confirmation) { consent in
                try await self.commands.restart(selector, timeout: timeout, consent: consent)
            }
        }
    }

    func pause(_ selectors: [VMSelector]) async throws {
        try await perform(.pause, on: selectors) {
            try await self.commands.pause($0)
        }
    }

    func resume(_ selectors: [VMSelector], confirmation: Bool) async throws {
        try await perform(.resume, on: selectors) { selector in
            try await Self.consenting(confirmation) { consent in
                try await self.commands.resume(selector, consent: consent)
            }
        }
    }

    func suspend(_ selectors: [VMSelector]) async throws {
        try await perform(.suspend, on: selectors) {
            try await self.commands.suspend($0)
        }
    }

    func reveal(_ selectors: [VMSelector]) async throws {
        try await perform(.reveal, on: selectors) {
            try self.commands.reveal($0)
        }
    }

    // MARK: - Configuration

    /// Sets `key` of the VM `id` identifies to `value` — a script's `set` of a
    /// writable `virtual machine` property.
    ///
    /// A script's `set` carries no `with confirmation`, so nothing it writes
    /// is given consent.
    func setConfiguration(_ id: UUID, key: VMConfigurationKey, value: String) {
        run(.setConfiguration, on: id) {
            try commands.setConfiguration(.id(id), assignments: [key.assigning(value)], consent: .none)
        }
    }

    // MARK: - Networks

    /// What a script that asks to make a virtual machine reads back.
    nonisolated static let cannotMakeVirtualMachine = "A script can\u{2019}t make a virtual machine."

    /// What a script that asks to make a storage disk reads back.
    nonisolated static let cannotMakeStorageDisk = "A script can\u{2019}t make a storage disk."

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
    /// Cocoa's own answer allocates the class with `init()`, which
    /// ``VMScriptObject`` does not have.
    func makeElement(forKey key: String, name: String?, kind: NSNumber?) -> VMNetworkScriptObject? {
        guard key == VMScriptingRoot.networksKey else {
            refuseToMake(Self.cannotMakeVirtualMachine)
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
    /// `id` names the network or VM the verb addresses, `nil` for a create.
    @discardableResult
    private func run<T>(_ verb: VMVerb, on id: UUID?, _ body: () throws -> T) -> T? {
        if let answering, answering.scriptErrorNumber != 0 { return nil }
        do {
            return try body()
        } catch let refusal as CommandError {
            let subject = id.map { " for \($0.uuidString)" } ?? ""
            Self.logger.log(
                .notice,
                "Script \(verb.rawValue, privacy: .public) refused\(subject, privacy: .public): \(refusal.message, privacy: .public)"
            )
            answering?.refuse(refusal)
            return nil
        } catch {
            answering?.refuse(Int(errAEEventFailed), error.localizedDescription)
            return nil
        }
    }

    // MARK: - Dispatch

    /// Runs `verb` on each VM once the library read has landed, logging and
    /// rethrowing the first refusal.
    ///
    /// The verbs run under an ``ActivationRequester`` that only readies the
    /// app, so a verb that surfaces readies it at that moment — a window put up
    /// from a hidden, headless app is on screen — and a refused one leaves it
    /// as it was. A refusal stops the run where it happened: an event
    /// addressing several VMs carries back one error, and finishing the rest
    /// would leave a script unable to tell how far the verb got.
    private func perform(
        _ verb: VMVerb, on selectors: [VMSelector],
        _ body: (VMSelector) async throws -> Void
    ) async throws {
        await readiness.ready()
        try await ActivationRequester.$current.withValue(ActivationRequester(prepareToSurface)) {
            for selector in selectors {
                do {
                    try await body(selector)
                } catch let failure as CommandError {
                    Self.logger.log(
                        .notice,
                        "Script \(verb.rawValue, privacy: .public) refused for '\(selector.displayText, privacy: .private)': \(failure.message, privacy: .public)"
                    )
                    throw failure
                }
            }
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
