import Cocoa
import CoreServices
import KernovaKit

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

/// One suspended script command, carried from the Apple event's own callout
/// into the main-actor turn that answers it.
///
/// `@unchecked Sendable` is that crossing spelled out rather than inferred:
/// Cocoa creates and executes every script command on the main thread, this
/// hands one nowhere else, and between the two the command is suspended — the
/// turn that resumes it is the only thing touching it.
private struct SuspendedScriptCommand: @unchecked Sendable {
    let command: VMScriptCommand

    /// Runs the verb and hands the Apple event back.
    @MainActor
    func answer(
        _ body: @MainActor (VMScriptingGateway, [VMSelector]) async throws -> Void
    ) async {
        await record(body)
        // Resuming is what hands the event back, so a refusal not recorded by
        // now is not reported at all.
        command.resumeExecution(withResult: nil)
    }

    /// Runs the verb, recording whatever it refused.
    @MainActor
    private func record(
        _ body: @MainActor (VMScriptingGateway, [VMSelector]) async throws -> Void
    ) async {
        guard let gateway = (NSApp.delegate as? AppDelegate)?.scriptingGateway else {
            command.refuse(Int(errAEEventFailed), "Kernova is not ready to answer scripts.")
            return
        }
        let selectors = command.addressedVMs
        guard !selectors.isEmpty else {
            // Cocoa's own evaluation already said which specifier it could not
            // resolve, in the words a script reads for every other class too.
            command.refuse(Int(errAENoSuchObject), "")
            return
        }
        do {
            try await body(gateway, selectors)
        } catch let failure as CommandError {
            command.refuse(failure.appleEventErrorNumber, failure.appleEventErrorString)
        } catch {
            command.refuse(Int(errAEEventFailed), error.localizedDescription)
        }
    }
}

/// What every Kernova verb an Apple event can ask for is built out of: read who
/// the event addressed, run the verb, and answer once it settles.
class VMScriptCommand: NSScriptCommand {
    /// Whether the verb has already been started for this command.
    private var hasStarted = false

    /// Runs the verb the first time Cocoa dispatches this command to a VM.
    ///
    /// An object-first command arrives once per VM its specifier resolved to,
    /// and this command already addresses every one of them, so the arrivals
    /// after the first do nothing. A specifier that resolves to no VM is
    /// dispatched to none, and reaches ``performDefaultImplementation()``
    /// instead — which is what lets a name the core refuses as ambiguous be
    /// refused in the core's own words.
    func runOnceForResolvedReceivers() -> Any? {
        guard !hasStarted else { return nil }
        hasStarted = true
        return performDefaultImplementation()
    }

    /// The VMs this command addresses, in the order it named them.
    var addressedVMs: [VMSelector] {
        VMScriptSelector.selectors(
            addressing: receiversSpecifier ?? (directParameter as? NSScriptObjectSpecifier),
            resolving: evaluatedReceivers ?? directParameter)
    }

    /// Runs one Kernova verb for this command, off the Apple event's own
    /// callout, and reports whatever it refused.
    ///
    /// Cocoa requires the handler that suspends a command to return before the
    /// command is resumed, which is what a main-actor `Task` cannot violate: it
    /// has no turn to run in until this callout ends.
    func runVMVerb(
        _ body: @escaping @MainActor (VMScriptingGateway, [VMSelector]) async throws -> Void
    ) {
        let suspended = SuspendedScriptCommand(command: self)
        suspendExecution()
        Task { @MainActor in await suspended.answer(body) }
    }

    /// Records what a script reads back instead of a result.
    func refuse(_ number: Int, _ message: String) {
        scriptErrorNumber = number
        guard !message.isEmpty else { return }
        scriptErrorString = message
    }

    /// Whether the `with`/`without` parameter under `key` was given as `with`.
    func flag(_ key: String) -> Bool {
        evaluatedArguments?[key] as? Bool ?? false
    }

    /// The deadline in seconds the parameter under `key` carries, `nil` when
    /// the script named none — which is a wait as long as the guest takes.
    func seconds(_ key: String) -> TimeInterval? {
        guard let number = evaluatedArguments?[key] as? NSNumber else { return nil }
        return number.doubleValue
    }
}

// MARK: - Commands

/// `start virtual machine …`
@objc(VMStartScriptCommand)
final class VMStartScriptCommand: VMScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let recoveryMode = flag("RecoveryMode")
        runVMVerb { gateway, selectors in
            try await gateway.start(selectors, recoveryMode: recoveryMode)
        }
        return nil
    }
}

/// `stop virtual machine … [by <method>] [with confirmation] [giving up after <seconds>]`
@objc(VMStopScriptCommand)
final class VMStopScriptCommand: VMScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let method = stopMethod() else {
            refuse(Int(errAETypeError), "That is not a way Kernova can stop a guest.")
            return nil
        }
        let confirmed = flag("Confirmation")
        let timeout = seconds("GivingUpAfter")
        runVMVerb { gateway, selectors in
            try await gateway.stop(
                selectors, method: method, confirmed: confirmed, givingUpAfter: timeout)
        }
        return nil
    }

    /// The stop the `by` parameter asked for, shutting down when the script
    /// named none and `nil` for a code from no vocabulary this app writes.
    private func stopMethod() -> StopDisposition? {
        guard let named = evaluatedArguments?["StopMethod"] as? NSNumber else { return .graceful }
        return VMScriptStopMethod(code: named.uint32Value)?.disposition
    }
}

/// `restart virtual machine … [giving up after <seconds>]`
@objc(VMRestartScriptCommand)
final class VMRestartScriptCommand: VMScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let timeout = seconds("GivingUpAfter")
        runVMVerb { gateway, selectors in
            try await gateway.restart(selectors, givingUpAfter: timeout)
        }
        return nil
    }
}

/// `pause virtual machine …`
@objc(VMPauseScriptCommand)
final class VMPauseScriptCommand: VMScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runVMVerb { gateway, selectors in try await gateway.pause(selectors) }
        return nil
    }
}

/// `resume virtual machine …`
@objc(VMResumeScriptCommand)
final class VMResumeScriptCommand: VMScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runVMVerb { gateway, selectors in try await gateway.resume(selectors) }
        return nil
    }
}

/// `suspend virtual machine …`
@objc(VMSuspendScriptCommand)
final class VMSuspendScriptCommand: VMScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runVMVerb { gateway, selectors in try await gateway.suspend(selectors) }
        return nil
    }
}

/// `reveal virtual machine …`
@objc(VMRevealScriptCommand)
final class VMRevealScriptCommand: VMScriptCommand {
    override func performDefaultImplementation() -> Any? {
        runVMVerb { gateway, selectors in try await gateway.reveal(selectors) }
        return nil
    }
}
