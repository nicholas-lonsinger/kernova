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
    private var coldReads: [NSScriptCommand] = []

    /// The command standing in for a suspended one while its read is re-issued
    /// — what a refusal is recorded on while Cocoa has no current command.
    var reissued: NSScriptCommand?

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

    /// The command a read is being answered for: the one Cocoa is executing,
    /// or the one re-issued for a read that arrived before the library landed.
    private var answering: NSScriptCommand? {
        NSScriptCommand.current() ?? reissued
    }

    // MARK: - A read before the library has landed

    /// Suspends the command Cocoa is evaluating a specifier for, when the
    /// library it evaluates against has not landed, and answers it once it has.
    ///
    /// Cocoa evaluates a specifier inside the Apple event's own callout,
    /// through synchronous KVC with no suspension of its own to await in — but
    /// the command being executed is `NSScriptCommand.current()`, and a
    /// command can be suspended from anywhere on its own stack. The evaluation
    /// then finishes against an empty library and its result is discarded, as
    /// a suspended command's is; ``answer(coldRead:)`` supplies the real one.
    ///
    /// - Returns: Whether the read was deferred, which is the caller's cue to
    ///   answer nothing now.
    private func deferUntilLanded() -> Bool {
        guard !readiness.hasLanded, let command = NSScriptCommand.current() else { return false }
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

    /// Re-issues a suspended command once the library has landed, and resumes
    /// it with the answer.
    ///
    /// A fresh instance from the same description, because a command evaluates
    /// its receivers once and keeps the result: re-executing the suspended one
    /// answers from the empty library its first pass saw. The specifiers are
    /// shared with that first pass and keep its failure, which a re-evaluation
    /// repeats rather than retries, so that is cleared first.
    ///
    /// What `execute()` leaves behind is the command's own error and the
    /// specifiers': Cocoa's Apple event handling turns the latter into the
    /// script error itself, after `execute()` returns, and a resumed command
    /// gets none of that — so it is turned here, by the same rule. `exists` is
    /// the one command whose answer *is* that failure, and keeps its `false`.
    private func answer(coldRead command: NSScriptCommand) async {
        await readiness.ready()
        let answer = command.commandDescription.createCommandInstance()
        answer.directParameter = command.directParameter
        answer.receiversSpecifier = command.receiversSpecifier
        answer.arguments = command.arguments
        clearEvaluationFailure(answer.receiversSpecifier)
        clearEvaluationFailure(answer.directParameter as? NSScriptObjectSpecifier)
        reissued = answer
        let result = answer.execute()
        reissued = nil
        coldReads.removeAll { $0 === command }
        command.scriptErrorNumber = answer.scriptErrorNumber
        command.scriptErrorString = answer.scriptErrorString
        command.scriptErrorOffendingObjectDescriptor = answer.scriptErrorOffendingObjectDescriptor
        if command.scriptErrorNumber == 0, !(answer is NSExistsCommand),
            let failed = answer.receiversSpecifier?.evaluationError,
            failed.evaluationErrorNumber != 0
        {
            VMScriptEvaluationFailure(failed).record(on: command)
        }
        command.resumeExecution(withResult: result)
    }

    /// Clears the failure a past evaluation left on `specifier` and every
    /// container above it.
    private func clearEvaluationFailure(_ specifier: NSScriptObjectSpecifier?) {
        var link = specifier
        while let specifier = link {
            specifier.evaluationErrorNumber = 0
            link = specifier.container
        }
    }

    // MARK: - Addressing

    /// The VMs `specifier` addresses, read once the library has landed.
    func address(_ specifier: NSScriptObjectSpecifier) async throws -> [VMSelector] {
        await readiness.ready()
        return try VMScriptSelector.selectors(addressing: specifier)
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
