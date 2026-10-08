import Foundation

/// One lifecycle action taken on every virtual machine in a smart group or a
/// folder — the header menu's Start All, Suspend All and Stop All, the
/// `kernova` lifecycle verbs given a group, and the Shortcuts group action.
public enum VMGroupAction: String, Codable, Sendable, Hashable, CaseIterable {
    /// Brings up each VM whose state takes it: a start, the restore of a
    /// suspended session, or the resume of a paused guest.
    case start
    /// Saves each running or paused guest's session to its bundle.
    case suspend
    /// Asks each running guest to shut down.
    case stop

    /// The verb a refusal of the whole group names.
    public var verb: VMVerb {
        switch self {
        case .start: .start
        case .suspend: .suspend
        case .stop: .stop
        }
    }
}

/// What one group action did, VM by VM.
public struct VMGroupActionReport: Codable, Sendable, Hashable {
    /// The action taken.
    public let action: VMGroupAction
    /// What kind of group it was taken on.
    public let groupKind: VMGroupKind
    /// The group's identifier.
    public let groupID: UUID
    /// The group's name, as the library holds it.
    public let groupName: String
    /// One per VM in the group, in the group's order.
    public let results: [VMGroupActionResult]

    /// Describes one group action.
    public init(
        action: VMGroupAction, groupKind: VMGroupKind, groupID: UUID, groupName: String,
        results: [VMGroupActionResult]
    ) {
        self.action = action
        self.groupKind = groupKind
        self.groupID = groupID
        self.groupName = groupName
        self.results = results
    }

    /// The VMs the action concerned and left undone, in the group's order.
    public var undone: [VMGroupActionResult] { results.filter(\.outcome.isUndone) }

    /// What a surface heads its account of ``undone`` with.
    public var undoneTitle: String {
        let verb =
            switch action {
            case .start: "Start"
            case .suspend: "Suspend"
            case .stop: "Stop"
            }
        return "Couldn\u{2019}t \(verb) Every VM in \u{201C}\(groupName)\u{201D}"
    }

    /// One line per VM in ``undone``, saying why.
    public var undoneMessage: String {
        undone.map { $0.line(for: action) }.joined(separator: "\n")
    }
}

/// What a group action did to one VM.
public struct VMGroupActionResult: Codable, Sendable, Hashable {
    /// The VM, as it stood once the action was done with it.
    public let vm: VMSummary
    /// What happened to it.
    public let outcome: VMGroupActionOutcome

    /// Pairs one VM with what happened to it.
    public init(vm: VMSummary, outcome: VMGroupActionOutcome) {
        self.vm = vm
        self.outcome = outcome
    }

    /// What the group's `action` did to this VM, or why it did not, in one
    /// line.
    public func line(for action: VMGroupAction) -> String {
        let name = vm.name
        switch outcome {
        case .done(.resume):
            return "Resumed \(name)"
        case .done(.suspend):
            return "Suspended \(name)"
        case .done(.stop):
            return "Asked \(name) to shut down"
        case .done:
            return "Started \(name)"
        case .passedOver(.state):
            let state = VMStatus.phrase(forWireName: vm.status, heldByAnotherCopy: vm.heldByAnotherCopy)
            return "Skipped \(name): it is \(state)."
        case .passedOver(.refused(let error)):
            return "Skipped \(name): \(error.message)"
        case .passedOver(.guestSetup):
            return "Skipped \(name): its first start sets up its guest, which only its own Start begins."
        case .passedOver(.cancelled):
            return "Skipped \(name): the \(action.rawValue) was cancelled before its turn."
        case .passedOver(.removed):
            return "Skipped \(name): it left the library before its turn."
        case .needsAnswer(let verb, let question):
            // Every other question's own words already say where it is answered.
            let answer =
                if case .confirmationRequired = question {
                    " \(verb.displayName) it on its own to answer."
                } else {
                    ""
                }
            return "Skipped \(name): \(question.message)\(answer)"
        case .failed(let error):
            return "Couldn\u{2019}t \(action.rawValue) \(name): \(error.message)"
        }
    }
}

/// What happened to one VM in a group action.
public enum VMGroupActionOutcome: Codable, Sendable, Hashable {
    /// `verb` ran to completion on the VM: a start, a resume, a suspend, or a
    /// request to shut down.
    case done(verb: VMVerb)
    /// The action does not concern the VM, for `reason`, and asked nothing of
    /// it.
    case passedOver(reason: PassOver)
    /// The VM's own verb `verb` asks a question first — a confirmation, its
    /// account's password, or a change to its network — which a group action
    /// asks nobody. `question` is that refusal.
    case needsAnswer(verb: VMVerb, question: CommandErrorDTO)
    /// The verb was tried and did not complete.
    case failed(error: CommandErrorDTO)

    /// Why an action does not concern a VM.
    public enum PassOver: Codable, Sendable, Hashable {
        /// Its state is not one the action acts on: it is already where the
        /// action would take it, or somewhere the action does not reach from —
        /// the summary's status says which.
        case state
        /// Something other than its state refuses it — work in flight, the app
        /// quitting — and `error` is what its own verb would answer.
        case refused(error: CommandErrorDTO)
        /// Starting it would begin the guest setup it still owes — a macOS
        /// install or an installer download — which a group never begins.
        case guestSetup
        /// The caller cancelled the action before the VM's turn came.
        case cancelled
        /// The VM left the library after the action began and before its turn
        /// came; the summary is how it stood when the action began.
        case removed

        private enum CodingKeys: String, CodingKey {
            case refused
        }

        private enum RefusedKeys: String, CodingKey {
            case error
        }

        /// The name a reason carrying nothing codes as, `nil` for one carrying
        /// data.
        private var bareName: String? {
            switch self {
            case .state: "state"
            case .guestSetup: "guestSetup"
            case .cancelled: "cancelled"
            case .removed: "removed"
            case .refused: nil
            }
        }

        /// Reads the shape ``encode(to:)`` writes.
        public init(from decoder: Decoder) throws {
            if let name = try? decoder.singleValueContainer().decode(String.self) {
                guard
                    let reason = [Self.state, .guestSetup, .cancelled, .removed].first(where: { $0.bareName == name })
                else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: decoder.codingPath, debugDescription: "\(name) names no reason"))
                }
                self = reason
                return
            }
            let refused = try decoder.container(keyedBy: CodingKeys.self)
                .nestedContainer(keyedBy: RefusedKeys.self, forKey: .refused)
            self = .refused(error: try refused.decode(CommandErrorDTO.self, forKey: .error))
        }

        /// Writes a reason carrying nothing as its bare name — `"state"`,
        /// `"guestSetup"`, `"cancelled"`, `"removed"` — and ``refused(error:)`` as
        /// `{"refused": {"error": …}}`.
        public func encode(to encoder: Encoder) throws {
            if case .refused(let error) = self {
                var container = encoder.container(keyedBy: CodingKeys.self)
                var refused = container.nestedContainer(keyedBy: RefusedKeys.self, forKey: .refused)
                try refused.encode(error, forKey: .error)
            } else {
                var container = encoder.singleValueContainer()
                try container.encode(bareName)
            }
        }
    }

    /// Whether the action concerned the VM and left it undone.
    public var isUndone: Bool {
        switch self {
        case .needsAnswer, .failed: true
        case .done, .passedOver: false
        }
    }
}
