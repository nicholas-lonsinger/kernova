import Cocoa
import CoreServices
import KernovaCommandModel
import KernovaCore
import KernovaLogging

/// The dictionary's `VM stop method` enumeration, in Swift.
///
/// The terms and codes here and the enumerators in `Kernova.sdef` are two
/// halves of one thing, which is what `KernovaScriptingDefinitionTests` checks.
enum VMScriptStopMethod: CaseIterable {
    case shutDown
    case force

    /// The way of stopping `disposition` names. Exhaustive, so a new
    /// disposition has to be given a term before it compiles.
    init(_ disposition: StopDisposition) {
        switch disposition {
        case .graceful: self = .shutDown
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
        case .force: "force"
        }
    }

    /// The Apple event code the dictionary gives that term.
    var code: FourCharCode {
        switch self {
        case .shutDown: FourCharCode(scriptingCode: "KmSd")
        case .force: FourCharCode(scriptingCode: "KmFo")
        }
    }

    /// How the core reaches a powered-off guest this way.
    var disposition: StopDisposition {
        switch self {
        case .shutDown: .graceful
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
/// reaches is main-actor state.
@MainActor
class VMScriptCommand: NSScriptCommand {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMScriptCommand")

    /// What a script reads back before the app has a gateway to answer it.
    nonisolated static let notReady = "Kernova is not ready to answer scripts."

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

    /// Runs the verb on `selectors`, recording whatever refused it.
    ///
    /// The gateway resumes the event once this returns, which is what hands
    /// it back, so a refusal not recorded by then is not reported at all.
    func perform(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async {
        do {
            try await run(gateway, on: selectors)
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

// MARK: - Commands

/// `start virtual machine … [with recovery mode] [with confirmation]`
@objc(VMStartScriptCommand)
final class VMStartScriptCommand: VMScriptCommand {
    override func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        try await gateway.start(
            selectors, recoveryMode: flag("RecoveryMode"), confirmation: flag("Confirmation"))
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
            selectors, method: method, confirmation: flag("Confirmation"),
            givingUpAfter: seconds("GivingUpAfter"))
    }

    /// The stop the `by` parameter asked for, shutting down when the script
    /// named none and `nil` for a code from no vocabulary this app writes.
    private func stopMethod() -> StopDisposition? {
        guard let named = arguments?["StopMethod"] as? NSNumber else { return .graceful }
        return VMScriptStopMethod(code: named.uint32Value)?.disposition
    }
}

/// `restart virtual machine … [with confirmation] [giving up after <seconds>]`
@objc(VMRestartScriptCommand)
final class VMRestartScriptCommand: VMScriptCommand {
    override func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        try await gateway.restart(
            selectors, confirmation: flag("Confirmation"), givingUpAfter: seconds("GivingUpAfter"))
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
        try await gateway.resume(selectors, confirmation: flag("Confirmation"))
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
