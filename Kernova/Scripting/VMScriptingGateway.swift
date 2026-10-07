import Cocoa
import KernovaKit
import KernovaLogging

/// The Apple event front door: everything Script Editor, Automator, and
/// `osascript` ask of Kernova passes through here and reaches ``VMCommanding``.
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

    private let commands: any VMCommanding
    /// The app's first library read, shared with every other front door.
    private let readiness: LibraryReadiness
    /// Readies the app to put up a surface something outside the process asked
    /// for, without activating it: a script that wants Kernova in front says
    /// `activate`.
    private let prepareToSurface: @MainActor @Sendable () -> Void

    /// Cocoa's own commands suspended on a read that arrived before the library
    /// landed, each answered once it has.
    private(set) var coldReads: [NSScriptCommand] = []

    /// The command an evaluation this gateway runs is answering — a verb's own
    /// while it addresses its specifier, the fresh instance while a cold read
    /// is re-issued — which is where a refusal is recorded while Cocoa has no
    /// current command.
    var answeringCommand: NSScriptCommand?

    #if DEBUG
    /// What stands in for `NSScriptCommand.current()`. Tests only, which have
    /// no command in flight.
    var currentCommandForTesting: (@MainActor () -> NSScriptCommand?)?
    #endif

    init(
        commands: any VMCommanding, readiness: LibraryReadiness,
        prepareToSurface: @escaping @MainActor @Sendable () -> Void
    ) {
        self.commands = commands
        self.readiness = readiness
        self.prepareToSurface = prepareToSurface
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
            return VMScriptObject(try commands.info(.name(name)))
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
            return VMScriptObject(try commands.info(.id(id)))
        } catch {
            #log(
                Self.logger, .fault,
                "Listed VM \(id.uuidString, privacy: .public) has no info read: \(error.localizedDescription, privacy: .public)"
            )
            assertionFailure("Listed VM \(id.uuidString) has no info read: \(error)")
            return nil
        }
    }

    /// The command Cocoa is executing on this thread, if any.
    private var executing: NSScriptCommand? {
        #if DEBUG
        return currentCommandForTesting?() ?? NSScriptCommand.current()
        #else
        return NSScriptCommand.current()
        #endif
    }

    /// The command a read is being answered for: the one Cocoa is executing,
    /// or the one an evaluation of this gateway's own is answering.
    private var answering: NSScriptCommand? {
        executing ?? answeringCommand
    }

    // MARK: - A read before the library has landed

    /// Suspends the command Cocoa is evaluating a specifier for, when the
    /// library it evaluates against has not landed, and answers it once it has.
    ///
    /// Cocoa evaluates a specifier inside the Apple event's own callout,
    /// through synchronous KVC with no suspension of its own to await in — but
    /// the command being executed is `NSScriptCommand.current()`, and a
    /// command can be suspended from anywhere on its own stack.
    /// ``answer(coldRead:)`` supplies what it answers with.
    ///
    /// - Returns: Whether the read was deferred, which is the caller's cue to
    ///   answer nothing now.
    private func deferUntilLanded() -> Bool {
        guard !readiness.hasLanded, let command = executing else { return false }
        // One evaluation can read the element more than once.
        if coldReads.contains(where: { $0 === command }) { return true }
        coldReads.append(command)
        #log(
            Self.logger, .notice,
            "A \(command.commandDescription.commandName, privacy: .public) arrived before the library read landed; suspended until it does"
        )
        command.suspendExecution()
        Task { await answer(coldRead: command) }
        return true
    }

    /// Resumes a suspended command with its answer once the library has landed.
    private func answer(coldRead command: NSScriptCommand) async {
        await readiness.ready()
        let result = reissue(command)
        coldReads.removeAll { $0 === command }
        #log(
            Self.logger, .notice,
            "The library read landed; answering the \(command.commandDescription.commandName, privacy: .public) that waited on it"
        )
        command.resumeExecution(withResult: result)
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
    /// once the library has landed, with `command` answering for whatever the
    /// evaluation refuses.
    func address(_ parameter: Any, for command: NSScriptCommand) async throws -> [VMSelector] {
        await readiness.ready()
        answeringCommand = command
        defer { answeringCommand = nil }
        return try VMScriptSelector.selectors(addressing: parameter)
    }

    // MARK: - Lifecycle

    /// `remedy` is the change to each VM's network a MAC address conflict
    /// takes, `nil` for none — the script's `resolving MAC conflict by`.
    func start(
        _ selectors: [VMSelector], recoveryMode: Bool, confirmation: Bool,
        resolvingMACConflictBy remedy: MACAddressRemedy? = nil
    ) async throws {
        try await perform(.start, on: selectors) { selector in
            try await Self.consenting(confirmation) { consent in
                try await self.commands.start(
                    selector, recovery: recoveryMode, consent: consent, macAddressRemedy: remedy)
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
        _ selectors: [VMSelector], confirmation: Bool, givingUpAfter timeout: TimeInterval?,
        resolvingMACConflictBy remedy: MACAddressRemedy? = nil
    ) async throws {
        try await perform(.restart, on: selectors) { selector in
            try await Self.consenting(confirmation) { consent in
                try await self.commands.restart(
                    selector, timeout: timeout, consent: consent, macAddressRemedy: remedy)
            }
        }
    }

    func pause(_ selectors: [VMSelector]) async throws {
        try await perform(.pause, on: selectors) {
            try await self.commands.pause($0)
        }
    }

    func resume(
        _ selectors: [VMSelector], confirmation: Bool,
        resolvingMACConflictBy remedy: MACAddressRemedy? = nil
    ) async throws {
        try await perform(.resume, on: selectors) { selector in
            try await Self.consenting(confirmation) { consent in
                try await self.commands.resume(selector, consent: consent, macAddressRemedy: remedy)
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

    // MARK: - Networks

    /// What a script that asks to make a virtual machine reads back.
    nonisolated static let cannotMakeVirtualMachine = "A script can\u{2019}t make a virtual machine."

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
            answering?.refuse(Int(errAECantHandleClass), Self.cannotMakeVirtualMachine)
            return nil
        }
        return run(.createNetwork, on: nil) {
            object(for: try commands.createNetwork(name: name ?? "", kind: try Self.networkKind(kind)))
        }
    }

    /// The kind a `make`'s `kind` property names, as its enumerator's code: a
    /// NAT network when it names none.
    private static func networkKind(_ code: NSNumber?) throws -> NetworkKind {
        guard let code else { return .shared }
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
    ///
    /// A delete addressing several networks stops at the first refusal, as a
    /// verb addressing several VMs does: Cocoa carries on removing the rest,
    /// and a script could not tell how far it got.
    func removeNetwork(at index: Int) {
        guard let command = answering, command is NSDeleteCommand else {
            answering?.refuse(
                Int(errAEEventNotHandled),
                "Kernova orders networks by name, so a script can\u{2019}t move one.")
            return
        }
        guard command.scriptErrorNumber == 0,
            let listed = run(.deleteNetwork, on: nil, { try commands.networks() })
        else { return }
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
    /// `id` names the network the verb addresses, `nil` for a create.
    @discardableResult
    private func run<T>(_ verb: VMVerb, on id: UUID?, _ body: () throws -> T) -> T? {
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
