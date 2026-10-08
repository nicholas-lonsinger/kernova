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
    ///
    /// Reads the group as this copy holds it in memory and touches the disk
    /// only to ask each member's run lock whether another copy holds it — the
    /// View menu counts these while AppKit matches key equivalents.
    func concernedCounts(in group: VMGroupReference) throws -> [VMGroupAction: Int] {
        let instances = entries(in: try heldGroup(group, verb: .groups).selection).compactMap { entry in
            if case .vm(let instance) = entry { instance } else { nil }
        }
        for instance in instances { instance.activity.probeOtherCopyHold() }
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
    /// The members are the ones the group's file holds when the action
    /// begins; one added later is not acted on. Each is looked up again when
    /// its turn comes and decided as it stands then — against what another
    /// copy of Kernova holds then, and the group as this copy holds it then,
    /// without reading the file again: an arrival that has become a VM is
    /// acted on, a VM the action stopped concerning is passed over, and one
    /// that has left the library or the group is passed over as
    /// ``VMGroupActionOutcome/PassOver/removed`` or
    /// ``VMGroupActionOutcome/PassOver/leftGroup``.
    ///
    /// Cancelling the calling task — a client hanging up — stops the action
    /// between VMs: the VM in hand finishes, and every later one is reported as
    /// passed over, untouched.
    ///
    /// - Throws: ``CommandError/itemNotFoundOnHost(item:)`` for a group the
    ///   library does not list, before any VM is acted on.
    func groupAction(_ action: VMGroupAction, on group: VMGroupReference) async throws -> VMGroupActionReport {
        let resolved = try self.group(group, verb: action.verb)
        let members = entries(in: resolved.selection)
        #log(
            Self.logger, .notice,
            "\(action.rawValue, privacy: .public) on every VM in '\(resolved.name, privacy: .public)': \(members.count, privacy: .public) VM(s)"
        )
        var results: [VMGroupActionResult] = []
        for member in members {
            guard !Task.isCancelled else {
                let current = library.entries.first { $0.id == member.id }?.addressable ?? member
                results.append(VMGroupActionResult(vm: summary(current), outcome: .passedOver(reason: .cancelled)))
                continue
            }
            results.append(await result(of: action, on: member, in: resolved))
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

    /// What `action` does to `member` of `group`, looked up and decided now.
    private func result(
        of action: VMGroupAction, on member: AddressableEntry, in group: VMResolvedGroup
    ) async -> VMGroupActionResult {
        guard let row = library.entries.first(where: { $0.id == member.id }), let entry = row.addressable else {
            return VMGroupActionResult(vm: summary(member), outcome: .passedOver(reason: .removed))
        }
        if case .vm(let instance) = entry { instance.activity.probeOtherCopyHold() }
        guard isStill(row, in: group) else {
            return VMGroupActionResult(vm: summary(entry), outcome: .passedOver(reason: .leftGroup))
        }
        guard case .vm(let instance) = entry else {
            return VMGroupActionResult(vm: summary(entry), outcome: .passedOver(reason: .state))
        }
        let outcome = await self.outcome(of: action, on: instance)
        return VMGroupActionResult(vm: summary(instance), outcome: outcome)
    }

    /// Whether `row` is in `group` as this copy holds the library's
    /// organization now, without reading its file again — and, while that
    /// file is unreadable, as it was when the action began.
    private func isStill(_ row: LibraryEntry, in group: VMResolvedGroup) -> Bool {
        guard case .listed(let organization) = library.organization.state else { return true }
        guard let current = VMResolvedGroup(group.reference, in: organization),
            let subject = library.sidebarContext.subject(of: row)
        else { return false }
        return current.membership.contains(row, subject)
    }

    /// Where `instance` stands for `action`: the step the action takes it by,
    /// or why the action passes it over.
    private enum Turn {
        case acts(VMCapabilityCatalog.GroupActionStep)
        case passesOver(VMGroupActionOutcome.PassOver)
    }

    /// Where `instance` stands for `action` now, by
    /// ``VMCapabilityCatalog/groupAction(_:on:)``.
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
            return Self.outcome(of: bringUpFailure(error, verb: step.verb, on: instance), takenBy: step.verb)
        }
    }

    /// What a group action reports for a VM whose verb `verb` refused or
    /// failed with `refusal`.
    ///
    /// A question becomes the VM's account of what to answer; the app quitting
    /// is nobody's failure, so nobody is told about it; a VM another copy of
    /// Kernova took after its turn read it free is passed over, as one found
    /// held at its turn is; anything else failed.
    static func outcome(of refusal: CommandError, takenBy verb: VMVerb) -> VMGroupActionOutcome {
        switch refusal {
        case .confirmationRequired, .guestAccountPasswordRequired, .macAddressRemedyRequired:
            .needsAnswer(verb: verb, question: refusal.dto)
        case .heldByAnotherCopy:
            .passedOver(reason: .state)
        case .terminating:
            .passedOver(reason: .refused(error: refusal.dto))
        default:
            .failed(error: refusal.dto)
        }
    }
}
