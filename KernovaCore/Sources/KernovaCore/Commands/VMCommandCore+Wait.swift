import Foundation
import KernovaCommandModel

/// The wait verb: a VM meeting a ``WaitCondition``.
extension VMCommandCore {
    /// Suspends until the VM `selector` names meets `condition`, answering its
    /// `info` read as it stands then — at once, for a VM already meeting it.
    ///
    /// The condition is read in the step that arms the observation of what it
    /// reads, so no change can land between the two and be missed. A create,
    /// clone or import still writing the VM is waited through to the VM it
    /// becomes.
    ///
    /// Ends without the condition:
    /// - when the VM fails, with
    ///   ``CommandError/operationFailed(verb:title:message:recovery:)``
    ///   carrying the failure's own message — a create, clone or import's
    ///   included. A failure recorded before the wait began does not end it: a
    ///   VM in the error status can be started from there.
    /// - when the VM leaves the library otherwise, with ``WaitEnding/removed``.
    /// - for ``WaitCondition/address``, when Kernova answers an address no
    ///   wait can see become an observed one — at the start included — with
    ///   ``WaitEnding/noAddressToWaitFor(_:)``.
    /// - when `timeout` seconds pass first, with ``WaitEnding/timedOut(seconds:)``;
    ///   a `nil` `timeout` leaves the wait unbounded.
    /// - when the caller is cancelled, with `CancellationError`.
    package func wait(
        _ selector: VMSelector, until condition: WaitCondition, timeout: TimeInterval?
    ) async throws -> VMInfo {
        try Self.requireUsable(timeout)
        let start = try resolveEntry(selector)
        start.vm?.activity.refreshFromBundle()
        let id = start.id
        let priorFailure = start.vm?.activity.lastFailure?.id
        let reading: @MainActor () -> WaitReading? = { [self] in
            guard let entry = library.entries.first(where: { $0.id == id })?.addressable else { return .removed }
            if let current = entry.vm, let failure = current.activity.lastFailure, failure.id != priorFailure,
                let message = reportedMessage(of: failure, on: current)
            {
                return .ended(.operationFailed(verb: .wait, message: message))
            }
            switch standing(of: entry, against: condition) {
            case .met:
                return .met(info(entry))
            case .unmet:
                return nil
            case .unreachable(let ending):
                return .ended(.waitEnded(vm: summary(entry), condition: condition, ending: ending))
            }
        }
        let ended: WaitReading
        if let timeout {
            let deadline = ObservedChangeDeadline(seconds: timeout, clock: clock)
            guard let read = try await waitForObservedValue(reading, before: deadline) else {
                let current = library.entries.first(where: { $0.id == id })?.addressable ?? start
                throw CommandError.waitEnded(
                    vm: summary(current), condition: condition, ending: .timedOut(seconds: timeout))
            }
            ended = read
        } else {
            ended = try await waitForObservedValue(reading)
        }
        switch ended {
        case .met(let info): return info
        case .ended(let error): throw error
        case .removed: throw await removal(of: start, waitingFor: condition)
        }
    }

    /// What a wait whose VM left the library throws: the failure of the
    /// create, clone or import `start` was, when that is how it left, else
    /// ``WaitEnding/removed``.
    ///
    /// The arrival's outcome is read once its row has gone, which the library
    /// removes as that outcome settles.
    private func removal(of start: AddressableEntry, waitingFor condition: WaitCondition) async -> CommandError {
        if case .arriving(let arrival) = start, case .failure(let error) = await arrival.settled.result,
            let message = arrival.failure(for: error)?.operationFailureMessage
        {
            return .operationFailed(verb: .wait, message: message)
        }
        return .waitEnded(vm: summary(start), condition: condition, ending: .removed)
    }

    /// What a wait ended by `recorded`, a failure of `instance`, says of it: a
    /// session's end in Virtualization's own words, and an operation's in the
    /// words its verb gave its caller — ``bringUpFailure(_:verb:on:)`` for a
    /// Start or Resume, ``failure(_:verb:on:)`` for a Suspend — unrecorded;
    /// `nil` for a refusal, after which nothing about the VM moved.
    private func reportedMessage(of recorded: VMFailure, on instance: VMInstance) -> String? {
        switch recorded.cause {
        case .sessionStoppedWithError(let message):
            return message
        case .operation(let verb, let error):
            let reported: CommandError
            switch error {
            case is VMAdmissionRefusal:
                return nil
            case let command as CommandError:
                reported = command
            default:
                reported =
                    verb == .suspend
                    ? failure(error, verb: verb, on: instance) : ranAndFailed(error, verb: verb, on: instance)
            }
            return reported.operationFailureMessage
        }
    }

    /// How the library row `entry` stands against `condition` now. A row still
    /// being written runs nothing, and has the address of a VM at rest.
    private func standing(of entry: AddressableEntry, against condition: WaitCondition) -> WaitStanding {
        switch (condition, entry) {
        case (.running, .vm(let instance)):
            instance.status == .running ? .met : .unmet
        case (.stopped, .vm(let instance)):
            instance.status == .stopped ? .met : .unmet
        case (.agent, .vm(let instance)):
            instance.agentPresentation?.status.endsAWaitForTheAgent == true ? .met : .unmet
        case (.address, _):
            Self.standing(of: summary(entry).ipAddress)
        case (.running, .arriving), (.stopped, .arriving), (.agent, .arriving):
            .unmet
        }
    }

    /// How a guest whose address reads `address` stands against
    /// ``WaitCondition/address``: only an address not yet seen is one a wait
    /// can see arrive.
    private static func standing(of address: GuestIPAddress) -> WaitStanding {
        switch address.absence {
        case nil: .met
        case .notObserved: .unmet
        case let absence?: .unreachable(.noAddressToWaitFor(absence))
        }
    }
}

extension AgentStatus {
    /// Whether a wait for ``WaitCondition/agent`` ends on an agent in this
    /// status: one connected and current alone. An agent out of date, or of a
    /// standing this build can't judge, can't be relied on to behave like the
    /// one this build ships, which is what a caller waiting for it is about to
    /// use.
    var endsAWaitForTheAgent: Bool {
        switch self {
        case .current: true
        case .waiting, .connected, .outdated, .reinstallNeeded, .updating, .unresponsive, .expectedMissing,
            .connecting, .disconnected:
            false
        }
    }
}

/// Where a wait stands at one reading of the library, once it is over.
private enum WaitReading: Sendable {
    /// The VM met the condition, read as it stood then.
    case met(VMInfo)
    /// The wait ended without it.
    case ended(CommandError)
    /// The VM's row left the library.
    case removed
}

/// How one library row stands against a ``WaitCondition``.
private enum WaitStanding {
    case met
    case unmet
    /// No change a wait can see meets it, as the ending says.
    case unreachable(WaitEnding)
}
