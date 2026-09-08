import Cocoa
import KernovaKit
import os

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
    private static let logger = Logger(subsystem: "app.kernova", category: "VMScriptingGateway")

    private let commands: any VMCommanding
    /// The app's first library read, shared with every other front door.
    private let readiness: LibraryReadiness
    /// Brings the app forward for a surface something outside the process asked
    /// for.
    private let activate: @MainActor () -> Void

    /// Cocoa's own commands suspended on a read that arrived before the library
    /// landed, each answered once it has.
    private(set) var coldReads: [NSScriptCommand] = []

    /// The command an evaluation this gateway runs is answering — a verb's own
    /// while it addresses its specifier, the fresh instance while a cold read
    /// is re-issued — which is where a refusal is recorded while Cocoa has no
    /// current command.
    var answeringCommand: NSScriptCommand?

    /// What stands in for `NSScriptCommand.current()`. Tests only, which have
    /// no command in flight.
    var currentCommandForTesting: (@MainActor () -> NSScriptCommand?)?

    init(
        commands: any VMCommanding, readiness: LibraryReadiness,
        activate: @escaping @MainActor () -> Void
    ) {
        self.commands = commands
        self.readiness = readiness
        self.activate = activate
    }

    // MARK: - Reads

    /// Every VM in the library, in the order the sidebar shows them — or
    /// nothing, with the command asking deferred, until the library has landed.
    func virtualMachines() -> [VMScriptObject] {
        guard !deferUntilLanded() else { return [] }
        return commands.list().compactMap { object(for: $0.id) }
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
            Self.logger.fault(
                "Listed VM \(id.uuidString, privacy: .public) has no info read: \(error.localizedDescription, privacy: .public)"
            )
            assertionFailure("Listed VM \(id.uuidString) has no info read: \(error)")
            return nil
        }
    }

    /// The command Cocoa is executing on this thread, if any.
    private var executing: NSScriptCommand? {
        currentCommandForTesting?() ?? NSScriptCommand.current()
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
        Self.logger.notice(
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
        Self.logger.notice(
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
            failure.record(on: answer)
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

    func start(_ selectors: [VMSelector], recoveryMode: Bool) async throws {
        try await perform(.start, surfacing: true, on: selectors) {
            try await self.commands.start($0, recovery: recoveryMode)
        }
    }

    /// Stops each VM the way `method` names, supplying `confirmed` as the
    /// consent a destructive stop refuses without.
    ///
    /// The consent round trip is ``VMConsentPolicy``'s, with nothing to present:
    /// a script has already said whether it consents, so the prompt the core
    /// describes is either answered by the flag it was given or thrown back as
    /// the refusal it is.
    func stop(
        _ selectors: [VMSelector], method: StopDisposition, confirmed: Bool,
        givingUpAfter timeout: TimeInterval?
    ) async throws {
        try await perform(.stop, surfacing: false, on: selectors) { selector in
            try await VMConsentPolicy.run(
                prompting: { prompt in
                    guard confirmed else { throw CommandError.confirmationRequired(prompt) }
                },
                { consented in
                    try await self.commands.stop(
                        selector, disposition: method, confirmed: consented, timeout: timeout)
                })
        }
    }

    func restart(_ selectors: [VMSelector], givingUpAfter timeout: TimeInterval?) async throws {
        try await perform(.restart, surfacing: true, on: selectors) {
            try await self.commands.restart($0, presentation: .surface, timeout: timeout)
        }
    }

    func pause(_ selectors: [VMSelector]) async throws {
        try await perform(.pause, surfacing: false, on: selectors) {
            try await self.commands.pause($0)
        }
    }

    func resume(_ selectors: [VMSelector]) async throws {
        try await perform(.resume, surfacing: true, on: selectors) {
            try await self.commands.resume($0)
        }
    }

    func suspend(_ selectors: [VMSelector]) async throws {
        try await perform(.suspend, surfacing: false, on: selectors) {
            try await self.commands.suspend($0)
        }
    }

    func reveal(_ selectors: [VMSelector]) async throws {
        try await perform(.reveal, surfacing: true, on: selectors) {
            try self.commands.reveal($0)
        }
    }

    // MARK: - Dispatch

    /// Runs `verb` on each VM once the library read has landed, logging and
    /// rethrowing the first refusal.
    ///
    /// A `surfacing` verb brings the app forward first, so the window it puts
    /// up opens in front of the person who ran the script rather than behind
    /// Script Editor. A refusal stops the run where it happened: an event
    /// addressing several VMs carries back one error, and finishing the rest
    /// would leave a script unable to tell how far the verb got.
    private func perform(
        _ verb: VMVerb, surfacing: Bool, on selectors: [VMSelector],
        _ body: (VMSelector) async throws -> Void
    ) async throws {
        await readiness.ready()
        if surfacing, !selectors.isEmpty { activate() }
        for selector in selectors {
            do {
                try await body(selector)
            } catch let failure as CommandError {
                Self.logger.notice(
                    "Script \(verb.rawValue, privacy: .public) refused for '\(selector.displayText, privacy: .private)': \(failure.message, privacy: .public)"
                )
                throw failure
            }
        }
    }
}
