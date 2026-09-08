import Cocoa
import CoreServices
import KernovaKit
import os

/// The dictionary's `VM stop method` enumeration, in Swift.
///
/// The terms and codes here and the enumerators in `Kernova.sdef` are two
/// halves of one thing, which is what `KernovaScriptingDefinitionTests` checks.
enum VMScriptStopMethod: CaseIterable {
    case shutDown
    case resumeThenShutDown
    case force

    /// The way of stopping `disposition` names. Exhaustive, so a new
    /// disposition has to be given a term before it compiles.
    init(_ disposition: StopDisposition) {
        switch disposition {
        case .graceful: self = .shutDown
        case .resumeThenShutDown: self = .resumeThenShutDown
        case .force: self = .force
        }
    }

    /// The method an Apple event naming `code` asked for, `nil` for a code from
    /// no vocabulary this app writes.
    init?(code: FourCharCode) {
        guard let match = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = match
    }

    /// The term the dictionary names this method with.
    var term: String {
        switch self {
        case .shutDown: "shut down"
        case .resumeThenShutDown: "resume then shut down"
        case .force: "force"
        }
    }

    /// The Apple event code the dictionary gives that term.
    var code: FourCharCode {
        switch self {
        case .shutDown: FourCharCode(scriptingCode: "KmSd")
        case .resumeThenShutDown: FourCharCode(scriptingCode: "KmRs")
        case .force: FourCharCode(scriptingCode: "KmFo")
        }
    }

    /// How the core reaches a powered-off guest this way.
    var disposition: StopDisposition {
        switch self {
        case .shutDown: .graceful
        case .resumeThenShutDown: .resumeThenShutDown
        case .force: .force
        }
    }
}

// MARK: - The shape every VM verb takes

/// What every Kernova verb an Apple event can ask for is built out of: take
/// the event over, read who it addressed once the library has landed, run the
/// verb, and answer once it settles.
///
/// Main-actor isolated because everything it touches is: Cocoa creates and
/// executes every script command on the main thread, and the gateway a verb
/// reaches is main-actor state. ``execute()`` is the one door Cocoa calls, so
/// it stays as nonisolated as the method it overrides and does nothing but
/// suspend the event and hand the rest to the main actor.
@MainActor
class VMScriptCommand: NSScriptCommand {
    private static let logger = Logger(subsystem: "app.kernova", category: "VMScriptCommand")

    /// Takes the event over from Cocoa's own dispatch.
    ///
    /// Cocoa's `execute()` evaluates the receivers first and answers a failure
    /// itself, before any implementation runs: a name that resolves to nothing,
    /// or to two VMs, is "can't get" and never reaches the core. Overriding it
    /// is what lets a name reach the core as a name, and what lets the
    /// resolution wait for the library — nothing is evaluated here; that is
    /// ``answer()``'s, once the read has landed. Cocoa requires the handler
    /// that suspends a command to return before the command is resumed, which
    /// the hop cannot violate: it lands on the next pass of the main run loop.
    ///
    /// A selector hop rather than a task: it carries no closure, so nothing
    /// crosses isolation, and the method it lands in is main-actor code entered
    /// on the main thread, as every Cocoa callback is.
    nonisolated override func execute() -> Any? {
        suspendExecution()
        perform(#selector(begin), on: .main, with: nil, waitUntilDone: false)
        return nil
    }

    /// Where the hop lands: the verb starts here, on the main actor.
    @objc private func begin() {
        Task { await answer() }
    }

    /// What the event addressed — one specifier or a list of them — as its
    /// direct parameter, or as the `tell` block's subject, which Cocoa promotes
    /// into the same slot.
    private var addressed: Any? {
        directParameter ?? receiversSpecifier
    }

    /// Runs the verb and hands the event back.
    ///
    /// Resuming is what hands the event back, so a refusal not recorded by then
    /// is not reported at all.
    private func answer() async {
        await record()
        resumeExecution(withResult: nil)
    }

    /// Runs the verb, recording whatever refused it.
    private func record() async {
        guard let gateway = (NSApp.delegate as? AppDelegate)?.scriptingGateway else {
            refuse(Int(errAEEventFailed), "Kernova is not ready to answer scripts.")
            return
        }
        guard let addressed else {
            refuse(
                Int(errAEWrongNumberArgs),
                "Name the virtual machine to \(commandDescription.commandName).")
            return
        }
        do {
            try await run(gateway, on: try await gateway.address(addressed, for: self))
        } catch let failure as VMScriptEvaluationFailure {
            failure.record(on: self)
        } catch let refusal as CommandError {
            refuse(refusal)
        } catch {
            refuse(Int(errAEEventFailed), error.localizedDescription)
        }
    }

    /// The verb, run on the VMs the event addressed.
    ///
    /// Every command overrides this; reaching the base is a programming error.
    func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        Self.logger.fault(
            "The \(self.commandDescription.commandName, privacy: .public) command runs no verb")
        assertionFailure("The \(commandDescription.commandName) command runs no verb")
        throw CommandError.unsupported(capability: "the \(commandDescription.commandName) command")
    }

    /// Whether the `with`/`without` parameter under `key` was given as `with`.
    ///
    /// Read as unpacked: evaluating the arguments would evaluate the direct
    /// parameter along with them, which is ``answer()``'s to do after the
    /// library has landed.
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

// MARK: - Commands

/// `start virtual machine …`
@objc(VMStartScriptCommand)
final class VMStartScriptCommand: VMScriptCommand {
    override func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        try await gateway.start(selectors, recoveryMode: flag("RecoveryMode"))
    }
}

/// `stop virtual machine … [by <method>] [with confirmation] [giving up after <seconds>]`
@objc(VMStopScriptCommand)
final class VMStopScriptCommand: VMScriptCommand {
    override func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        guard let method = stopMethod() else {
            throw CommandError.invalidArgument("That is not a way Kernova can stop a guest.")
        }
        try await gateway.stop(
            selectors, method: method, confirmed: flag("Confirmation"),
            givingUpAfter: seconds("GivingUpAfter"))
    }

    /// The stop the `by` parameter asked for, shutting down when the script
    /// named none and `nil` for a code from no vocabulary this app writes.
    private func stopMethod() -> StopDisposition? {
        guard let named = arguments?["StopMethod"] as? NSNumber else { return .graceful }
        return VMScriptStopMethod(code: named.uint32Value)?.disposition
    }
}

/// `restart virtual machine … [giving up after <seconds>]`
@objc(VMRestartScriptCommand)
final class VMRestartScriptCommand: VMScriptCommand {
    override func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        try await gateway.restart(selectors, givingUpAfter: seconds("GivingUpAfter"))
    }
}

/// `pause virtual machine …`
@objc(VMPauseScriptCommand)
final class VMPauseScriptCommand: VMScriptCommand {
    override func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        try await gateway.pause(selectors)
    }
}

/// `resume virtual machine …`
@objc(VMResumeScriptCommand)
final class VMResumeScriptCommand: VMScriptCommand {
    override func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        try await gateway.resume(selectors)
    }
}

/// `suspend virtual machine …`
@objc(VMSuspendScriptCommand)
final class VMSuspendScriptCommand: VMScriptCommand {
    override func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        try await gateway.suspend(selectors)
    }
}

/// `reveal virtual machine …`
@objc(VMRevealScriptCommand)
final class VMRevealScriptCommand: VMScriptCommand {
    override func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        try await gateway.reveal(selectors)
    }
}
