import ArgumentParser
import Foundation
import KernovaKit

/// What `kernova wait` is waiting for.
public enum WaitCondition: String, ExpressibleByArgument, Sendable, CaseIterable {
    /// The guest is running.
    case running
    /// The guest is not running.
    case stopped
    /// The guest agent is connected and current.
    case agent

    /// Whether `status` satisfies a status-shaped condition, `nil` when this
    /// condition is not about the VM's status.
    func isSatisfied(byStatus status: String) -> Bool? {
        switch self {
        case .running: status == VMStatus.running.rawValue
        case .stopped: status == VMStatus.stopped.rawValue
        case .agent: nil
        }
    }

    /// Whether `agentStatus` satisfies an agent-shaped condition, `nil` when
    /// this condition is not about the agent.
    ///
    /// `current` alone: an agent that is connected but out of date cannot be
    /// relied on to behave like the one this build ships, which is the whole
    /// reason a script waits for it.
    func isSatisfied(byAgentStatus agentStatus: String) -> Bool? {
        guard case .agent = self else { return nil }
        return agentStatus == "current"
    }
}

extension KernovaCommand {
    /// `kernova wait <vm> --until <condition>` — block until a VM gets there.
    public struct Wait: ParsableCommand {
        /// What `kernova wait --help` says.
        public static let configuration = CommandConfiguration(
            commandName: "wait",
            abstract: "Block until a virtual machine reaches a state.",
            discussion: "Race-free against a virtual machine already in the state: the app "
                + "subscribes before it answers, so nothing can land in between and be missed.")

        /// Which virtual machine, by name or identifier.
        @Argument(help: "The virtual machine's name or identifier.")
        public var vm: String

        /// The state to wait for.
        @Option(name: .long, help: "The state to wait for: running, stopped, or agent.")
        public var until: WaitCondition

        /// How long to wait before giving up.
        @Option(name: .long, help: "Seconds to wait before giving up.")
        public var timeout: Double = 300

        /// The options every subcommand carries.
        @OptionGroup public var options: GlobalOptions

        /// Creates the subcommand.
        public init() {}

        /// Waits, or refuses with what stood in the way.
        public func run() throws {
            let selector = try SelectorParsing.selector(from: vm, forcingID: options.id)
            let client = try CommandConnection.open(options)
            defer { client.close() }
            let deadline = Date().addingTimeInterval(timeout)

            // Subscribe first. The app takes its snapshot inside the same
            // main-actor call, so no change can land between the two.
            try client.post(.events)
            guard let snapshot = try nextFrame(from: client, before: deadline) else {
                throw CLIFailure(.unavailable, "Kernova closed the connection.")
            }
            guard case .summaries(let rows) = try snapshot.payload() else {
                throw snapshot.result.unexpectedAnswer
            }
            guard let vmID = try identify(selector, in: rows) else { return }

            if until == .agent {
                // The snapshot carries no agent status, so read one — but only
                // now, once the subscription is provably live. A read taken
                // before it could miss a change in the gap.
                try client.post(.info(.id(vmID)))
            }

            while true {
                guard let frame = try nextFrame(from: client, before: deadline) else {
                    throw CLIFailure(
                        .unavailable, "Kernova stopped answering before the state arrived.")
                }
                if try isSatisfied(by: frame.payload(), vm: vmID) { return }
            }
        }

        /// The VM `selector` names, or `nil` when the wait is already over.
        ///
        /// A `stopped` wait on a VM that is not in the library is satisfied,
        /// not refused: a script tearing one down asked for it to be gone.
        private func identify(_ selector: VMSelector, in rows: [VMSummary]) throws -> UUID? {
            let matches = rows.filter { row in
                switch selector {
                case .id(let id): row.id == id
                case .name(let name): row.name == name
                case .idOrName(let text): row.id.uuidString == text || row.name == text
                }
            }
            guard let match = matches.first else {
                if until == .stopped { return nil }
                throw CLIFailure(
                    CLIExitCode(.notFound(selector: selector)),
                    CommandErrorDTO.notFound(selector: selector).message)
            }
            guard matches.count == 1 else {
                let failure = CommandErrorDTO.ambiguous(selector: selector, candidates: matches)
                throw CLIFailure(CLIExitCode(failure), failure.message)
            }
            return until.isSatisfied(byStatus: match.status) == true ? nil : match.id
        }

        /// Whether `result` says the wait is over.
        private func isSatisfied(by result: VMCommandResponse.Result, vm: UUID) throws -> Bool {
            switch result {
            case .info(let info) where info.id == vm:
                return until.isSatisfied(byAgentStatus: info.agentStatus) ?? false
            case .event(.statusChanged(let id, _, _, let to)) where id == vm:
                return until.isSatisfied(byStatus: to) ?? false
            case .event(.agentStatusChanged(let id, _, let status)) where id == vm:
                return until.isSatisfied(byAgentStatus: status) ?? false
            case .event(.removed(let id, _)) where id == vm:
                // The VM left the library. It is stopped in every sense that
                // matters; anything else waits for a state it can never reach.
                guard until == .stopped else {
                    throw CLIFailure(
                        .notFound, "\u{201C}\(vm.uuidString)\u{201D} left the library.")
                }
                return true
            default:
                return false
            }
        }

        /// The next frame, mapping the read deadline onto the timeout exit.
        private func nextFrame(from client: VMCommandClient, before deadline: Date) throws
            -> VMCommandResponse?
        {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw timedOut }
            client.waitForFrames(upTo: remaining)
            do {
                return try client.nextFrame()
            } catch let failure as CLIFailure where failure.code == .timedOut {
                throw timedOut
            }
        }

        private var timedOut: CLIFailure {
            CLIFailure(
                .timedOut,
                "\u{201C}\(vm)\u{201D} was not \(until.rawValue) within \(Int(timeout)) seconds.")
        }
    }
}
