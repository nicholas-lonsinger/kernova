import Foundation
import KernovaKit
import KernovaLogging

/// Start, suspend or stop every VM in a smart group or a folder — the one
/// executor behind the group header menus, the `kernova` lifecycle verbs given
/// a group, and the Shortcuts group action.
extension VMCommandCore {
    /// How many of the VMs in `group` each action acts on now — what the
    /// actions' menu items count, by the rule the actions themselves act by
    /// (``VMCapabilityCatalog/groupAction(_:on:)``).
    func concernedCounts(in group: VMGroupReference) throws -> [VMGroupAction: Int] {
        let instances = entries(in: try self.group(group, verb: .groups).selection).compactMap { entry in
            if case .vm(let instance) = entry { instance } else { nil }
        }
        return Dictionary(
            uniqueKeysWithValues: VMGroupAction.allCases.map { action in
                let acted = instances.count { instance in
                    if case .acts = capabilities.groupAction(action, on: instance) { true } else { false }
                }
                return (action, acted)
            })
    }

    /// Takes `action` on each VM in `group`, one after another, and reports
    /// what it did to each.
    ///
    /// One at a time, as the launch's auto-start is: each guest commits its
    /// memory as it comes up, and the platform's cap on running macOS guests is
    /// met by the start that exceeds it, which then fails on its own.
    ///
    /// Asks nobody and moves nothing on screen: a VM whose own verb would raise
    /// a question is passed by and reported, and a failure is reported in the
    /// result rather than raised — so the caller owes the user one account of
    /// everything left undone. Each VM is decided when its turn comes, so one
    /// the action stopped concerning since it was counted is passed over.
    ///
    /// - Throws: ``CommandError/itemNotFoundOnHost(item:)`` for a group the
    ///   library does not list, before any VM is acted on.
    func groupAction(_ action: VMGroupAction, on group: VMGroupReference) async throws -> VMGroupActionReport {
        library.refreshFromOtherCopies()
        let resolved = try self.group(group, verb: action.verb)
        let members = entries(in: resolved.selection)
        #log(
            Self.logger, .notice,
            "\(action.rawValue, privacy: .public) on every VM in '\(resolved.name, privacy: .public)': \(members.count, privacy: .public) VM(s)"
        )
        var results: [VMGroupActionResult] = []
        for entry in members {
            results.append(await result(of: action, on: entry))
        }
        let report = VMGroupActionReport(
            action: action, groupKind: resolved.kind, groupID: resolved.id, groupName: resolved.name,
            results: results)
        let undone = report.undone.count
        #log(
            Self.logger, .notice,
            "\(action.rawValue, privacy: .public) on '\(resolved.name, privacy: .public)' finished — \(undone, privacy: .public) of \(results.count, privacy: .public) VM(s) undone"
        )
        return report
    }

    /// What `action` does to `entry`, decided now.
    private func result(of action: VMGroupAction, on entry: LibraryEntry) async -> VMGroupActionResult {
        guard case .vm(let instance) = entry else {
            return VMGroupActionResult(vm: summary(entry), outcome: .passedOver(reason: .state))
        }
        let outcome: VMGroupActionOutcome =
            switch capabilities.groupAction(action, on: instance) {
            case .acts(let step):
                await take(step, on: instance)
            case .passedOverByState:
                .passedOver(reason: .state)
            case .owesGuestSetup:
                .passedOver(reason: .guestSetup)
            case .refused(let reason):
                .passedOver(
                    reason: .refused(error: commandError(for: reason, on: instance, verb: action.verb).dto))
            }
        return VMGroupActionResult(vm: summary(instance), outcome: outcome)
    }

    /// Runs `step` on `instance` with no consent and no remedy, as the verb
    /// any door reaches it by.
    private func take(
        _ step: VMCapabilityCatalog.GroupActionStep, on instance: VMInstance
    ) async -> VMGroupActionOutcome {
        do {
            switch step {
            case .start:
                try await start(.id(instance.id), recovery: false, consent: .none)
            case .resume:
                try await resume(.id(instance.id), consent: .none)
            case .suspend:
                try await suspend(instance)
            case .stop:
                try await stop(instance, disposition: .graceful, consent: .none)
            }
            return .done(verb: step.verb)
        } catch {
            let refusal = failure(error, verb: step.verb, on: instance)
            switch refusal {
            case .confirmationRequired, .guestAccountPasswordRequired, .macAddressRemedyRequired:
                return .needsAnswer(question: refusal.dto)
            case .terminating:
                // Quitting is not this VM's failure, and nobody is told about it.
                return .passedOver(reason: .refused(error: refusal.dto))
            default:
                return .failed(error: refusal.dto)
            }
        }
    }
}
