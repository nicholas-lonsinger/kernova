import Foundation
import KernovaKit

/// A way out of a failure that a caller performs by acting on the app's own
/// model, offered as data rather than as a presenter call.
enum CommandRecovery: Sendable, Equatable {
    /// The start failed opening one attachment. Removing that attachment (the
    /// file is untouched) and starting again is the offered way out.
    case removeStartFailedAttachment(StartFailedAttachment)

    /// How this recovery names itself to a caller that cannot hold the object
    /// it acts on.
    var dto: CommandRecoveryDTO {
        switch self {
        case .removeStartFailedAttachment(let failure):
            .removeStartFailedAttachment(id: failure.id, label: failure.label)
        }
    }
}

/// Why a command did not run, in the one vocabulary every front door inherits.
///
/// Each case is a refusal a surface renders in its own idiom — an AppKit alert
/// in process, a ``CommandErrorDTO`` on the wire. The mapping belongs to each
/// transport; the vocabulary lives here.
enum CommandError: Error, Sendable, Equatable {
    /// No VM answers to the selector.
    case notFound(VMSelector)
    /// More than one VM answers to the selector; the candidates say which.
    case ambiguous(selector: VMSelector, candidates: [VMSummary])
    /// The VM's current state does not admit this verb; `allowed` names the
    /// verbs it does admit.
    case invalidState(vm: VMSummary, current: VMStatus, allowed: [VMVerb])
    /// The VM has work in flight that this verb would race.
    case busy(vm: VMSummary, operation: String)
    /// The verb is destructive and no consent was supplied.
    case confirmationRequired(ConfirmationPrompt)
    /// This build, guest, or configuration cannot do what was asked.
    case unsupported(capability: String)
    /// Running the VM would put two guests on one identity.
    case conflict(vm: VMSummary, with: VMSummary, reason: ConflictReason)
    /// The guest had not powered off `seconds` after the shutdown request, so
    /// the verb stopped waiting and left the VM as it was.
    case timedOut(vm: VMSummary, verb: VMVerb, seconds: TimeInterval)
    /// The verb ran and did not complete. `title` is the alert heading when the
    /// failure names its own; `recovery` is what the caller can do about it.
    case operationFailed(
        verb: VMVerb, title: String? = nil, message: String, recovery: CommandRecovery? = nil)
}

extension CommandError {
    /// The heading a surface shows this refusal under.
    ///
    /// Rendered from ``dto``, so an alert and a wire client cannot word the
    /// same refusal differently.
    var alertTitle: String { dto.title }

    /// What a surface tells the user, in one sentence per fact.
    var message: String { dto.message }

    /// Whether the VM already had work in flight that this verb would race.
    var isBusy: Bool {
        if case .busy = self { return true }
        return false
    }

    /// Whether the verb ran and did not complete, as opposed to being refused
    /// before it started.
    var isOperationFailure: Bool {
        if case .operationFailed = self { return true }
        return false
    }

    /// The confirmation this refusal is asking for, or `nil` when it is not a
    /// consent refusal.
    var confirmationPrompt: ConfirmationPrompt? {
        guard case .confirmationRequired(let prompt) = self else { return nil }
        return prompt
    }

    /// This failure as it crosses a wire.
    var dto: CommandErrorDTO {
        switch self {
        case .notFound(let selector):
            .notFound(selector: selector)
        case .ambiguous(let selector, let candidates):
            .ambiguous(selector: selector, candidates: candidates)
        case .invalidState(let vm, let current, let allowed):
            .invalidState(vm: vm, current: current.rawValue, allowed: allowed)
        case .busy(let vm, let operation):
            .busy(vm: vm, operation: operation)
        case .confirmationRequired(let prompt):
            .confirmationRequired(prompt: prompt)
        case .unsupported(let capability):
            .unsupported(capability: capability)
        case .conflict(let vm, let other, let reason):
            .conflict(vm: vm, with: other, reason: reason)
        case .timedOut(let vm, let verb, let seconds):
            .timedOut(vm: vm, verb: verb, seconds: seconds)
        case .operationFailed(let verb, let title, let message, let recovery):
            .operationFailed(
                verb: verb, title: title, message: message, recovery: recovery?.dto)
        }
    }
}

extension CommandError: LocalizedError {
    var errorDescription: String? { message }
}
