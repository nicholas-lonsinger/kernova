import AppIntents
import Foundation
import KernovaCommandModel

/// How a stop, or the stop half of a restart, takes the guest down, offered
/// as a Shortcuts picker on both verbs.
///
/// Mirrors ``StopDisposition`` rather than conforming it: the App Intents
/// metadata processor reads an `AppEnum`'s cases and case display
/// representations out of the declaring target's own source ("enums implemented
/// in an imported framework or library are not supported"), and
/// ``StopDisposition`` lives in the KernovaCommandModel library. ``init(_:)`` is
/// exhaustive over the dispositions, so a new one fails to build here rather than
/// reaching Shortcuts unnamed.
enum VMStopMethod: String, AppEnum {
    /// Request an ACPI shutdown and let the guest power itself off.
    case graceful
    /// Shut a macOS guest down without waiting for apps.
    case anyway
    /// Terminate the virtual machine immediately, losing unsaved guest state.
    case force

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Stop Method")

    /// Named for the verb they qualify, which the intent's own title holds:
    /// Stop, Stop Anyway, Force Stop; Restart, Restart Anyway, Force Restart.
    static let caseDisplayRepresentations: [VMStopMethod: DisplayRepresentation] = [
        .graceful: "Normal",
        .anyway: "Anyway",
        .force: "Force",
    ]

    /// The disposition this method names.
    var disposition: StopDisposition {
        switch self {
        case .graceful: .graceful
        case .anyway: .anyway
        case .force: .force
        }
    }

    /// The method naming `disposition`.
    init(_ disposition: StopDisposition) {
        self =
            switch disposition {
            case .graceful: .graceful
            case .anyway: .anyway
            case .force: .force
            }
    }
}
