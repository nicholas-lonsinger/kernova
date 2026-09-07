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

        /// Refuses a deadline that names no wait.
        public func validate() throws {
            try TimeoutOption.validate(timeout)
        }

        /// Waits, or refuses with what stood in the way.
        public func run() throws {
            let selector = try SelectorParsing.selector(from: vm, forcingID: options.id)
            let client = try CommandConnection.open(launchIfNeeded: !options.noLaunch)
            defer { client.close() }
            let deadline = Date().addingTimeInterval(timeout)

            // Subscribe first. The app takes its snapshot inside the same
            // main-actor call, so no change can land between the two.
            try client.post(.events)
            guard let snapshot = try nextFrame(from: client, before: deadline) else {
                throw CLIFailure(.unavailable, "Kernova closed the connection.")
            }
            _ = try snapshot.payload()

            // The app resolves the selector, so a name matches by exactly the
            // rules every other verb uses and a refusal carries its own exit
            // code. Issued only now, once the snapshot proves the subscription
            // is live, so the baseline it reads cannot predate it.
            try client.post(.info(selector))

            // Events for a VM not yet identified are kept rather than dropped:
            // the info answer and the event stream are answered by separate
            // tasks, so nothing guarantees the answer reaches the wire first.
            var pending: [VMCommandResponse.Result] = []
            let baseline = try awaitInfo(from: client, before: deadline, buffering: &pending)
            if isSatisfied(byBaseline: baseline) { return }
            for result in pending where try isSatisfied(by: result, vm: baseline.id) { return }

            while true {
                guard let frame = try nextFrame(from: client, before: deadline) else {
                    throw CLIFailure(
                        .unavailable, "Kernova stopped answering before the state arrived.")
                }
                if try isSatisfied(by: frame.payload(), vm: baseline.id) { return }
            }
        }

        /// Reads frames until the `info` answer lands, keeping every event that
        /// arrives first.
        private func awaitInfo(
            from client: VMCommandClient, before deadline: Date,
            buffering pending: inout [VMCommandResponse.Result]
        ) throws -> VMInfo {
            while true {
                guard let frame = try nextFrame(from: client, before: deadline) else {
                    throw CLIFailure(.unavailable, "Kernova closed the connection.")
                }
                // A refusal here is the app's own — a selector naming no VM
                // exits 3, an ambiguous one exits 4 listing the candidates.
                let result = try frame.payload()
                if case .info(let info) = result { return info }
                pending.append(result)
            }
        }

        /// Whether the VM was already in the state when the wait started.
        private func isSatisfied(byBaseline info: VMInfo) -> Bool {
            until.isSatisfied(byStatus: info.status)
                ?? until.isSatisfied(byAgentStatus: info.agentStatus)
                ?? false
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
            case .event(.removed(let id, let name)) where id == vm:
                // The VM left the library, so no state it could reach is
                // coming — including `stopped`, which is about a guest that
                // still exists.
                throw CLIFailure(.notFound, "\u{201C}\(name)\u{201D} left the library.")
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
