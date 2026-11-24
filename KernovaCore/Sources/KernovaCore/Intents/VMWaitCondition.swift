import AppIntents
import Foundation
import KernovaCommandModel

/// What Wait for Virtual Machine waits for, offered as a Shortcuts picker.
///
/// Mirrors ``WaitCondition`` for the reason ``VMStopMethod`` states.
/// ``init(_:)`` is exhaustive over the conditions, so a new one fails to build
/// here rather than reaching Shortcuts unnamed.
enum VMWaitCondition: String, AppEnum {
    case running
    case stopped
    case agent
    case address

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Wait Condition")

    /// Each reads after the virtual machine in the action's summary.
    static let caseDisplayRepresentations: [VMWaitCondition: DisplayRepresentation] = [
        .running: "Is Running",
        .stopped: "Is Stopped",
        .agent: "Has Its Guest Agent Connected and Up to Date",
        .address: "Has an IP Address",
    ]

    /// The condition this case names.
    var condition: WaitCondition {
        switch self {
        case .running: .running
        case .stopped: .stopped
        case .agent: .agent
        case .address: .address
        }
    }

    // periphery:ignore - never called: an exhaustive switch, so a condition added stops compiling here
    /// The case naming `condition`.
    init(_ condition: WaitCondition) {
        self =
            switch condition {
            case .running: .running
            case .stopped: .stopped
            case .agent: .agent
            case .address: .address
            }
    }
}
