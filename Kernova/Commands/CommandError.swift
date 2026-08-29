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
    /// The verb ran and did not complete. `title` is the alert heading when the
    /// failure names its own; `recovery` is what the caller can do about it.
    case operationFailed(
        verb: VMVerb, title: String? = nil, message: String, recovery: CommandRecovery? = nil)
}

extension CommandError {
    /// The heading a surface shows this refusal under.
    var alertTitle: String {
        switch self {
        case .notFound, .ambiguous, .busy, .unsupported:
            "Error"
        case .invalidState:
            "Error"
        case .confirmationRequired(let prompt):
            prompt.title
        case .conflict(_, _, let reason):
            switch reason {
            case .machineIdentity: "Duplicate Machine ID"
            case .macAddress: "Duplicate MAC Address"
            }
        case .operationFailed(_, let title, _, _):
            title ?? "Error"
        }
    }

    /// What a surface tells the user, in one sentence per fact.
    var message: String {
        switch self {
        case .notFound(let selector):
            "No virtual machine named \u{201C}\(selector.displayText)\u{201D}."
        case .ambiguous(let selector, let candidates):
            "\u{201C}\(selector.displayText)\u{201D} names \(candidates.count) virtual machines. "
                + "Use one of their identifiers instead: "
                + candidates.map { "\($0.name) (\($0.id.uuidString))" }.joined(separator: ", ")
                + "."
        case .invalidState(let vm, let current, let allowed):
            // Display names, never the raw values: those are the wire's
            // vocabulary, and this sentence goes in front of a person. Reads are
            // left out — every state admits them, so naming them says nothing.
            {
                let offered = allowed.filter { !$0.isRead }.map(\.displayName)
                return "\u{201C}\(vm.name)\u{201D} is \(current.displayName.lowercased()). "
                    + (offered.isEmpty
                        ? "Nothing can be done with it in that state."
                        : "What it accepts now: \(offered.joined(separator: ", ")).")
            }()
        case .busy(let vm, let operation):
            "\u{201C}\(vm.name)\u{201D} is busy \(operation). Wait for it to finish, then try again."
        case .confirmationRequired(let prompt):
            prompt.message
        case .unsupported(let capability):
            "This virtual machine does not support \(capability)."
        case .conflict(let vm, let other, let reason):
            switch reason {
            case .machineIdentity:
                "\u{201C}\(vm.name)\u{201D} has the same machine ID as \u{201C}\(other.name)\u{201D}, which is active. "
                    + "Two virtual machines with the same machine ID must not run at once. "
                    + "Stop \u{201C}\(other.name)\u{201D} first, or allow this in Settings \u{2192} Advanced."
            case .macAddress:
                "\u{201C}\(vm.name)\u{201D} has the same MAC address as \u{201C}\(other.name)\u{201D}, which is active. "
                    + "Two virtual machines with the same MAC address must not run on the same network at once. "
                    + "Stop \u{201C}\(other.name)\u{201D} first, or give one of them a new address in Network settings."
            }
        case .operationFailed(_, _, let message, _):
            message
        }
    }

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

    /// The recovery this failure offers, or `nil` when there is none.
    var recovery: CommandRecovery? {
        guard case .operationFailed(_, _, _, let recovery) = self else { return nil }
        return recovery
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
        case .operationFailed(let verb, let title, let message, let recovery):
            .operationFailed(
                verb: verb, title: title, message: message, recovery: recovery?.dto)
        }
    }
}

extension CommandError: LocalizedError {
    var errorDescription: String? { message }
}
