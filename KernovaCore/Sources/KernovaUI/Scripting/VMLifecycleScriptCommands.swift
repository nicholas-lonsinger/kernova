import Cocoa
import CoreServices
import KernovaCommandModel
import KernovaCore
import KernovaLogging

/// The dictionary's `VM stop method` enumeration, in Swift: how `stop` and
/// `restart` take the guest down.
///
/// The cases and codes here and the enumerators in `Kernova.sdef` are two
/// halves of one thing, which is what `KernovaScriptingDefinitionTests` checks.
enum VMScriptStopMethod: CaseIterable {
    case normal
    case anyway
    case force

    // periphery:ignore - never called: an exhaustive switch, so a disposition added stops compiling here
    /// The way of stopping `disposition` names. Exhaustive, so a new
    /// disposition has to be given a term before it compiles.
    init(_ disposition: StopDisposition) {
        switch disposition {
        case .graceful: self = .normal
        case .force: self = .force
        case .anyway: self = .anyway
        }
    }

    /// The method an Apple event naming `code` asked for, `nil` for a code from
    /// no vocabulary this app writes.
    init?(code: FourCharCode) {
        guard let match = Self.allCases.first(where: { $0.code == code }) else { return nil }
        self = match
    }

    /// The Apple event code the dictionary gives this case's term.
    var code: FourCharCode {
        switch self {
        case .normal: FourCharCode(scriptingCode: "KmNo")
        case .force: FourCharCode(scriptingCode: "KmFo")
        case .anyway: FourCharCode(scriptingCode: "KmSa")
        }
    }

    /// How the core reaches a powered-off guest this way.
    var disposition: StopDisposition {
        switch self {
        case .normal: .graceful
        case .force: .force
        case .anyway: .anyway
        }
    }
}

// MARK: - The shape every Kernova verb takes

/// What every Kernova verb an Apple event can ask for is built out of: take
/// the event over, read what it addressed once the library has landed, run the
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

    /// The Cocoa key of `with confirmation`, on every command that takes it.
    nonisolated static let confirmationKey = "Confirmation"

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

    /// Reads what the event addresses — inside a dispatch of the gateway's
    /// own — and answers the verb to run on it once that dispatch returns, or
    /// `nil` with the refusal recorded.
    ///
    /// A command addressing VMs runs ``run(_:on:)`` on the ones its direct
    /// parameter names; one addressing anything else overrides this.
    func work(on gateway: VMScriptingGateway) -> VMScriptingGateway.Work? {
        guard let selectors = gateway.virtualMachines(addressedBy: self) else { return nil }
        return {
            try await self.run(gateway, on: selectors)
            return nil
        }
    }

    /// The verb, run on the VMs the event addressed.
    ///
    /// Every command addressing VMs overrides this; reaching the base is a
    /// programming error.
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
            selectors, recoveryMode: flag("RecoveryMode"), confirmation: flag(Self.confirmationKey))
    }
}

/// `stop virtual machine … [method <method>] [with confirmation] [giving up after <seconds>]`
@objc(VMStopScriptCommand)
final class VMStopScriptCommand: VMScriptCommand {
    override func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        try await gateway.stop(
            selectors, method: try stopMethod(), confirmation: flag(Self.confirmationKey),
            givingUpAfter: seconds("GivingUpAfter"))
    }
}

/// `restart virtual machine … [method <method>] [with confirmation] [giving up after <seconds>]`
@objc(VMRestartScriptCommand)
final class VMRestartScriptCommand: VMScriptCommand {
    override func run(_ gateway: VMScriptingGateway, on selectors: [VMSelector]) async throws {
        try await gateway.restart(
            selectors, method: try stopMethod(), confirmation: flag(Self.confirmationKey),
            givingUpAfter: seconds("GivingUpAfter"))
    }
}

extension VMScriptCommand {
    /// The way down the `method` parameter asked for, `normal` when the script
    /// named none.
    ///
    /// - Throws: ``CommandError/invalidArgument(_:)`` for a code from no
    ///   vocabulary this app writes.
    func stopMethod() throws -> StopDisposition {
        guard let named = arguments?["StopMethod"] as? NSNumber else { return .graceful }
        guard let method = VMScriptStopMethod(code: named.uint32Value) else {
            throw CommandError.invalidArgument("That is not a way Kernova can stop a guest.")
        }
        return method.disposition
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
        try await gateway.resume(selectors, confirmation: flag(Self.confirmationKey))
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

/// The Standard Suite's `delete … [with confirmation]`: a snapshot's delete
/// goes to ``VMScriptingGateway/deleteSnapshots(_:in:for:)``, and everything
/// else's is Cocoa's own.
///
/// Cocoa splits a delete's reference into the container it evaluates and the
/// element it names (``keySpecifier``), and runs this once that container is
/// in hand.
@MainActor
@objc(VMDeleteScriptCommand)
final class VMDeleteScriptCommand: NSDeleteCommand {
    /// A selector hop to the main actor, as ``VMScriptCommand/execute()``
    /// takes, for a snapshot's delete.
    nonisolated override func performDefaultImplementation() -> Any? {
        guard keySpecifier.key == VMScriptObject.snapshotsKey else { return super.performDefaultImplementation() }
        performSelector(onMainThread: #selector(deleteSnapshots), with: nil, waitUntilDone: true)
        return nil
    }

    /// Where the hop lands, on the main actor.
    @objc private func deleteSnapshots() {
        guard let gateway = (NSApp.delegate as? VMScriptingRoot)?.scriptingGateway else {
            refuse(Int(errAEEventFailed), VMScriptCommand.notReady)
            return
        }
        gateway.deleteSnapshots(keySpecifier, in: evaluatedReceivers, for: self)
    }
}

/// `revert to snapshot … [with confirmation]`
///
/// It addresses snapshots, each of which names its VM, so it reverts a VM to
/// a snapshot of its own by construction.
@objc(VMRevertScriptCommand)
final class VMRevertScriptCommand: VMScriptCommand {
    override func work(on gateway: VMScriptingGateway) -> VMScriptingGateway.Work? {
        guard let snapshots = gateway.snapshots(addressedBy: self, unnamed: "Name the snapshot to revert to.")
        else { return nil }
        let confirmation = flag(Self.confirmationKey)
        return {
            try await gateway.revert(to: snapshots, confirmation: confirmation)
            return nil
        }
    }
}
