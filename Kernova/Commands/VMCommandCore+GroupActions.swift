import Foundation
import KernovaKit
import KernovaLogging

/// Start, suspend or stop every VM in a set — the one executor behind the
/// group header menus, the `kernova` lifecycle verbs given a group, the
/// Shortcuts group action, and the launch pass that starts the VMs marked to
/// start automatically.
extension VMCommandCore {
    /// How many of the VMs in `group` each action acts on — what the actions'
    /// menu items count, by the rule the actions themselves act by
    /// (``VMCapabilityCatalog/groupAction(_:on:)``).
    ///
    /// Reads only what this copy already holds in memory and touches no disk —
    /// the View menu counts these while AppKit matches key equivalents. So a
    /// count is as current as the sidebar's rows: what another copy of Kernova
    /// holds or wrote shows once the library next catches up with it
    /// (``VMLibrary/refreshFromOtherCopies(only:reportingUnreadable:)``), and
    /// the action itself decides each VM afresh.
    func concernedCounts(in group: VMGroupReference) throws -> [VMGroupAction: Int] {
        let instances = entries(in: try heldGroup(group, verb: .groups).selection).compactMap { entry in
            if case .vm(let instance) = entry { instance } else { nil }
        }
        return Dictionary(
            uniqueKeysWithValues: VMGroupAction.allCases.map { action in
                let acted = instances.count { instance in
                    if case .acts = turn(of: action, on: instance) { true } else { false }
                }
                return (action, acted)
            })
    }

    /// Takes `action` on each VM in `group`, one after another, and reports
    /// what it did to each — by ``take(_:on:)``, passing over a VM that other
    /// work holds at its turn.
    ///
    /// The members are the ones the group holds once the library has caught
    /// up, when the action begins. A smart group's members stay those: its
    /// filter reads the state the action itself changes. A folder's are
    /// checked against the folder at each turn, and one taken out of it is
    /// passed over as ``VMGroupActionOutcome/PassOver/leftGroup``.
    ///
    /// - Throws: ``CommandError/itemNotFoundOnHost(item:)`` for a group the
    ///   library does not list, before any VM is acted on.
    func groupAction(_ action: VMGroupAction, on group: VMGroupReference) async throws -> VMGroupActionReport {
        library.refreshFromOtherCopies(reportingUnreadable: false)
        let resolved = try self.group(group, verb: action.verb)
        let set = MemberSet(
            members: entries(in: resolved.selection), description: "every VM in '\(resolved.name)'",
            holds: { [weak self] entry in self?.isStill(entry.id, in: resolved) ?? false })
        let results = await take(Run(action), on: set)
        return VMGroupActionReport(
            action: action, groupKind: resolved.kind, groupID: resolved.id, groupName: resolved.name,
            results: results)
    }

    /// Starts each VM marked to start automatically
    /// (``VMHostState/startsAutomaticallyOnLaunch``), in library order, and
    /// reports what it did to each — the launch pass, by ``take(_:on:)``.
    ///
    /// Unlike a group action, it waits out a VM that other work holds at its
    /// turn — a snapshot a relaunching `kernova` command is taking, say — and
    /// decides it in the step that frees it. A VM no longer marked by then is
    /// passed over as ``VMGroupActionOutcome/PassOver/leftGroup``.
    func startVMsMarkedToStartAutomatically() async -> [VMGroupActionResult] {
        library.refreshFromOtherCopies(reportingUnreadable: false)
        let set = MemberSet(
            members: library.instances.filter(\.hostState.startsAutomaticallyOnLaunch).map(AddressableEntry.vm),
            description: "every VM marked to start automatically",
            holds: { entry in
                if case .vm(let instance) = entry { instance.hostState.startsAutomaticallyOnLaunch } else { false }
            })
        return await take(.start(waitsOutBusyVMs: true), on: set)
    }

    /// The VMs one run of the executor takes, fixed when it begins, and the
    /// rule that keeps a member in the set until its turn.
    private struct MemberSet {
        let members: [AddressableEntry]
        /// What the log calls the set.
        let description: String
        /// Whether `entry`, re-read at its turn, is still in the set.
        let holds: @MainActor (AddressableEntry) -> Bool
    }

    /// What one run of the executor does to each member.
    private enum Run {
        /// Brings each VM up — deciding it at its turn and passing over one
        /// other work holds then, or, when `waitsOutBusyVMs`, deciding it once
        /// that work ends.
        case start(waitsOutBusyVMs: Bool)
        case suspend
        case stop

        /// A group's action, which passes over a VM other work holds.
        init(_ action: VMGroupAction) {
            switch action {
            case .start: self = .start(waitsOutBusyVMs: false)
            case .suspend: self = .suspend
            case .stop: self = .stop
            }
        }

        var action: VMGroupAction {
            switch self {
            case .start: .start
            case .suspend: .suspend
            case .stop: .stop
            }
        }
    }

    /// Takes `run` on each VM in `set`, one after another, and reports what it
    /// did to each.
    ///
    /// One at a time: each guest commits its memory as it comes up, the
    /// platform's cap on running macOS guests is met by the start that exceeds
    /// it, which then fails on its own, and the machine-identity check every
    /// bring-up passes counts a VM still coming up as live.
    ///
    /// Asks nobody and puts nothing in front of the user: each bring-up is
    /// ``StartPolicy/group``, which begins no guest setup and readies its
    /// display behind whatever the user is looking at, and a VM whose own verb
    /// would raise a question is passed by and reported. A failure is reported
    /// in the result rather than raised — so the caller owes the user one
    /// account of everything left undone — and put on the event stream when
    /// the VM's status cannot carry it (``broadcastFailure(_:on:)``).
    ///
    /// Each member is looked up again when its turn comes, re-read from its
    /// bundle, and decided as it stands then: an arrival that has become a VM
    /// is acted on, a VM the action stopped concerning is passed over, one
    /// that has left the set is passed over as
    /// ``VMGroupActionOutcome/PassOver/leftGroup``, and one that has left the
    /// library as ``VMGroupActionOutcome/PassOver/removed``.
    ///
    /// A config file a read finds unreadable is recorded for the library's
    /// next report rather than brought on screen mid-action.
    ///
    /// Cancelling the calling task — a client hanging up — stops the run
    /// between VMs: the VM in hand finishes, and every later one is reported as
    /// passed over, untouched.
    private func take(_ run: Run, on set: MemberSet) async -> [VMGroupActionResult] {
        let action = run.action
        #log(
            Self.logger, .notice,
            "\(action.rawValue, privacy: .public) on \(set.description, privacy: .public): \(set.members.count, privacy: .public) VM(s)"
        )
        var results: [VMGroupActionResult] = []
        for member in set.members {
            guard !Task.isCancelled else {
                let current = library.entries.first { $0.id == member.id }?.addressable ?? member
                results.append(VMGroupActionResult(vm: summary(current), outcome: .passedOver(reason: .cancelled)))
                continue
            }
            results.append(await result(of: run, on: member, in: set))
        }
        #log(
            Self.logger, .notice,
            "\(action.rawValue, privacy: .public) on \(set.description, privacy: .public) finished\(Task.isCancelled ? " after a cancel" : "", privacy: .public) — \(results.undone.count, privacy: .public) of \(results.count, privacy: .public) VM(s) undone"
        )
        return results
    }

    /// What `run` does to `member` of `set`, looked up and decided at its turn.
    private func result(
        of run: Run, on member: AddressableEntry, in set: MemberSet
    ) async -> VMGroupActionResult {
        guard let entry = library.entries.first(where: { $0.id == member.id })?.addressable else {
            return VMGroupActionResult(vm: summary(member), outcome: .passedOver(reason: .removed))
        }
        guard case .vm(let instance) = entry else {
            let reason: VMGroupActionOutcome.PassOver = set.holds(entry) ? .state : .leftGroup
            return VMGroupActionResult(vm: summary(entry), outcome: .passedOver(reason: reason))
        }
        let outcome =
            if case .start(waitsOutBusyVMs: true) = run {
                await startOnceFree(instance, in: set)
            } else {
                await self.outcome(of: run.action, on: instance, in: set)
            }
        return VMGroupActionResult(vm: summary(instance), outcome: outcome)
    }

    /// Whether the member `id` is still in `group`: for a folder, as this copy
    /// holds it in memory — and as it was when the action began while its
    /// file is unreadable; a smart group's members are fixed at the start.
    private func isStill(_ id: UUID, in group: VMResolvedGroup) -> Bool {
        guard group.kind == .folder, let folders = library.organization.folders else { return true }
        return folders.first { $0.id == group.id }?.members.contains(id) ?? false
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

    /// Where `instance` stands for `action` as a member of `set`, re-read from
    /// its bundle now.
    private func turn(of action: VMGroupAction, on instance: VMInstance, in set: MemberSet) -> Turn {
        library.refreshFromOtherCopies(of: instance)
        guard set.holds(.vm(instance)) else { return .passesOver(.leftGroup) }
        return turn(of: action, on: instance)
    }

    /// What `action` does to `instance`, decided now: the step its standing
    /// names, run as a ``StartPolicy/group`` bring-up or the plain suspend or
    /// graceful stop, with no consent and no remedy.
    private func outcome(
        of action: VMGroupAction, on instance: VMInstance, in set: MemberSet
    ) async -> VMGroupActionOutcome {
        let step: VMCapabilityCatalog.GroupActionStep
        switch turn(of: action, on: instance, in: set) {
        case .passesOver(let reason):
            return .passedOver(reason: reason)
        case .acts(let acting):
            step = acting
        }
        do {
            switch step {
            case .start, .resume:
                try await launchBringUp(on: instance, resuming: step == .resume).value()
            case .suspend:
                try await suspend(instance)
            case .stop:
                try await stop(instance, disposition: .graceful, consent: .none)
            }
            return .done(verb: step.verb)
        } catch {
            return outcome(of: error, takenBy: step.verb, on: instance)
        }
    }

    /// Starts `instance` once no other work holds it: a follow-up on the VM,
    /// so its turn is decided, and its bring-up launched, in the step that
    /// frees it, before anything else can be decided against it — or at once
    /// on a VM nothing holds.
    ///
    /// The follow-up names no request, so nothing joins it before its turn has
    /// decided a start: a start queued behind it is decided on its own once
    /// this turn has passed the VM over or brought it up. A bring-up holding
    /// the VM when the turn comes is waited out, not joined — so one that
    /// fails leaves the turn to decide, and try, the start afresh.
    private func startOnceFree(_ instance: VMInstance, in set: MemberSet) async -> VMGroupActionOutcome {
        // What the drained turn decided: the verb it took the VM by, or why it
        // passed the VM over.
        var verb = VMVerb.start
        var passOver: VMGroupActionOutcome.PassOver?
        let followUp = VMFollowUp(scope: .vm, rank: .ordinary) { [weak self, weak instance] outcome in
            guard let self, let instance else { throw CancellationError() }
            switch self.turn(of: .start, on: instance, in: set) {
            case .passesOver(let reason):
                passOver = reason
                outcome.resolve(.success(()))
            case .acts(let step):
                verb = step.verb
                try self.launchBringUp(on: instance, resuming: step == .resume, resolving: outcome)
            }
        }
        instance.activity.follow(followUp)
        do {
            try await followUp.outcome.value()
        } catch {
            return outcome(of: error, takenBy: verb, on: instance)
        }
        return passOver.map { .passedOver(reason: $0) } ?? .done(verb: verb)
    }

    /// Launches the ``StartPolicy/group`` bring-up a start takes `instance`
    /// by — its Resume when `resuming`, else its Start — with no remedy,
    /// resolving `outcome`.
    @discardableResult
    private func launchBringUp(
        on instance: VMInstance, resuming: Bool, resolving outcome: VMOutcome = VMOutcome()
    ) throws -> VMOutcome {
        if resuming {
            return try launchResume(instance, policy: .group, macAddressRemedy: nil, resolving: outcome)
        }
        return try launchStart(
            instance, recovery: false, policy: .group, macAddressRemedy: nil, resolving: outcome)
    }

    /// What a run reports for `instance`, whose verb `verb` ended with
    /// `error`.
    ///
    /// A start that would begin a guest setup, and a VM that left the library
    /// while its turn waited, are passed over; anything else is read by
    /// ``outcome(of:takenBy:)``.
    private func outcome(
        of error: any Error, takenBy verb: VMVerb, on instance: VMInstance
    ) -> VMGroupActionOutcome {
        if error is UnattendedGuestSetupRefusal { return .passedOver(reason: .guestSetup) }
        if let refused = error as? VMAdmissionRefusal, refused.refusal == .removed {
            return .passedOver(reason: .removed)
        }
        let failure = bringUpFailure(error, verb: verb, on: instance)
        let outcome = Self.outcome(of: failure, takenBy: verb)
        if case .failed = outcome { broadcastFailure(failure, on: instance) }
        return outcome
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
