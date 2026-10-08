import Foundation
import KernovaKit
import KernovaLogging

/// Start, suspend or stop every VM in a smart group or a folder — the one
/// executor behind the group header menus, the `kernova` lifecycle verbs given
/// a group, and the Shortcuts group action.
extension VMCommandCore {
    /// How many of the VMs in `group` each action acts on now — what the
    /// actions' menu items count, by the rule the actions themselves act by
    /// (``VMCapabilityCatalog/groupAction(_:on:)``), against what another copy
    /// of Kernova holds now.
    func concernedCounts(in group: VMGroupReference) throws -> [VMGroupAction: Int] {
        let instances = entries(in: try self.group(group, verb: .groups).selection).compactMap { entry in
            if case .vm(let instance) = entry { instance } else { nil }
        }
        library.refreshFromOtherCopies(only: Set(instances.map(\.id)))
        return Dictionary(
            uniqueKeysWithValues: VMGroupAction.allCases.map { action in
                let acted = instances.count { instance in
                    if case .acts = turn(of: action, on: instance) { true } else { false }
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
    /// Asks nobody and puts nothing in front of the user: each bring-up is
    /// ``StartPolicy/group``, which begins no guest setup and readies its
    /// display behind whatever the user is looking at, and a VM whose own verb
    /// would raise a question is passed by and reported. A failure is reported
    /// in the result rather than raised — so the caller owes the user one
    /// account of everything left undone.
    ///
    /// The members are the ones the group holds when the action begins; one
    /// added later is not acted on, and one taken out of the group is. Each is
    /// looked up again when its turn comes and decided as it stands then,
    /// against what another copy of Kernova holds then: an arrival that has
    /// become a VM is acted on, a VM the action stopped concerning is passed
    /// over, and one that has left the library is passed over as
    /// ``VMGroupActionOutcome/PassOver/removed``.
    ///
    /// Cancelling the calling task — a client hanging up — stops the action
    /// between VMs: the VM in hand finishes, and every later one is reported as
    /// passed over, untouched.
    ///
    /// - Throws: ``CommandError/itemNotFoundOnHost(item:)`` for a group the
    ///   library does not list, before any VM is acted on.
    func groupAction(_ action: VMGroupAction, on group: VMGroupReference) async throws -> VMGroupActionReport {
        library.refreshFromOtherCopies()
        let resolved = try self.group(group, verb: action.verb)
        let members = entries(in: resolved.selection).map { (id: $0.id, summary: summary($0)) }
        #log(
            Self.logger, .notice,
            "\(action.rawValue, privacy: .public) on every VM in '\(resolved.name, privacy: .public)': \(members.count, privacy: .public) VM(s)"
        )
        var results: [VMGroupActionResult] = []
        for member in members {
            guard !Task.isCancelled else {
                results.append(VMGroupActionResult(vm: member.summary, outcome: .passedOver(reason: .cancelled)))
                continue
            }
            results.append(await result(of: action, on: member.id, summarized: member.summary))
        }
        let report = VMGroupActionReport(
            action: action, groupKind: resolved.kind, groupID: resolved.id, groupName: resolved.name,
            results: results)
        let undone = report.undone.count
        #log(
            Self.logger, .notice,
            "\(action.rawValue, privacy: .public) on '\(resolved.name, privacy: .public)' finished\(Task.isCancelled ? " after a cancel" : "", privacy: .public) — \(undone, privacy: .public) of \(results.count, privacy: .public) VM(s) undone"
        )
        return report
    }

    /// What `action` does to the member `id`, looked up and decided now;
    /// `summary` is how it stood when the action began.
    private func result(
        of action: VMGroupAction, on id: UUID, summarized summary: VMSummary
    ) async -> VMGroupActionResult {
        library.refreshFromOtherCopies(only: [id])
        guard let entry = library.entries.first(where: { $0.id == id })?.addressable else {
            return VMGroupActionResult(vm: summary, outcome: .passedOver(reason: .removed))
        }
        guard case .vm(let instance) = entry else {
            return VMGroupActionResult(vm: self.summary(entry), outcome: .passedOver(reason: .state))
        }
        let outcome = await self.outcome(of: action, on: instance)
        return VMGroupActionResult(vm: self.summary(instance), outcome: outcome)
    }

    /// Where `instance` stands for `action`: the step the action takes it by,
    /// or why the action passes it over.
    private enum Turn {
        case acts(VMCapabilityCatalog.GroupActionStep)
        case passesOver(VMGroupActionOutcome.PassOver)
    }

    /// Where `instance` stands for `action` now, by
    /// ``VMCapabilityCatalog/groupAction(_:on:)`` — the one reading of a VM
    /// another copy of Kernova holds as a pass-over.
    private func turn(of action: VMGroupAction, on instance: VMInstance) -> Turn {
        switch capabilities.groupAction(action, on: instance) {
        case .acts(let step):
            .acts(step)
        case .passedOverByState:
            .passesOver(.state)
        case .owesGuestSetup:
            .passesOver(.guestSetup)
        case .refused(let reason):
            .passesOver(.refused(error: commandError(for: reason, on: instance, verb: action.verb).dto))
        }
    }

    /// What `action` does to `instance`, decided now: the step its standing
    /// names, run as a ``StartPolicy/group`` bring-up or the plain suspend or
    /// graceful stop, with no consent and no remedy.
    private func outcome(of action: VMGroupAction, on instance: VMInstance) async -> VMGroupActionOutcome {
        let step: VMCapabilityCatalog.GroupActionStep
        switch turn(of: action, on: instance) {
        case .passesOver(let reason):
            return .passedOver(reason: reason)
        case .acts(let acting):
            step = acting
        }
        do {
            switch step {
            case .start:
                try await start(instance, recovery: false, policy: .group, macAddressRemedy: nil)
            case .resume:
                try await resume(instance, policy: .group, macAddressRemedy: nil)
            case .suspend:
                try await suspend(instance)
            case .stop:
                try await stop(instance, disposition: .graceful, consent: .none)
            }
            return .done(verb: step.verb)
        } catch is UnattendedGuestSetupRefusal {
            return .passedOver(reason: .guestSetup)
        } catch {
            let refusal = bringUpFailure(error, verb: step.verb, on: instance)
            // Another copy took the VM after the turn read it free. The
            // refusing commit recorded the hold, so the standing read again
            // passes the VM over as one found held at its turn.
            if case .heldByAnotherCopy = refusal, case .passesOver(let reason) = turn(of: action, on: instance) {
                return .passedOver(reason: reason)
            }
            return Self.outcome(of: refusal, takenBy: step.verb)
        }
    }

    /// What a group action reports for a VM whose verb `verb` refused or
    /// failed with `refusal`.
    ///
    /// A question becomes the VM's account of what to answer; the app quitting
    /// is nobody's failure, so nobody is told about it; anything else failed.
    static func outcome(of refusal: CommandError, takenBy verb: VMVerb) -> VMGroupActionOutcome {
        switch refusal {
        case .confirmationRequired, .guestAccountPasswordRequired, .macAddressRemedyRequired:
            .needsAnswer(verb: verb, question: refusal.dto)
        case .terminating:
            .passedOver(reason: .refused(error: refusal.dto))
        default:
            .failed(error: refusal.dto)
        }
    }
}
