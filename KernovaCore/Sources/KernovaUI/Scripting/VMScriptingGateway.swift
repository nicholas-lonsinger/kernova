import Cocoa
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
/// **Readiness:** nothing resolves before the app's first library read has
/// landed, as at every other door — a script that launched Kernova is the
/// ordinary case, and a specifier resolved against a library that has not
/// landed yet reads an empty library as if it were the whole one. A verb
/// suspends its own event and waits; a property read is Cocoa's command, so
/// the element accessors suspend that one and re-issue it once the read lands.
/// A VM's storage disks are measured from their image files, which the main
/// thread never reads, so an evaluation that reaches a disk list runs again
/// once that list is measured: Cocoa's command is suspended the same way and
/// re-issued, and a verb evaluates what it addressed again.
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

    /// Cocoa's own commands suspended until what their answer reads is in
    /// hand, each answered once it is.
    private(set) var suspended: [CommandEvaluation] = []

    /// The evaluation whose pass is running — a suspended command's re-issue,
    /// or a verb's addressing — which every disk-list read the pass reaches
    /// answers from.
    private var evaluating: CommandEvaluation?

    /// The command Cocoa suspended during the first pass it is still
    /// evaluating, which `NSScriptCommand.current()` stops reporting the
    /// moment it is suspended while Cocoa carries on evaluating the rest of
    /// the specifier.
    ///
    /// Open from ``suspend(_:because:)`` until ``answer(_:)`` begins: that is
    /// a main-actor task, and Cocoa runs the whole pass inside one Apple event
    /// callout on the main thread, so it cannot begin before the pass returns
    /// (observed on macOS 27 with a probe app that stalls inside the pass).
    private var openFirstPass: CommandEvaluation?

    /// The command an evaluation this gateway runs is answering — a verb's own
    /// while it addresses its specifier, the fresh instance while a suspended
    /// command is re-issued — which is where a refusal is recorded while Cocoa
    /// has no current command.
    var answeringCommand: NSScriptCommand?

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
            #log(
                Self.logger, .fault,
                "Listed VM \(id.uuidString, privacy: .public) has no info read: \(error.localizedDescription, privacy: .public)"
            )
            assertionFailure("Listed VM \(id.uuidString) has no info read: \(error)")
            return nil
        }
    }

    /// The command Cocoa is running its own first pass of: the one it is
    /// executing, or the one it suspended earlier in the same pass.
    ///
    /// A command Cocoa is executing is always the newer: one that arrives
    /// before ``openFirstPass`` closes is reported until it is itself
    /// suspended, and then replaces it.
    private var firstPass: NSScriptCommand? {
        runtime.current() ?? openFirstPass?.command
    }

    /// The command whatever is read or written now answers for — where every
    /// refusal is recorded, and what ``run(_:on:_:)`` holds a write back on:
    /// the one an evaluation of this gateway's own is answering while it runs
    /// a pass, Cocoa's first pass otherwise.
    private var answering: NSScriptCommand? {
        evaluating != nil ? answeringCommand : (firstPass ?? answeringCommand)
    }

    /// Records a `make` the dictionary refuses on the command being answered.
    ///
    /// `NSScriptCommand.current()` reports no command once the `make` is
    /// suspended, and none while it is re-issued.
    func refuseToMake(_ message: String) {
        answering?.refuse(Int(errAECantHandleClass), message)
    }

    /// The storage disks of the VM `vm` identifies, in attachment order, from
    /// the measurement the running evaluation holds.
    ///
    /// Every evaluation that can reach a disk list runs under
    /// ``evaluate(_:_:)``: a verb's addressing, and a re-issued command. A
    /// first pass of Cocoa's holds no measurement, so its command is
    /// suspended, once, and answered by such an evaluation. A list not
    /// measured yet answers nothing for now, and the evaluation measures it
    /// before its next pass.
    ///
    /// Cocoa evaluates the rest of a first pass after its command is
    /// suspended, and a `whose` test can match the empty list answered for
    /// now — so the pass is refused, which holds back every write left in it
    /// (``run(_:on:_:)``). Only a pass that reads every list measured answers
    /// the script, and its outcome replaces the refusal.
    func storageDisks(of vm: UUID) -> [VMStorageDiskScriptObject] {
        let evaluation: CommandEvaluation
        if let evaluating {
            evaluation = evaluating
        } else if let command = firstPass {
            evaluation = suspend(command, because: "reached a storage disk list")
        } else {
            #log(
                Self.logger, .fault,
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

    /// The refusal a pass that read a disk list unmeasured carries, which the
    /// pass that answers the script replaces.
    nonisolated static let measuringStorageDisks = "Kernova is measuring the storage disks this reads."

    // MARK: - Evaluations

    /// One command's evaluation: the storage disks measured for it, and the
    /// lists a pass reached unmeasured.
    ///
    /// The measurements live only as long as the evaluation, so no command
    /// answers from another's.
    @MainActor
    final class CommandEvaluation {
        /// The command the evaluation answers.
        let command: NSScriptCommand
        /// Each reached VM's storage disks, as measured for this command.
        fileprivate(set) var measured: [UUID: [StorageDiskSummary]] = [:]
        /// The VMs whose disk lists a pass reached unmeasured, in the order it
        /// reached them.
        fileprivate(set) var unmeasured: [UUID] = []

        init(_ command: NSScriptCommand) {
            self.command = command
        }
    }

    /// Runs `pass` until one reaches no disk list unmeasured, measuring what
    /// each pass reached before the next, and returns the last pass's outcome.
    ///
    /// Cocoa stops a failed evaluation early, so a pass can reach a list the
    /// one before never got to. Each pass but the last measures a VM no earlier
    /// one did, so the passes end.
    private func evaluate<Answer, Failure: Error>(
        _ evaluation: CommandEvaluation, _ pass: () throws(Failure) -> Answer
    ) async throws(Failure) -> Answer {
        while true {
            let reached = evaluation.unmeasured
            evaluation.unmeasured = []
            for vm in reached {
                evaluation.measured[vm] = await measureStorageDisks(of: vm)
            }
            evaluating = evaluation
            let outcome: Result<Answer, Failure>
            do {
                outcome = .success(try pass())
            } catch {
                outcome = .failure(error)
            }
            evaluating = nil
            if evaluation.unmeasured.isEmpty { return try outcome.get() }
        }
    }

    /// The storage disks of the VM `vm` identifies, measured off the main
    /// thread — none for a VM that has left the library.
    ///
    /// The next pass evaluates against the library as it stands, so a
    /// departed VM is reached again only if it is listed again.
    private func measureStorageDisks(of vm: UUID) async -> [StorageDiskSummary] {
        do {
            return try await commands.storageDisks(of: .id(vm))
        } catch {
            #log(
                Self.logger, .notice,
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
        guard !readiness.hasLanded, let command = firstPass else { return false }
        suspend(command, because: "arrived before the library read landed")
        return true
    }

    /// The evaluation `command` is suspended under, suspending it first when
    /// it is not yet: one first pass can reach the library and its disk lists
    /// many times, and the command is suspended and answered once.
    ///
    /// Cocoa evaluates a specifier inside the Apple event's own callout,
    /// through synchronous KVC with no suspension of its own to await in — but
    /// the command being executed is `NSScriptCommand.current()`, and a
    /// command can be suspended from anywhere on its own stack. From then on
    /// the pass reaches it as ``openFirstPass``.
    @discardableResult
    private func suspend(_ command: NSScriptCommand, because reason: String) -> CommandEvaluation {
        if let held = suspended.first(where: { $0.command === command }) { return held }
        let evaluation = CommandEvaluation(command)
        suspended.append(evaluation)
        #log(
            Self.logger, .notice,
            "A \(command.commandDescription.commandName, privacy: .public) \(reason, privacy: .public); suspended until it can be answered"
        )
        runtime.suspend(command)
        openFirstPass = evaluation
        Task { await answer(evaluation) }
        return evaluation
    }

    /// Resumes a suspended command with its answer, once its first pass has
    /// returned, the library has landed, and every disk list its re-issue
    /// reaches is measured.
    private func answer(_ evaluation: CommandEvaluation) async {
        if openFirstPass === evaluation { openFirstPass = nil }
        await readiness.ready()
        let result = await evaluate(evaluation) { reissue(evaluation.command) }
        suspended.removeAll { $0 === evaluation }
        #log(
            Self.logger, .notice,
            "Answering the suspended \(evaluation.command.commandDescription.commandName, privacy: .public)"
        )
        runtime.resume(evaluation.command, result)
    }

    /// Runs `command` again against the landed library, recording on it what
    /// the script reads back, and returns the result to resume it with.
    ///
    /// A fresh instance from the same description, because a command evaluates
    /// its receivers once and keeps the result. The specifiers are shared with
    /// the first pass and keep its failure, which a re-evaluation repeats
    /// rather than retries, so that is cleared first.
    ///
    /// Cocoa's Apple event handling turns receivers `execute()` could not
    /// evaluate into the script error itself, after `execute()` returns, and a
    /// resumed command gets none of that — so it is turned here, by the same
    /// rule. `execute()` leaves nothing that tells a failed evaluation from an
    /// empty one: it reports no receivers for either, and a specifier that
    /// evaluated to nothing keeps an error code whether or not it failed. The
    /// evaluation itself does — `nil` against an empty list — so the receivers
    /// are evaluated once beforehand to tell the two apart. `exists` is the one
    /// command whose answer *is* that failure, and keeps its `false`.
    ///
    /// One pass of ``evaluate(_:_:)``: a disk-list read it reaches outside one
    /// has no measurement to answer from.
    func reissue(_ command: NSScriptCommand) -> Any? {
        let answer = command.commandDescription.createCommandInstance()
        answer.directParameter = command.directParameter
        answer.receiversSpecifier = command.receiversSpecifier
        answer.arguments = command.arguments
        answeringCommand = answer
        defer { answeringCommand = nil }
        let receivers = answer.receiversSpecifier
        Self.clearEvaluationFailure(receivers)
        let failure = receivers.flatMap { receivers -> VMScriptEvaluationFailure? in
            receivers.objectsByEvaluatingSpecifier == nil ? VMScriptEvaluationFailure(receivers) : nil
        }
        Self.clearEvaluationFailure(receivers)
        let result = answer.execute()
        if answer.scriptErrorNumber == 0, !(answer is NSExistsCommand), let failure {
            failure.record(on: answer, addressing: receivers)
        }
        command.scriptErrorNumber = answer.scriptErrorNumber
        command.scriptErrorString = answer.scriptErrorString
        command.scriptErrorOffendingObjectDescriptor = answer.scriptErrorOffendingObjectDescriptor
        return result
    }

    /// Clears the failure a past evaluation left on `specifier` and every
    /// container above it.
    static func clearEvaluationFailure(_ specifier: NSScriptObjectSpecifier?) {
        var link = specifier
        while let specifier = link {
            specifier.evaluationErrorNumber = 0
            link = specifier.container
        }
    }

    // MARK: - Addressing

    /// The VMs `parameter` addresses — one specifier, or a list of them — read
    /// once the library has landed and every disk list it reaches is measured,
    /// with `command` answering for whatever the evaluation refuses.
    ///
    /// The verb has already suspended its own event, so the passes need no
    /// Cocoa suspension: each starts from what the one before left — the
    /// specifiers' evaluation failure, and the command's refusal — cleared.
    func address(_ parameter: Any, for command: NSScriptCommand) async throws -> [VMSelector] {
        await readiness.ready()
        return try await evaluate(CommandEvaluation(command)) {
            Self.clearEvaluationFailures(in: parameter)
            command.scriptErrorNumber = 0
            command.scriptErrorString = nil
            answeringCommand = command
            defer { answeringCommand = nil }
            return try VMScriptSelector.selectors(addressing: parameter)
        }
    }

    /// Clears the failure a past evaluation left on what `parameter` addresses
    /// — one specifier, or a list of them.
    private static func clearEvaluationFailures(in parameter: Any) {
        if let specifier = parameter as? NSScriptObjectSpecifier {
            clearEvaluationFailure(specifier)
            return
        }
        for case let specifier as NSScriptObjectSpecifier in parameter as? [Any] ?? [] {
            clearEvaluationFailure(specifier)
        }
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
        guard key == AppDelegate.networksKey else {
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
            #log(
                Self.logger, .fault,
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
            #log(
                Self.logger, .notice,
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
                    #log(
                        Self.logger, .notice,
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
/// Cocoa resumes only a command an Apple event suspended, so a test answers a
/// command it built through closures of its own.
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
