import Foundation
import KernovaKit
import os

/// The Apple event front door: everything Script Editor, Automator, and
/// `osascript` ask of Kernova passes through here and reaches ``VMCommanding``.
///
/// Receiving Apple events needs no entitlement — a sandboxed app keeps the
/// ability to receive and respond to them, and only *sending* one to another
/// app needs a scripting-targets entitlement (Apple QA1888).
///
/// **Readiness:** every verb awaits the app's first library read, as every
/// other door does — a script that launched Kernova is the ordinary case, and a
/// verb run against a library that has not landed yet refuses with "no virtual
/// machine named…". The property reads cannot wait: Cocoa evaluates a specifier
/// through synchronous KVC, which has no suspension to await in, so a read
/// arriving before that first read answers from the library as it stands.
/// **Addressing:** a script names a VM the way a person does, so this addresses
/// VMs by ``VMSelector/name(_:)`` as readily as by identifier and the ambiguity
/// refusal can fire here.
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

    init(commands: any VMCommanding, readiness: LibraryReadiness) {
        self.commands = commands
        self.readiness = readiness
    }

    // MARK: - Reads

    /// Every VM in the library, in the order the sidebar shows them.
    func virtualMachines() -> [VMScriptObject] {
        commands.list().compactMap { object(for: $0.id) }
    }

    /// The one VM called `name`, or nothing when the library holds no VM by
    /// that name — or more than one.
    ///
    /// Cocoa's own name lookup answers with the first match, which for two VMs
    /// sharing a display name is whichever the library happens to list first.
    /// Refusing instead is what keeps a property read from quietly describing
    /// the wrong VM; a verb reads the name off the specifier before it gets
    /// here, so `stop virtual machine "Alpha"` still refuses with the
    /// candidates the core names.
    func virtualMachine(named name: String) -> VMScriptObject? {
        let matches = commands.list().filter { $0.name == name }
        guard matches.count == 1, let only = matches.first else { return nil }
        return object(for: only.id)
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

    // MARK: - Lifecycle

    func start(_ selectors: [VMSelector], recoveryMode: Bool) async throws {
        try await perform(.start, on: selectors) {
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
        try await perform(.stop, on: selectors) { selector in
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
        try await perform(.restart, on: selectors) {
            try await self.commands.restart($0, presentation: .surface, timeout: timeout)
        }
    }

    func pause(_ selectors: [VMSelector]) async throws {
        try await perform(.pause, on: selectors) { try await self.commands.pause($0) }
    }

    func resume(_ selectors: [VMSelector]) async throws {
        try await perform(.resume, on: selectors) { try await self.commands.resume($0) }
    }

    func suspend(_ selectors: [VMSelector]) async throws {
        try await perform(.suspend, on: selectors) { try await self.commands.suspend($0) }
    }

    func reveal(_ selectors: [VMSelector]) async throws {
        try await perform(.reveal, on: selectors) { try self.commands.reveal($0) }
    }

    // MARK: - Dispatch

    /// Runs `verb` on each VM once the library read has landed, logging and
    /// rethrowing the first refusal.
    ///
    /// A refusal stops the run where it happened: an event addressing several
    /// VMs carries back one error, and finishing the rest would leave a script
    /// unable to tell how far the verb got.
    private func perform(
        _ verb: VMVerb, on selectors: [VMSelector], _ body: (VMSelector) async throws -> Void
    ) async throws {
        await readiness.ready()
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
